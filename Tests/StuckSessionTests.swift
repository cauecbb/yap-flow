import Foundation
import Testing
@testable import Yap

/// A session whose stop never returns, like Apple's analyzer finalizing a
/// session it never started.
@MainActor
final class HangingSession: DictationSessioning {
    var onLevel: ((Float) -> Void)?
    var onPartial: ((String) -> Void)?
    var onAudio: ((Data) -> Void)?

    func start() async throws {}

    func stop() async throws -> String {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        return "never"
    }
}

/// A cloud transcriber that answers a fixed text, or hangs until released.
@MainActor
final class FakeCloud: CloudTranscribing {
    var isConfigured = true
    var cleansText = true
    var text: String? = "From the cloud."
    func warmUp() {}
    func beginStream(vocabulary: [String]) -> CloudStream? { nil }
    func transcribe(wav: Data, vocabulary: [String]) async -> String? { text }
}

@MainActor
final class RecordingSessionWithAudio: DictationSessioning {
    var onLevel: ((Float) -> Void)?
    var onPartial: ((String) -> Void)?
    var onAudio: ((Data) -> Void)?
    var lastRecording: Data? { Data("wav".utf8) }
    var stopBehavior: () async throws -> String = { "" }

    func start() async throws {}
    func stop() async throws -> String { try await stopBehavior() }
}

@MainActor
private func coordinator(
    session: DictationSessioning, injector: FakeInjector, cloud: CloudTranscribing? = nil
) -> RecordingCoordinator {
    RecordingCoordinator(
        session: session,
        injector: injector,
        history: FakeHistory(),
        hud: FakeHUD(),
        sounds: FakeSounds(),
        cleaner: FakeCleaner(),
        cleanupEnabled: { false },
        vocabulary: { [] },
        deviceName: { nil },
        cloud: cloud,
        cloudEnabled: { cloud != nil }
    )
}

@MainActor
struct StuckSessionTests {
    @Test func aStuckOnDeviceStopDoesNotWedgeTheCoordinator() async {
        let coordinator = coordinator(session: HangingSession(), injector: FakeInjector())
        await coordinator.toggle()
        await coordinator.toggle()
        // Back to idle after the deadline, so the next press starts a take.
        #expect(coordinator.state == .idle)
    }

    @Test func cancelDoesNotWaitOnAStuckStop() async {
        let coordinator = coordinator(session: HangingSession(), injector: FakeInjector())
        await coordinator.toggle()
        await coordinator.cancel()
        #expect(coordinator.state == .idle)
    }

    @Test func withoutAnOnDeviceTranscriptTheCloudTextIsStillPasted() async {
        let session = RecordingSessionWithAudio()
        session.stopBehavior = { throw TranscriptionError.notReady }
        let injector = FakeInjector()
        let coordinator = coordinator(session: session, injector: injector, cloud: FakeCloud())

        await coordinator.toggle()
        await coordinator.toggle()

        #expect(injector.delivered == ["From the cloud."])
        #expect(coordinator.state == .idle)
    }

    @Test func aFinishedEmptyOnDeviceTranscriptStillMeansSilence() async {
        let session = RecordingSessionWithAudio()
        session.stopBehavior = { "" }
        let injector = FakeInjector()
        let coordinator = coordinator(session: session, injector: injector, cloud: FakeCloud())

        await coordinator.toggle()
        await coordinator.toggle()

        #expect(injector.delivered.isEmpty)
    }

    @Test func escapeWhileProcessingAbandonsTheTake() async {
        let session = RecordingSessionWithAudio()
        let injector = FakeInjector()
        let coordinator = coordinator(session: session, injector: injector, cloud: FakeCloud())
        session.stopBehavior = { [weak coordinator] in
            // The user gives up while the take is still being processed.
            coordinator?.abandonProcessing()
            return "something said"
        }

        await coordinator.toggle()
        await coordinator.toggle()

        #expect(injector.delivered.isEmpty)
        #expect(coordinator.state == .idle)
    }
}
