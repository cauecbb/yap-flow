import Foundation
import Observation
import Security

// Behind a protocol so the coordinator can be unit-tested with a fake.
@MainActor
protocol CloudTranscribing: AnyObject {
    var isConfigured: Bool { get }
    /// Opens the connection while the user is still talking, so the upload on
    /// release doesn't also pay for DNS and TLS.
    func warmUp()
    /// Starts streaming a dictation as it is spoken, or nil when streaming is off.
    func beginStream(vocabulary: [String]) -> CloudStream?
    /// The cleaned-up transcript, or nil on any failure so the caller can fall
    /// back to the on-device one.
    func transcribe(wav: Data, vocabulary: [String]) async -> String?
}

/// Wispr Flow-style transcription through Gemini 3.5 Transcribe in SMART mode:
/// filler and false starts removed, spoken self-corrections applied, lists and
/// numbers formatted, and Portuguese and English mixed in one sentence handled
/// without picking a language up front.
///
/// Unlike the rest of Yap this sends audio off the device, to Google. It is
/// opt-in through a key the user pastes in Settings, and every failure falls
/// back to the on-device transcript rather than losing the dictation.
@MainActor
@Observable
final class GeminiTranscriber: CloudTranscribing {
    private(set) var hasKey = false
    /// Last failure, shown in Settings so a bad key or quota isn't silent.
    private(set) var lastError: String?

    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

    private static let host = "https://generativelanguage.googleapis.com"
    private static let timeout: TimeInterval = 20
    /// The docs advise about 100 terms for the best biasing.
    private static let maximumVocabulary = 100

    /// Overridable without a rebuild: `defaults write com.frigade.Yap geminiModel <id>`.
    private var model: String {
        UserDefaults.standard.string(forKey: "geminiModel") ?? "gemini-3.5-transcribe"
    }

    private var liveModel: String {
        UserDefaults.standard.string(forKey: "geminiLiveModel") ?? "gemini-3.5-transcribe-live"
    }

    /// Streaming is the fast path; `defaults write com.frigade.Yap
    /// geminiStreaming -bool false` falls back to one upload on release.
    private var streamingEnabled: Bool {
        (UserDefaults.standard.object(forKey: "geminiStreaming") as? Bool) ?? true
    }

    /// Empty means automatic detection with code-switching, which is what
    /// mixed Portuguese and English needs. `defaults write com.frigade.Yap
    /// geminiLanguageCodes -array pt-BR` pins it.
    private var languageCodes: [String] {
        UserDefaults.standard.stringArray(forKey: "geminiLanguageCodes") ?? []
    }

    var isConfigured: Bool { hasKey }

    /// Read once at launch: with an ad-hoc signed build, macOS may ask to allow
    /// keychain access after a rebuild, and that belongs at launch rather than
    /// in the middle of a dictation.
    func loadKey() {
        apiKey = Keychain.read()
        hasKey = apiKey?.isEmpty == false
    }

    func saveKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.write(key)
        lastError = nil
        loadKey()
    }

    func removeKey() {
        Keychain.delete()
        lastError = nil
        loadKey()
    }

    func warmUp() {
        guard hasKey, let url = URL(string: Self.host) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        session.dataTask(with: request).resume()
    }

    func beginStream(vocabulary: [String]) -> CloudStream? {
        guard streamingEnabled, let apiKey, !apiKey.isEmpty,
              var components = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        else { return nil }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { return nil }

        var transcription: [String: Any] = ["mode": "SMART"]
        let terms = Array(vocabulary.prefix(Self.maximumVocabulary))
        if !terms.isEmpty { transcription["customVocabulary"] = terms }
        if !languageCodes.isEmpty { transcription["languageCodes"] = languageCodes }

        let stream = GeminiLiveSession(task: session.webSocketTask(with: url), setup: [
            "model": "models/\(liveModel)",
            "generationConfig": ["responseModalities": ["TEXT"]],
            // Push-to-talk: the release ends the turn, not a pause.
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            "inputAudioTranscription": transcription,
        ])
        stream.onError = { [weak self] message in
            Task { @MainActor in self?.fail(message) }
        }
        stream.start()
        return stream
    }

    func transcribe(wav: Data, vocabulary: [String]) async -> String? {
        guard let apiKey, !apiKey.isEmpty,
              let url = URL(string: "\(Self.host)/v1beta/models/\(model):generateContent") else { return nil }

        var config: [String: Any] = ["mode": "SMART"]
        let terms = Array(vocabulary.prefix(Self.maximumVocabulary))
        if !terms.isEmpty { config["customVocabulary"] = terms }
        if !languageCodes.isEmpty { config["languageCodes"] = languageCodes }

        let body: [String: Any] = [
            "contents": [["parts": [["inlineData": ["mimeType": "audio/wav", "data": wav.base64EncodedString()]]]]],
            "generationConfig": ["audioTranscriptionConfig": config],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            guard status == 200 else {
                let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
                fail("Gemini returned \(status): \(message)")
                return nil
            }

            let candidates = json?["candidates"] as? [[String: Any]]
            let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            let text = (parts ?? []).compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = nil
            return text.isEmpty ? nil : text
        } catch {
            fail("Gemini request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fail(_ message: String) {
        NSLog("Yap: \(message); using the on-device transcript")
        lastError = message
    }
}

/// The API key lives in the login keychain, never in defaults or on disk.
private enum Keychain {
    private static let service = "com.frigade.Yap.gemini"
    private static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("Yap: could not save the Gemini key to the keychain (\(status))")
        }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
