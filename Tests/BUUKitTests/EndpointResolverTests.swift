import Foundation
import Testing
@testable import BUUKit

@Suite("Endpoint resolution")
struct EndpointResolverTests {

    @Test("OpenAI compatible URLs keep the version prefix")
    func openAIChatURLKeepsVersionedBase() {
        let base = URL(string: "http://localhost:1234/v1")!
        #expect(
            EndpointResolver.chatURL(baseURL: base, style: .openAI).absoluteString
                == "http://localhost:1234/v1/chat/completions"
        )
        #expect(
            EndpointResolver.modelsURL(baseURL: base, style: .openAI).absoluteString
                == "http://localhost:1234/v1/models"
        )
    }

    @Test("A bare host gets the /v1 prefix")
    func openAIBareHostGetsVersionPrefix() {
        let base = EndpointResolver.normalizedBaseURL("http://localhost:1234", style: .openAI)!
        #expect(base.absoluteString == "http://localhost:1234/v1")
        #expect(
            EndpointResolver.chatURL(baseURL: base, style: .openAI).absoluteString
                == "http://localhost:1234/v1/chat/completions"
        )
    }

    @Test("Anthropic compatible URLs")
    func anthropicURLs() {
        let base = URL(string: "https://api.anthropic.com")!
        #expect(
            EndpointResolver.chatURL(baseURL: base, style: .anthropic).absoluteString
                == "https://api.anthropic.com/v1/messages"
        )
        #expect(
            EndpointResolver.modelsURL(baseURL: base, style: .anthropic).absoluteString
                == "https://api.anthropic.com/v1/models"
        )
    }

    @Test("Anthropic URLs are not versioned twice")
    func anthropicWithVersionedBaseDoesNotDuplicate() {
        let base = URL(string: "https://proxy.example.com/v1")!
        #expect(
            EndpointResolver.chatURL(baseURL: base, style: .anthropic).absoluteString
                == "https://proxy.example.com/v1/messages"
        )
    }

    @Test("Trailing slashes are removed")
    func trailingSlashesAreRemoved() {
        let base = EndpointResolver.normalizedBaseURL("http://localhost:1234/v1/", style: .openAI)!
        #expect(base.absoluteString == "http://localhost:1234/v1")
    }

    @Test("Bearer authentication")
    func bearerAuthentication() throws {
        var endpoint = ProviderEndpoint(baseURL: "https://api.openai.com/v1", apiStyle: .openAI)
        endpoint.authStyle = .bearer
        let configuration = try ProviderConfiguration.make(endpoint: endpoint, apiKey: "secret")
        #expect(configuration.headers["Authorization"] == "Bearer secret")
    }

    @Test("Anthropic header authentication")
    func anthropicHeaderAuthentication() throws {
        var endpoint = ProviderEndpoint(baseURL: "https://api.anthropic.com", apiStyle: .anthropic)
        endpoint.authStyle = .header
        endpoint.apiKeyHeader = "x-api-key"
        let configuration = try ProviderConfiguration.make(endpoint: endpoint, apiKey: "secret")
        #expect(configuration.headers["x-api-key"] == "secret")
        #expect(configuration.headers["anthropic-version"] == "2023-06-01")
    }

    @Test("Query parameter authentication")
    func queryAuthentication() throws {
        var endpoint = ProviderEndpoint(baseURL: "https://api.example.com/v1", apiStyle: .openAI)
        endpoint.authStyle = .query
        endpoint.apiKeyQueryParameter = "key"
        let configuration = try ProviderConfiguration.make(endpoint: endpoint, apiKey: "secret")
        #expect(configuration.queryItems.first?.name == "key")
        #expect(configuration.queryItems.first?.value == "secret")
    }

    @Test("No authentication sends no credentials")
    func noAuthentication() throws {
        var endpoint = ProviderEndpoint(baseURL: "http://localhost:1234/v1", apiStyle: .openAI)
        endpoint.authStyle = .none
        let configuration = try ProviderConfiguration.make(endpoint: endpoint, apiKey: "secret")
        #expect(configuration.headers["Authorization"] == nil)
        #expect(configuration.queryItems.isEmpty)
    }
}
