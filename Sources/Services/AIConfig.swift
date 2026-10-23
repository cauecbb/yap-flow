import Foundation

/// The cloud services Yap can hold an API key for.
enum AIService: String, CaseIterable, Identifiable {
    case gemini, openai, anthropic, groq, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        case .anthropic: return "Claude"
        case .groq: return "Groq"
        case .custom: return "Custom"
        }
    }

    /// Where the key comes from, shown under the key field.
    var keyHint: String {
        switch self {
        case .gemini: return "From aistudio.google.com/apikey."
        case .openai: return "From platform.openai.com/api-keys."
        case .anthropic: return "From the Claude Console, under API keys."
        case .groq: return "From console.groq.com/keys."
        case .custom: return "Optional: local servers usually don't need one."
        }
    }

    /// One keychain item per service. Gemini's matches the name used before
    /// there were other providers, so a key saved back then carries over.
    var keychainService: String { "com.frigade.Yap.\(rawValue)" }

    /// Base URL for the services that speak the OpenAI API.
    var openAIBase: String? {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .custom: return AIConfig.customBaseURL.isEmpty ? nil : AIConfig.customBaseURL
        case .gemini, .anthropic: return nil
        }
    }
}

/// Who turns speech into text.
enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case gemini, openai, groq, custom, onDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        case .custom: return "Custom (OpenAI-compatible)"
        case .onDevice: return "On-device only"
        }
    }

    var service: AIService? {
        switch self {
        case .gemini: return .gemini
        case .openai: return .openai
        case .groq: return .groq
        case .custom: return .custom
        case .onDevice: return nil
        }
    }
}

/// Who tidies the raw transcript: filler, punctuation, lists, spoken
/// corrections. Gemini transcription does this itself, so it's skipped there.
/// Claude is here and not above because it doesn't take audio.
enum CleanupProvider: String, CaseIterable, Identifiable {
    case off, apple, openai, anthropic, groq, gemini, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .apple: return "Apple Intelligence"
        case .openai: return "OpenAI"
        case .anthropic: return "Claude"
        case .groq: return "Groq"
        case .gemini: return "Gemini"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var service: AIService? {
        switch self {
        case .off, .apple: return nil
        case .openai: return .openai
        case .anthropic: return .anthropic
        case .groq: return .groq
        case .gemini: return .gemini
        case .custom: return .custom
        }
    }
}

enum AIRole: String, Identifiable {
    case transcription, cleanup
    var id: String { rawValue }
}

/// Provider settings that live in UserDefaults. Keys are in the keychain
/// (APIKeyStore); everything here is safe to read with `defaults read`.
enum AIConfig {
    static let customBaseURLKey = "customBaseURL"

    /// What each provider uses unless Settings says otherwise. Custom has no
    /// default: whoever points Yap at their own server names the models.
    static func defaultModel(_ service: AIService, _ role: AIRole) -> String {
        switch (service, role) {
        case (.gemini, .transcription): return "gemini-3.5-transcribe"
        case (.gemini, .cleanup): return "gemini-3.5-flash-lite"
        case (.openai, .transcription): return "gpt-transcribe"
        case (.openai, .cleanup): return "gpt-6-luna"
        case (.groq, .transcription): return "whisper-large-v3-turbo"
        case (.groq, .cleanup): return "openai/gpt-oss-20b"
        case (.anthropic, _): return "claude-opus-5-5"
        case (.custom, _): return ""
        }
    }

    static func modelKey(_ service: AIService, _ role: AIRole) -> String {
        // Gemini's transcription model kept the key it had before there were
        // other providers.
        if service == .gemini, role == .transcription { return "geminiModel" }
        return "model.\(service.rawValue).\(role.rawValue)"
    }

    /// The model to call: the one set in Settings, or the default when blank.
    static func model(_ service: AIService, _ role: AIRole) -> String {
        let stored = UserDefaults.standard.string(forKey: modelKey(service, role))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultModel(service, role) : stored
    }

    static var geminiLiveModel: String {
        UserDefaults.standard.string(forKey: "geminiLiveModel") ?? "gemini-3.5-transcribe-live"
    }

    /// Streaming is Gemini's fast path; off, the whole take goes up on release.
    static var geminiStreaming: Bool {
        (UserDefaults.standard.object(forKey: "geminiStreaming") as? Bool) ?? true
    }

    /// For Custom: any OpenAI-compatible API, e.g. https://openrouter.ai/api/v1.
    static var customBaseURL: String {
        var url = (UserDefaults.standard.string(forKey: customBaseURLKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// Spoken-language hints as BCP-47 codes (pt-BR, en-US). Empty means detect
    /// automatically, which is what mixed Portuguese and English needs.
    static var languageCodes: [String] {
        let defaults = UserDefaults.standard
        return defaults.stringArray(forKey: "languageCodes")
            ?? defaults.stringArray(forKey: "geminiLanguageCodes")
            ?? []
    }

    /// The same hints as ISO 639-1 (pt, en), for the OpenAI-style APIs.
    static var languageISOCodes: [String] {
        var seen = Set<String>()
        return languageCodes.compactMap { code in
            let base = String(code.prefix { $0 != "-" && $0 != "_" }).lowercased()
            guard base.count == 2, seen.insert(base).inserted else { return nil }
            return base
        }
    }
}
