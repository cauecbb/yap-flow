import Foundation
import Testing
@testable import Yap

/// Answers every request with a canned response and remembers what was sent.
final class StubProtocol: URLProtocol {
    static var response: (status: Int, body: String) = (200, "{}")
    static var lastRequest: URLRequest?
    static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let reply = HTTPURLResponse(
            url: request.url!, statusCode: Self.response.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func install(status: Int = 200, body: String) {
        response = (status, body)
        lastRequest = nil
        lastBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        ProviderHTTP.session = URLSession(configuration: configuration)
    }

    static var sentJSON: [String: Any] {
        (lastBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    static var sentText: String { String(decoding: lastBody ?? Data(), as: UTF8.self) }
}

private let wav = Data("RIFF-fake-wav".utf8)
private let transcript = "remember to grab the keys and my laptop"

@Suite(.serialized)
struct ProviderRequestTests {
    @Test func openAITranscriptionSendsKeywordsAndTheFile() async throws {
        StubProtocol.install(body: #"{"text": " hello world "}"#)
        let text = try await OpenAICompatibleTranscriber.transcribe(
            wav: wav, vocabulary: ["Decola", "Bad<term>"], service: .openai, apiKey: "sk-test", model: "gpt-transcribe"
        )

        #expect(text == "hello world")
        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = StubProtocol.sentText
        #expect(body.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
        #expect(body.contains("name=\"keywords[]\"\r\n\r\nDecola\r\n"))
        #expect(!body.contains("Bad<term>"))
        #expect(body.contains("filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF-fake-wav"))
    }

    @Test func groqTranscriptionUsesAPromptInsteadOfKeywords() async throws {
        StubProtocol.install(body: #"{"text": "oi"}"#)
        _ = try await OpenAICompatibleTranscriber.transcribe(
            wav: wav, vocabulary: ["Decola", "Supabase"], service: .groq, apiKey: "gsk", model: "whisper-large-v3-turbo"
        )

        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        let body = StubProtocol.sentText
        #expect(body.contains("name=\"prompt\"\r\n\r\nGlossary: Decola, Supabase.\r\n"))
        #expect(body.contains("name=\"temperature\"\r\n\r\n0\r\n"))
        #expect(!body.contains("keywords[]"))
    }

    @Test func errorBodiesBecomeReadableErrors() async throws {
        StubProtocol.install(status: 401, body: #"{"error": {"message": "Incorrect API key"}}"#)
        await #expect(throws: ProviderError(message: "OpenAI returned 401: Incorrect API key")) {
            try await OpenAICompatibleTranscriber.transcribe(
                wav: wav, vocabulary: [], service: .openai, apiKey: "bad", model: "gpt-transcribe"
            )
        }
    }

    @Test func claudeCleanupUsesLowEffortAndDefaultFallbacks() async throws {
        StubProtocol.install(body: #"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "Remember to grab the keys and my laptop."}]}"#)
        let cleaned = try await LLMCleaner.clean(
            transcript, vocabulary: [], service: .anthropic, apiKey: "sk-ant", model: "claude-opus-5-5"
        )

        #expect(cleaned == "Remember to grab the keys and my laptop.")
        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let body = StubProtocol.sentJSON
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["temperature"] == nil)
        #expect((body["system"] as? String)?.contains("Reply with the edited transcript only") == true)
    }

    @Test func claudeRefusalFallsBackToTheRawText() async throws {
        StubProtocol.install(body: #"{"stop_reason": "refusal", "content": []}"#)
        await #expect(throws: ProviderError.self) {
            try await LLMCleaner.clean(transcript, vocabulary: [], service: .anthropic, apiKey: "k", model: "claude-opus-5-5")
        }
    }

    @Test func openAICleanupTurnsReasoningOff() async throws {
        StubProtocol.install(body: #"{"choices": [{"message": {"content": "Remember to grab the keys and my laptop."}}]}"#)
        _ = try await LLMCleaner.clean(transcript, vocabulary: [], service: .openai, apiKey: "sk", model: "gpt-6-luna")

        #expect(StubProtocol.lastRequest?.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        let body = StubProtocol.sentJSON
        #expect(body["reasoning_effort"] as? String == "none")
        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.first?["role"] as? String == "system")
        #expect((messages?.last?["content"] as? String)?.contains("<transcript>") == true)
    }

    @Test func groqCleanupKeepsReasoningLow() async throws {
        StubProtocol.install(body: #"{"choices": [{"message": {"content": "<think>hm</think>Remember to grab the keys and my laptop."}}]}"#)
        let cleaned = try await LLMCleaner.clean(
            transcript, vocabulary: [], service: .groq, apiKey: "gsk", model: "openai/gpt-oss-20b"
        )

        #expect(cleaned == "Remember to grab the keys and my laptop.")
        #expect(StubProtocol.sentJSON["reasoning_effort"] as? String == "low")
    }

    @Test func geminiCleanupSkipsThoughtParts() async throws {
        StubProtocol.install(body: #"{"candidates": [{"content": {"parts": [{"text": "thinking", "thought": true}, {"text": "Remember to grab the keys and my laptop."}]}}]}"#)
        let cleaned = try await LLMCleaner.clean(
            transcript, vocabulary: [], service: .gemini, apiKey: "AIza", model: "gemini-3.5-flash-lite"
        )

        #expect(cleaned == "Remember to grab the keys and my laptop.")
        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIza")
        #expect(StubProtocol.sentJSON["systemInstruction"] != nil)
    }

    @Test func geminiTranscriptionAsksForSmartMode() async throws {
        StubProtocol.install(body: #"{"candidates": [{"content": {"parts": [{"text": "Oi, tudo bem?"}]}}]}"#)
        let text = try await GeminiAPI.transcribe(wav: wav, vocabulary: ["Decola"], apiKey: "AIza", model: "gemini-3.5-transcribe")

        #expect(text == "Oi, tudo bem?")
        let config = (StubProtocol.sentJSON["generationConfig"] as? [String: Any])?["audioTranscriptionConfig"] as? [String: Any]
        #expect(config?["mode"] as? String == "SMART")
        #expect(config?["customVocabulary"] as? [String] == ["Decola"])
    }

    @Test func anAnswerInsteadOfAnEditIsRejected() async throws {
        StubProtocol.install(body: #"{"choices": [{"message": {"content": "Sure! Here are some productivity tips for organizing your workday efficiently."}}]}"#)
        await #expect(throws: ProviderError.self) {
            try await LLMCleaner.clean(transcript, vocabulary: [], service: .openai, apiKey: "sk", model: "gpt-6-luna")
        }
    }

    @Test func tidyDropsLeakedReasoningAndTags() {
        #expect(LLMCleaner.tidy("<think>x</think>\n<transcript>\nHi there.\n</transcript>") == "Hi there.")
        #expect(LLMCleaner.tidy("  Plain.  ") == "Plain.")
    }
}
