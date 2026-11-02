import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Helpers shared by the OpenAI and Anthropic transports.
enum StreamSupport {
    enum ResponseMode {
        case unknown
        case sse
        case json
    }

    /// Some servers ignore `stream: true` and answer with a plain JSON body.
    /// Peek at the first bytes to find out which protocol we are talking to.
    static func looksLikeSSE(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(16), as: UTF8.self)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:") || trimmed.hasPrefix("event:") || trimmed.hasPrefix(":") { return true }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return false }
        return true
    }
}

enum RequestBuilder {
    static func makeURLRequest(
        url: URL,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        headers: [String: String],
        body: Data? = nil,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var finalURL = url
        if !queryItems.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw HTTPError(statusCode: 0, body: "Cannot build URL for \(url.absoluteString)")
            }
            components.queryItems = (components.queryItems ?? []) + queryItems
            guard let resolved = components.url else {
                throw HTTPError(statusCode: 0, body: "Cannot build URL for \(url.absoluteString)")
            }
            finalURL = resolved
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }
}
