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
    private let wordForWord: () -> Bool
    private var liveStream: CloudStream?

    private var startedAt: Date?

    /// Bumped whenever a take is abandoned, so work still in flight for it
    /// knows not to paste.
    private var take = 0

    /// How long the on-device transcript may take to finish before the take
    /// goes on without it.
    private let localDeadline: Double = 2.5

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
        cloudEnabled: @escaping () -> Bool = { false },
        wordForWord: @escaping () -> Bool = { false }
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
        self.wordForWord = wordForWord

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
        take += 1
        state = .transcribing
        if !silently { sounds.playStop() }
        hud.hide(after: 0)
        takeStream()?.cancel()
        // Stops the mic. Not waited on past the deadline: a stuck analyzer would
        // otherwise hold the state here and every later press would be ignored.
        _ = await withDeadline(localDeadline) { try await self.session.stop() }
        state = .idle
    }

    /// Esc while a take is still being transcribed: give up on it now. Its work
    /// finishes in the background and is dropped.
    func abandonProcessing() {
        guard state == .transcribing else { return }
        take += 1
        DiagnosticLog.write("take abandoned while processing")
        finish()
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
            DiagnosticLog.write("failed to start recording: \(error.localizedDescription)")
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
        let current = take
        sounds.playStop()
        hud.setPhase(.transcribing)

        let releasedAt = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(releasedAt) * 1000) }

        // The stream finishes while the on-device transcript does: the task only
        // runs once `session.stop()` has stopped the mic, so no audio is cut off.
        let stream = liveStream
        let streamed = stream.map { stream in Task { await stream.finish() } }

        // nil when the on-device transcript didn't come: stopped before the
        // analyzer was ready, failed, or past the deadline. The recording still
        // goes to the cloud then.
        let local = await withDeadline(localDeadline) { try await self.session.stop() }
        _ = takeStream()
        guard take == current else {
            stream?.cancel()
            return
        }
        var text = (local ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cloud = activeCloud
        DiagnosticLog.write("released; on-device transcript \(local == nil ? "unavailable" : "done") at \(elapsed()) ms")

        // A finished, empty on-device transcript is the silence check: that take
        // never goes up, so the cloud model can't hallucinate words into a pause.
        // Without one, only the cloud can tell.
        guard !text.isEmpty || (local == nil && cloud != nil) else {
            stream?.cancel()
            finish()
            return
        }

        let terms = vocabulary()

        var cloudText = await streamed?.value
        var path = cloudText == nil ? "on-device" : "live"
        if cloudText == nil, let cloud, let audio = session.lastRecording {
            cloudText = await cloud.transcribe(wav: audio, vocabulary: terms)
            if cloudText != nil { path = "upload" }
        }
        guard take == current else { return }
        DiagnosticLog.write("transcribed via \(path) at \(elapsed()) ms")

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
                finish()
                return
            }

            if wordForWord() {
                // Every word stays as spoken: no rewrite, only punctuation, and
                // only when the transcript came without it.
                if cleanupEnabled(), cleaner.isAvailable, TranscriptCleanupService.needsPunctuation(text) {
                    hud.setPhase(.cleaning)
                    text = await cleaner.punctuate(text)
                    guard take == current else { return }
                }
            } else if cleanupEnabled(), cleaner.isAvailable {
                // Cleanup also applies the dictionary to messier mis-hearings. If
                // you want your transcript cleaned, you want your names right too,
                // so the two ride the same setting and run in one pass.
                hud.setPhase(.cleaning)
                text = await cleaner.process(text, cleanup: true, vocabulary: terms)
                guard take == current else { return }
            }
        }

        state = .inserting
        let outcome = await injector.deliver(text)
        lastOutcome = outcome
        if case .blockedBySecureInput(let holder) = outcome {
            DiagnosticLog.write("paste blocked by secure input held by \(holder ?? "another app"); text left on clipboard")
        }

        let duration = startedAt.map { Date().timeIntervalSince($0) }
        history.save(text: text, duration: duration, device: deviceName())
        DiagnosticLog.write("pasted at \(elapsed()) ms")
        finish()
    }

    private func finish() {
        hud.hide(after: 0)
        state = .idle
    }
}
