import Foundation

/// Everything needed to talk to one server: where to send requests and how to
/// authenticate them.
public struct ProviderConfiguration: Sendable {
    public var style: APIStyle
    public var chatURL: URL
    public var modelsURL: URL
    public var headers: [String: String]
    public var queryItems: [URLQueryItem]
    public var timeout: TimeInterval

    public init(
        style: APIStyle,
        chatURL: URL,
        modelsURL: URL,
        headers: [String: String] = [:],
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval = 600
    ) {
        self.style = style
        self.chatURL = chatURL
        self.modelsURL = modelsURL
        self.headers = headers
        self.queryItems = queryItems
        self.timeout = timeout
    }

    /// Build the configuration for an endpoint definition.
    public static func make(endpoint: ProviderEndpoint, apiKey: String?) throws -> ProviderConfiguration {
        guard let base = EndpointResolver.normalizedBaseURL(endpoint.baseURL, style: endpoint.apiStyle) else {
            throw EndpointResolver.ResolutionError.invalidURL(endpoint.baseURL)
        }

        var headers: [String: String] = [:]
        var queryItems: [URLQueryItem] = []

        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch endpoint.authStyle {
        case .none:
            break
        case .bearer:
            if let key, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        case .header:
            if let key, !key.isEmpty {
                headers[endpoint.apiKeyHeader.isEmpty ? "x-api-key" : endpoint.apiKeyHeader] = key
            }
        case .query:
            if let key, !key.isEmpty {
                queryItems.append(URLQueryItem(name: endpoint.apiKeyQueryParameter.isEmpty ? "key" : endpoint.apiKeyQueryParameter, value: key))
            }
        }

        if endpoint.apiStyle == .anthropic, !endpoint.anthropicVersion.isEmpty {
            headers["anthropic-version"] = endpoint.anthropicVersion
        }
        headers["Accept"] = "text/event-stream, application/json"
        headers["User-Agent"] = "BUU/1.0"

        return ProviderConfiguration(
            style: endpoint.apiStyle,
            chatURL: EndpointResolver.chatURL(baseURL: base, style: endpoint.apiStyle),
            modelsURL: EndpointResolver.modelsURL(baseURL: base, style: endpoint.apiStyle),
            headers: headers,
            queryItems: queryItems
        )
    }
}
