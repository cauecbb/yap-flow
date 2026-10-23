import Foundation
import Observation

// System dependencies are injected as protocols so this logic can be unit-tested with fakes.
@MainActor
@Observable
final class RecordingCoordinator {
    enum State: Equatable {
        case idle, recording, transcribing, inserting
    }

    private(set) var state: State = .idle
    private(set) var lastOutcome: InjectionOutcome?

    private let session: DictationSessioning
    private let injector: TextInjecting
    private let history: HistoryStoring
    private let hud: HUDControlling
    private let sounds: SoundPlaying
    private let cleaner: TranscriptCleaning
    private let cleanupEnabled: () -> Bool
    private let vocabulary: () -> [String]
    private let deviceName: () -> String?
    private let cloud: CloudTranscribing?
    private let cloudEnabled: () -> Bool
    private var liveStream: CloudStream?

    private var startedAt: Date?

    private var cancelArmed = false
    private var cancelArmTask: Task<Void, Never>?
    private let cancelArmWindow: Duration = .milliseconds(2500)

    init(
        session: DictationSessioning,
        injector: TextInjecting,
        history: HistoryStoring,
        hud: HUDControlling,
        sounds: SoundPlaying,
        cleaner: TranscriptCleaning,
        cleanupEnabled: @escaping () -> Bool,
        vocabulary: @escaping () -> [String],
        deviceName: @escaping () -> String?,
        cloud: CloudTranscribing? = nil,
        cloudEnabled: @escaping () -> Bool = { false }
    ) {
        self.session = session
        self.injector = injector
        self.history = history
        self.hud = hud
        self.sounds = sounds
        self.cleaner = cleaner
        self.cleanupEnabled = cleanupEnabled
        self.vocabulary = vocabulary
        self.deviceName = deviceName
        self.cloud = cloud
        self.cloudEnabled = cloudEnabled

        session.onLevel = { [weak self] level in self?.hud.setLevel(level) }
        session.onPartial = { [weak self] text in self?.hud.setPartial(text) }

        hud.setActions(
            onConfirm: { [weak self] in Task { await self?.toggle() } },
            onCancel: { [weak self] in Task { await self?.cancel() } }
        )
    }

    /// `silently` skips the stop cue: used when a too-short fn tap or an fn
    /// shortcut throws the dictation away, which shouldn't sound like a finish.
    func cancel(silently: Bool = false) async {
        guard state == .recording else { return }
        disarmCancel()
        state = .transcribing
        if !silently { sounds.playStop() }
        hud.hide(after: 0)
        takeStream()?.cancel()
        _ = try? await session.stop()
        state = .idle
    }

    // Two-step cancel: first press arms it, a second press within the window discards. Prevents a stray Escape (dismissing a menu, say) from destroying a dictation in progress.
    func handleEscape() {
        guard state == .recording else { return }

        if cancelArmed {
            disarmCancel()
            Task { await cancel() }
            return
        }

        cancelArmed = true
        hud.setPhase(.confirmCancel)
        cancelArmTask = Task { [weak self] in
            try? await Task.sleep(for: self?.cancelArmWindow ?? .milliseconds(2500))
            guard !Task.isCancelled, let self, self.cancelArmed else { return }
            self.cancelArmed = false
            if self.state == .recording { self.hud.setPhase(.listening) }
        }
    }

    private func disarmCancel() {
        cancelArmTask?.cancel()
        cancelArmTask = nil
        cancelArmed = false
    }

    private var activeCloud: CloudTranscribing? {
        guard cloudEnabled(), let cloud, cloud.isConfigured else { return nil }
        return cloud
    }

    func toggle() async {
        switch state {
        case .idle:
            await startRecording()
        case .recording:
            await stopRecording()
        case .transcribing, .inserting:
            break
        }
    }

