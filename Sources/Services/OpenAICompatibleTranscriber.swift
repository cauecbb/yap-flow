import Foundation

/// Speech to text over the OpenAI audio API, which Groq and most self-hosted
/// servers (LocalAI, faster-whisper-server, and so on) also speak: the take goes
/// up as a WAV in one multipart request on release.
///
/// These return the transcript as heard, so the caller runs it through cleanup.
enum OpenAICompatibleTranscriber {
    /// Whisper reads at most 224 tokens of prompt; a few dozen terms fit.
    private static let maximumPromptTerms = 40
    private static let maximumKeywords = 100

    static func request(
        wav: Data, vocabulary: [String], service: AIService, apiKey: String?, model: String
    ) throws -> URLRequest {
        guard let base = service.openAIBase else {
            throw ProviderError(message: "\(service.title): set the API base URL in Settings")
        }
        guard !model.isEmpty else {
            throw ProviderError(message: "\(service.title): set a transcription model in Settings")
        }
        let url = try ProviderHTTP.url("\(base)/audio/transcriptions", service: service.title)

        var form = MultipartForm()
        form.field("model", model)
        form.field("response_format", "json")

        // Keywords can't span lines or carry angle brackets.
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "<>\r\n")) == nil }
        let languages = AIConfig.languageISOCodes

        if service == .openai {
            // gpt-transcribe takes literal keyword hints and several languages.
            for term in terms.prefix(maximumKeywords) { form.field("keywords[]", term) }
            for language in languages { form.field("languages[]", language) }
        } else {
            // Whisper-style: a prompt that spells the terms, one language at most.
            if !terms.isEmpty {
                form.field("prompt", "Glossary: " + terms.prefix(maximumPromptTerms).joined(separator: ", ") + ".")
            }
            if languages.count == 1 { form.field("language", languages[0]) }
            form.field("temperature", "0")
        }
        form.file("file", filename: "dictation.wav", contentType: "audio/wav", data: wav)

        var headers = ["Content-Type": form.contentType]
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        return ProviderHTTP.post(url, headers: headers, body: form.finish())
    }

    static func transcribe(
        wav: Data, vocabulary: [String], service: AIService, apiKey: String?, model: String
    ) async throws -> String {
        let json = try await ProviderHTTP.json(
            request(wav: wav, vocabulary: vocabulary, service: service, apiKey: apiKey, model: model),
            service: service.title
        )
        return ((json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A multipart/form-data body.
struct MultipartForm {
    let boundary = "yap-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, contentType: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finish() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}
