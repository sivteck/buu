import Foundation

/// A server agnostic client that speaks either the OpenAI or the Anthropic
/// protocol, depending on the endpoint configuration.
public protocol InferenceClient: Sendable {
    func listModels() async throws -> [RemoteModel]
    func stream(request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

public struct ProviderClient: InferenceClient {
    public let configuration: ProviderConfiguration

    public init(configuration: ProviderConfiguration) {
        self.configuration = configuration
    }

    public init(endpoint: ProviderEndpoint, apiKey: String?) throws {
        self.configuration = try ProviderConfiguration.make(endpoint: endpoint, apiKey: apiKey)
    }

    public func listModels() async throws -> [RemoteModel] {
        switch configuration.style {
        case .openAI:
            return try await OpenAITransport(configuration: configuration).listModels()
        case .anthropic:
            return try await AnthropicTransport(configuration: configuration).listModels()
        }
    }

    public func stream(request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        switch configuration.style {
        case .openAI:
            return OpenAITransport(configuration: configuration).stream(request)
        case .anthropic:
            return AnthropicTransport(configuration: configuration).stream(request)
        }
    }
}
