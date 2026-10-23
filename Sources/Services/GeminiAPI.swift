import Foundation

/// Gemini: Wispr Flow-style transcription through Gemini 3.5 Transcribe in
/// SMART mode (filler and false starts removed, spoken self-corrections
/// applied, lists and numbers formatted, Portuguese and English mixed in one
/// sentence handled without picking a language up front), plus plain text
/// cleanup for when another provider transcribed.
enum GeminiAPI {
    static let host = "https://generativelanguage.googleapis.com"

    /// The docs advise about 100 terms for the best biasing.
    private static let maximumVocabulary = 100

    private static func transcriptionConfig(vocabulary: [String]) -> [String: Any] {
        var config: [String: Any] = ["mode": "SMART"]
        let terms = Array(vocabulary.prefix(maximumVocabulary))
        if !terms.isEmpty { config["customVocabulary"] = terms }
        if !AIConfig.languageCodes.isEmpty { config["languageCodes"] = AIConfig.languageCodes }
        return config
    }

    static func transcribeRequest(wav: Data, vocabulary: [String], apiKey: String, model: String) throws -> URLRequest {
        let url = try ProviderHTTP.url("\(host)/v1beta/models/\(model):generateContent", service: "Gemini")
        let body: [String: Any] = [
            "contents": [["parts": [["inlineData": ["mimeType": "audio/wav", "data": wav.base64EncodedString()]]]]],
            "generationConfig": ["audioTranscriptionConfig": transcriptionConfig(vocabulary: vocabulary)],
        ]
        return ProviderHTTP.post(url, headers: [
            "x-goog-api-key": apiKey,
            "Content-Type": "application/json",
        ], body: try ProviderHTTP.jsonBody(body))
    }

    /// The whole take in one request, after release.
    static func transcribe(wav: Data, vocabulary: [String], apiKey: String, model: String) async throws -> String {
        let json = try await ProviderHTTP.json(
            transcribeRequest(wav: wav, vocabulary: vocabulary, apiKey: apiKey, model: model), service: "Gemini"
        )
        return text(of: json)
    }

    /// Streams the take while it is spoken; see GeminiLiveSession.
    static func beginStream(
        vocabulary: [String], apiKey: String, model: String, onError: @escaping (String) -> Void
    ) -> CloudStream? {
        guard var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        ) else { return nil }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { return nil }

        let stream = GeminiLiveSession(task: ProviderHTTP.session.webSocketTask(with: url), setup: [
            "model": "models/\(model)",
            "generationConfig": ["responseModalities": ["TEXT"]],
            // Push-to-talk: the release ends the turn, not a pause.
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            "inputAudioTranscription": transcriptionConfig(vocabulary: vocabulary),
        ])
        stream.onError = onError
        stream.start()
        return stream
    }

    static func cleanupRequest(system: String, prompt: String, apiKey: String, model: String) throws -> URLRequest {
        let url = try ProviderHTTP.url("\(host)/v1beta/models/\(model):generateContent", service: "Gemini")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
        ]
        return ProviderHTTP.post(url, headers: [
            "x-goog-api-key": apiKey,
            "Content-Type": "application/json",
        ], body: try ProviderHTTP.jsonBody(body))
    }

    static func clean(system: String, prompt: String, apiKey: String, model: String) async throws -> String {
        let json = try await ProviderHTTP.json(
            cleanupRequest(system: system, prompt: prompt, apiKey: apiKey, model: model), service: "Gemini"
        )
        return text(of: json)
    }

    /// The answer's text parts, skipping any thought summaries.
    static func text(of json: [String: Any]) -> String {
        let candidates = json["candidates"] as? [[String: Any]]
        let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
