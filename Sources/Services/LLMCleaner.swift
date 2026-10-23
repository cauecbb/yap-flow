import Foundation

/// Tidies a transcript that arrived as heard (on-device, OpenAI, Groq, a custom
/// server) with a chat model from any provider, by the same rules as the
/// on-device cleanup in TranscriptCleanupService.
///
/// Throws instead of returning the input, so the caller can show why; it
/// pastes the raw text either way.
enum LLMCleaner {
    /// Cloud models answer in prose by default. Spelled out so nothing but the
    /// transcript gets pasted.
    private static let replyRule =
        "Reply with the edited transcript only: no preamble, no quotes, no tags, no commentary."

    static func clean(
        _ text: String, vocabulary: [String], service: AIService, apiKey: String?, model: String
    ) async throws -> String {
        guard !model.isEmpty else {
            throw ProviderError(message: "\(service.title): set a cleanup model in Settings")
        }
        let system = TranscriptCleanupService.instructions(cleanup: true, vocabulary: vocabulary) + "\n\n" + replyRule
        let prompt = TranscriptCleanupService.prompt(for: text)

        let raw: String
        switch service {
        case .anthropic:
            raw = try await anthropic(system: system, prompt: prompt, apiKey: apiKey ?? "", model: model)
        case .gemini:
            raw = try await GeminiAPI.clean(system: system, prompt: prompt, apiKey: apiKey ?? "", model: model)
        case .openai, .groq, .custom:
            raw = try await chat(system: system, prompt: prompt, service: service, apiKey: apiKey, model: model)
        }

        let edited = tidy(raw)
        guard !edited.isEmpty,
              TranscriptCleanupService.isFaithful(input: text, output: edited, vocabulary: vocabulary)
        else {
            throw ProviderError(message: "\(service.title) answered the dictation instead of editing it; pasted it as heard")
        }
        return edited
    }

    /// Drops reasoning a model leaked into its answer and transcript tags it echoed.
    static func tidy(_ raw: String) -> String {
        var text = raw
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        text = text.replacingOccurrences(of: "<transcript>", with: "")
            .replacingOccurrences(of: "</transcript>", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OpenAI-compatible chat (OpenAI, Groq, custom)

    static func chatRequest(
        system: String, prompt: String, service: AIService, apiKey: String?, model: String
    ) throws -> URLRequest {
        guard let base = service.openAIBase else {
            throw ProviderError(message: "\(service.title): set the API base URL in Settings")
        }
        let url = try ProviderHTTP.url("\(base)/chat/completions", service: service.title)

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt],
            ],
        ]
        // Reasoning models think before answering; for a copy edit that is only
        // a longer wait before the paste.
        if service == .openai, model.hasPrefix("gpt-6") { body["reasoning_effort"] = "none" }
        if service == .groq, model.hasPrefix("openai/gpt-oss") { body["reasoning_effort"] = "low" }

        var headers = ["Content-Type": "application/json"]
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        return ProviderHTTP.post(url, headers: headers, body: try ProviderHTTP.jsonBody(body))
    }

    private static func chat(
        system: String, prompt: String, service: AIService, apiKey: String?, model: String
    ) async throws -> String {
        let json = try await ProviderHTTP.json(
            chatRequest(system: system, prompt: prompt, service: service, apiKey: apiKey, model: model),
            service: service.title
        )
        let choices = json["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? ""
    }

    // MARK: - Claude (Anthropic Messages API)

    static func anthropicRequest(system: String, prompt: String, apiKey: String, model: String) throws -> URLRequest {
        let url = try ProviderHTTP.url("https://api.anthropic.com/v1/messages", service: "Claude")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        var headers = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json",
        ]
        // A copy edit needs little thought, and every second of it delays the paste.
        if supportsEffort(model) { body["output_config"] = ["effort": "low"] }
        // If a safety classifier declines, the API reruns on a model that won't.
        if supportsDefaultFallbacks(model) {
            body["fallbacks"] = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }
        return ProviderHTTP.post(url, headers: headers, body: try ProviderHTTP.jsonBody(body))
    }

    private static func anthropic(system: String, prompt: String, apiKey: String, model: String) async throws -> String {
        let json = try await ProviderHTTP.json(
            anthropicRequest(system: system, prompt: prompt, apiKey: apiKey, model: model), service: "Claude"
        )
        if (json["stop_reason"] as? String) == "refusal" {
            throw ProviderError(message: "Claude declined to edit this dictation; pasted it as heard")
        }
        let content = json["content"] as? [[String: Any]] ?? []
        return content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    /// The current Claude generation takes `output_config.effort`.
    private static func supportsEffort(_ model: String) -> Bool {
        ["claude-opus-5", "claude-fable-5", "claude-sonnet-5", "claude-haiku-5"].contains { model.hasPrefix($0) }
    }

    /// The models that accept `fallbacks: "default"`.
    private static func supportsDefaultFallbacks(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5") || model == "claude-fable-5-1" || model == "claude-sonnet-5-5"
    }
}
