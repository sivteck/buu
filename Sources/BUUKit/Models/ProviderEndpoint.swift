import Foundation

/// Which wire protocol the remote server speaks.
public enum APIStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// `POST /chat/completions` with SSE deltas (OpenAI, LM Studio, Ollama, vLLM, llama.cpp…).
    case openAI
    /// `POST /v1/messages` with SSE content-block deltas (Anthropic).
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI compatible"
        case .anthropic: return "Anthropic compatible"
        }
    }
}

/// How the API key is transmitted.
public enum AuthStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case bearer
    case header
    case query

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "No authentication"
        case .bearer: return "Authorization: Bearer"
        case .header: return "Custom header"
        case .query: return "Query parameter"
        }
    }

    public static func `default`(for style: APIStyle) -> AuthStyle {
        switch style {
        case .openAI: return .bearer
        case .anthropic: return .header
        }
    }
}

/// A configured inference server.
public struct ProviderEndpoint: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Base URL of the server, e.g. `http://localhost:1234/v1`.
    public var baseURL: String
    public var apiStyle: APIStyle
    public var authStyle: AuthStyle
    /// Name of the header used when ``AuthStyle/header`` is selected.
    public var apiKeyHeader: String
    /// Name of the query parameter used when ``AuthStyle/query`` is selected.
    public var apiKeyQueryParameter: String
    /// `anthropic-version` header, only sent for Anthropic compatible servers.
    public var anthropicVersion: String
    public var defaultModel: String
    public var systemPrompt: String
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    /// Whether images may be attached to requests.
    public var supportsImages: Bool
    /// Whether the server should be asked for the model list.
    public var listsModels: Bool

    public init(
        id: UUID = UUID(),
        name: String = "New server",
        baseURL: String = "http://localhost:1234/v1",
        apiStyle: APIStyle = .openAI,
        authStyle: AuthStyle = .bearer,
        apiKeyHeader: String = "x-api-key",
        apiKeyQueryParameter: String = "key",
        anthropicVersion: String = "2023-06-01",
        defaultModel: String = "",
        systemPrompt: String = "",
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        supportsImages: Bool = true,
        listsModels: Bool = true
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiStyle = apiStyle
        self.authStyle = authStyle
        self.apiKeyHeader = apiKeyHeader
        self.apiKeyQueryParameter = apiKeyQueryParameter
        self.anthropicVersion = anthropicVersion
        self.defaultModel = defaultModel
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.supportsImages = supportsImages
        self.listsModels = listsModels
    }

    public var url: URL? {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether the `anthropic-version` header should be sent.
    public var sendsAnthropicVersion: Bool {
        get { !anthropicVersion.isEmpty }
        set { anthropicVersion = newValue ? "2023-06-01" : "" }
    }
}

/// Ready made configurations for the usual suspects.
public enum EndpointPresets {
    public static let all: [ProviderEndpoint] = [
        ProviderEndpoint(
            name: "LM Studio",
            baseURL: "http://localhost:1234/v1",
            apiStyle: .openAI,
            authStyle: .none,
            defaultModel: ""
        ),
        ProviderEndpoint(
            name: "Ollama",
            baseURL: "http://localhost:11434/v1",
            apiStyle: .openAI,
            authStyle: .none,
            defaultModel: ""
        ),
        ProviderEndpoint(
            name: "llama.cpp",
            baseURL: "http://localhost:8080/v1",
            apiStyle: .openAI,
            authStyle: .none,
            defaultModel: ""
        ),
        ProviderEndpoint(
            name: "vLLM",
            baseURL: "http://localhost:8000/v1",
            apiStyle: .openAI,
            authStyle: .none,
            defaultModel: ""
        ),
        ProviderEndpoint(
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            apiStyle: .openAI,
            authStyle: .bearer,
            defaultModel: "gpt-4o-mini"
        ),
        ProviderEndpoint(
            name: "Anthropic",
            baseURL: "https://api.anthropic.com",
            apiStyle: .anthropic,
            authStyle: .header,
            apiKeyHeader: "x-api-key",
            defaultModel: "claude-3-5-sonnet-latest"
        ),
    ]
}

/// Turns a base URL into concrete request URLs.
public enum EndpointResolver {

    public enum ResolutionError: LocalizedError {
        case invalidURL(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let value): return "'\(value)' is not a valid URL"
            }
        }
    }

    /// URL of the chat endpoint.
    public static func chatURL(baseURL: URL, style: APIStyle) -> URL {
        switch style {
        case .openAI:
            return baseURL.appendingPathComponent("chat/completions")
        case .anthropic:
            if hasV1Suffix(baseURL) {
                return baseURL.appendingPathComponent("messages")
            }
            return baseURL.appendingPathComponent("v1/messages")
        }
    }

    /// URL of the model list endpoint.
    public static func modelsURL(baseURL: URL, style: APIStyle) -> URL {
        switch style {
        case .openAI:
            return baseURL.appendingPathComponent("models")
        case .anthropic:
            if hasV1Suffix(baseURL) {
                return baseURL.appendingPathComponent("models")
            }
            return baseURL.appendingPathComponent("v1/models")
        }
    }

    /// OpenAI compatible servers almost always live under `/v1`; add it when the
    /// user typed a bare host so `http://localhost:1234` keeps working.
    public static func normalizedBaseURL(_ raw: String, style: APIStyle) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
        if components.scheme == nil {
            components.scheme = "http"
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        if style == .openAI && (path == "/" || path.isEmpty) {
            path = "/v1"
        }
        components.path = path
        return components.url
    }

    static func hasV1Suffix(_ url: URL) -> Bool {
        let path = url.path
        return path == "/v1" || path.hasSuffix("/v1")
    }
}