    private func startRecording() async {
        // Capture the target app BEFORE any Yap UI appears, so the paste goes to where the user actually was.
        injector.captureTarget()

        state = .recording
        startedAt = Date()
        sounds.playStart()
        hud.show(device: deviceName())
        hud.setPhase(.listening)

        // Stream to the cloud from the first buffer, so on release only the
        // tail is left to transcribe.
        if let cloud = activeCloud {
            if let stream = cloud.beginStream(vocabulary: vocabulary()) {
                liveStream = stream
                session.onAudio = { [weak stream] pcm in stream?.append(pcm) }
            } else {
                cloud.warmUp()
            }
        }

        do {
            try await session.start()
        } catch {
            NSLog("Yap: failed to start recording: \(error.localizedDescription)")
            takeStream()?.cancel()
            hud.hide(after: 0)
            state = .idle
        }
    }

    /// Detaches the live stream from the microphone and hands it over.
    private func takeStream() -> CloudStream? {
        session.onAudio = nil
        defer { liveStream = nil }
        return liveStream
    }

    private func stopRecording() async {
        disarmCancel()
        state = .transcribing
        sounds.playStop()
        hud.setPhase(.transcribing)

        let releasedAt = Date()
        // The stream finishes while the on-device transcript does: the task only
        // runs once `session.stop()` has stopped the mic, so no audio is cut off.
        let stream = liveStream
        let streamed = stream.map { stream in Task { await stream.finish() } }

        do {
            let raw = try await session.stop()
            _ = takeStream()
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            // The on-device transcript doubles as the silence check: an empty
            // take never goes up, so the cloud model can't hallucinate words
            // into a pause.
            guard !text.isEmpty else {
                stream?.cancel()
                hud.hide(after: 0)
                state = .idle
                return
            }

            let terms = vocabulary()

            let cloud = activeCloud
            var cloudText = await streamed?.value
            var path = cloudText == nil ? "on-device" : "live"
            if cloudText == nil, let cloud, let audio = session.lastRecording {
                cloudText = await cloud.transcribe(wav: audio, vocabulary: terms)
                if cloudText != nil { path = "upload" }
            }
            NSLog("Yap: transcribed via \(path) in \(Int(Date().timeIntervalSince(releasedAt) * 1000)) ms after release")

            if let cloudText, cloud?.cleansText == true {
                // SMART mode already removed filler, applied corrections and the
                // dictionary, and formatted lists.
                text = cloudText
            } else {
                // A cloud transcript as heard beats the on-device one, but still
                // gets the same cleanup.
                if let cloudText { text = cloudText }

                // Deterministic passes first: instant, on device, no model needed.
                text = FillerRemoval.strip(text)
                if !terms.isEmpty {
                    text = DictionaryCorrection.correctFirstLetterMisses(in: text, terms: terms)
                }

                // Removing fillers can empty a transcript that was only "um uh".
                guard !text.isEmpty else {
                    hud.hide(after: 0)
                    state = .idle
                    return
                }

                // Cleanup also applies the dictionary to messier mis-hearings. If you
                // want your transcript cleaned, you want your names right too, so the
                // two ride the same setting and run in one pass.
                if cleanupEnabled(), cleaner.isAvailable {
                    hud.setPhase(.cleaning)
                    text = await cleaner.process(text, cleanup: true, vocabulary: terms)
                }
            }

            state = .inserting
            let outcome = await injector.deliver(text)
            lastOutcome = outcome
            if case .blockedBySecureInput(let holder) = outcome {
                NSLog("Yap: paste blocked by secure input held by \(holder ?? "another app"); text left on clipboard")
            }

            let duration = startedAt.map { Date().timeIntervalSince($0) }
            history.save(text: text, duration: duration, device: deviceName())

            hud.hide(after: 0)
        } catch {
            NSLog("Yap: failed to finish recording: \(error.localizedDescription)")
            takeStream()?.cancel()
            hud.hide(after: 0)
        }
        state = .idle
    }
}
