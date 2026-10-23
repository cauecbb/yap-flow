import Foundation
import Observation

// Behind a protocol so the coordinator can be unit-tested with a fake.
@MainActor
protocol CloudTranscribing: AnyObject {
    var isConfigured: Bool { get }
    /// Whether the text comes back already cleaned up (Gemini's SMART mode), so
    /// the cleanup pass is skipped.
    var cleansText: Bool { get }
    /// Opens the connection while the user is still talking, so the upload on
    /// release doesn't also pay for DNS and TLS.
    func warmUp()
    /// Starts streaming a dictation as it is spoken, or nil when the provider
    /// doesn't stream.
    func beginStream(vocabulary: [String]) -> CloudStream?
    /// The transcript, or nil on any failure so the caller can fall back to the
    /// on-device one.
    func transcribe(wav: Data, vocabulary: [String]) async -> String?
}

/// Sends each take to the transcription provider picked in Settings.
///
/// Unlike the rest of Yap this sends audio off the device. It only happens with
/// a provider picked and a key saved, and every failure falls back to the
/// on-device transcript rather than losing the dictation.
@MainActor
@Observable
final class CloudTranscriptionRouter: CloudTranscribing {
    /// Last failure, shown in Settings so a bad key or quota isn't silent.
    private(set) var lastError: String?

    @ObservationIgnored private let keys: APIKeyStore
    @ObservationIgnored private let provider: () -> TranscriptionProvider

    init(keys: APIKeyStore, provider: @escaping () -> TranscriptionProvider) {
        self.keys = keys
        self.provider = provider
    }

    var isConfigured: Bool {
        guard let service = provider().service else { return false }
        // A local server may take no key; the base URL is what it needs.
        if service == .custom { return service.openAIBase != nil }
        return keys.has(service)
    }

    var cleansText: Bool { provider() == .gemini }

    func warmUp() {
        guard isConfigured, let service = provider().service else { return }
        let base = service == .gemini ? GeminiAPI.host : service.openAIBase
        guard let base, let url = URL(string: base) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        ProviderHTTP.session.dataTask(with: request).resume()
    }

    func beginStream(vocabulary: [String]) -> CloudStream? {
        guard provider() == .gemini, AIConfig.geminiStreaming, let key = keys.key(for: .gemini) else { return nil }
        return GeminiAPI.beginStream(vocabulary: vocabulary, apiKey: key, model: AIConfig.geminiLiveModel) { [weak self] message in
            Task { @MainActor in self?.report(message) }
        }
    }

    func transcribe(wav: Data, vocabulary: [String]) async -> String? {
        guard isConfigured, let service = provider().service else { return nil }
        let model = AIConfig.model(service, .transcription)
        do {
            let text: String
            switch service {
            case .gemini:
                text = try await GeminiAPI.transcribe(
                    wav: wav, vocabulary: vocabulary, apiKey: keys.key(for: .gemini) ?? "", model: model
                )
            case .openai, .groq, .custom:
                text = try await OpenAICompatibleTranscriber.transcribe(
                    wav: wav, vocabulary: vocabulary, service: service, apiKey: keys.key(for: service), model: model
                )
            case .anthropic:
                return nil
            }
            lastError = nil
            return text.isEmpty ? nil : text
        } catch {
            report(error.localizedDescription)
            return nil
        }
    }

    private func report(_ message: String) {
        NSLog("Yap: \(message); using the on-device transcript")
        lastError = message
    }
}

/// Runs the cleanup pass on the provider picked in Settings: Apple
/// Intelligence on the device, or a chat model in the cloud.
@MainActor
@Observable
final class CleanupRouter: TranscriptCleaning {
    private(set) var lastError: String?

    @ObservationIgnored let apple: TranscriptCleanupService
    @ObservationIgnored private let keys: APIKeyStore
    @ObservationIgnored private let provider: () -> CleanupProvider

    init(apple: TranscriptCleanupService, keys: APIKeyStore, provider: @escaping () -> CleanupProvider) {
        self.apple = apple
        self.keys = keys
        self.provider = provider
    }

    var isAvailable: Bool {
        switch provider() {
        case .off: return false
        case .apple: return apple.isAvailable
        case .custom: return AIService.custom.openAIBase != nil
        case .openai, .anthropic, .groq, .gemini:
            return provider().service.map(keys.has) ?? false
        }
    }

    func process(_ text: String, cleanup: Bool, vocabulary: [String]) async -> String {
        let choice = provider()
        if choice == .apple { return await apple.process(text, cleanup: cleanup, vocabulary: vocabulary) }
        guard let service = choice.service else { return text }

        do {
            let edited = try await LLMCleaner.clean(
                text, vocabulary: vocabulary, service: service,
                apiKey: keys.key(for: service), model: AIConfig.model(service, .cleanup)
            )
            lastError = nil
            return edited
        } catch {
            NSLog("Yap: cleanup fell back to the raw text: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return text
        }
    }
}
