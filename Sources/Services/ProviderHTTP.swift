import Foundation

struct ProviderError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// The one HTTP path every provider goes through: an ephemeral session, so
/// nothing is cached to disk, and the `{"error": {"message": ...}}` body that
/// Gemini, OpenAI, Anthropic and Groq all use turned into a readable error.
enum ProviderHTTP {
    /// Swapped for a stubbed session in tests.
    static var session = URLSession(configuration: .ephemeral)

    static let timeout: TimeInterval = 20

    static func post(_ url: URL, headers: [String: String], body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = body
        return request
    }

    static func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func json(_ request: URLRequest, service: String) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError(message: "\(service) request failed: \(error.localizedDescription)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? (json?["error"] as? String)
                ?? "HTTP \(status)"
            throw ProviderError(message: "\(service) returned \(status): \(message)")
        }
        guard let json else {
            throw ProviderError(message: "\(service) returned a response Yap couldn't read")
        }
        return json
    }

    static func url(_ string: String, service: String) throws -> URL {
        guard let url = URL(string: string), url.scheme != nil else {
            throw ProviderError(message: "\(service): \(string) is not a valid URL")
        }
        return url
    }
}
