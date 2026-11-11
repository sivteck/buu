import Foundation
import Testing
@testable import BUUKit

/// End to end tests: a real HTTP request goes out and the SSE answer comes
/// back through the transports.
@Suite("End to end", .serialized)
struct IntegrationTests {

    private func endpoint(_ server: MockHTTPServer, style: APIStyle) -> ProviderEndpoint {
        ProviderEndpoint(
            name: "mock",
            baseURL: "http://127.0.0.1:\(server.port)/v1",
            apiStyle: style,
            authStyle: .none
        )
    }

    @Test("An OpenAI server streams deltas")
    func openAIStreamIsDecoded() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"Hello"}}]}

        data: {"choices":[{"delta":{"content":" world"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}

        data: [DONE]

        """
        let server = try MockHTTPServer(contentType: "text/event-stream", body: sse)
        server.start()
        defer { server.stop() }

        let client = try ProviderClient(endpoint: endpoint(server, style: .openAI), apiKey: nil)
        let request = ChatRequest(model: "test-model", messages: [ChatMessage(role: .user, text: "Hi")])

        var text = ""
        var reason: StopReason?
        var usage: TokenUsage?
        for try await event in client.stream(request: request) {
            switch event {
            case .text(let chunk): text += chunk
            case .finished(let stop, let reported): reason = stop; usage = reported
            default: break
            }
        }

        #expect(text == "Hello world")
        #expect(reason == .endTurn)
        #expect(usage?.inputTokens == 3)
        #expect(usage?.outputTokens == 2)

        let requests = server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.method == "POST")
        #expect(requests.first?.path == "/v1/chat/completions")
        #expect(requests.first?.body.contains("\"model\":\"test-model\"") == true)
    }

    @Test("An Anthropic server streams content blocks")
    func anthropicStreamIsDecoded() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m","model":"claude-test"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let server = try MockHTTPServer(contentType: "text/event-stream", body: sse)
        server.start()
        defer { server.stop() }

        let client = try ProviderClient(endpoint: endpoint(server, style: .anthropic), apiKey: nil)
        let request = ChatRequest(model: "claude-test", messages: [ChatMessage(role: .user, text: "Hi")])

        var text = ""
        var model: String?
        var reason: StopReason?
        for try await event in client.stream(request: request) {
            switch event {
            case .text(let chunk): text += chunk
            case .started(let startedModel): model = startedModel
            case .finished(let stop, _): reason = stop
            default: break
            }
        }

        #expect(text == "Hi there")
        #expect(model == "claude-test")
        #expect(reason == .endTurn)

        let requests = server.requests
        #expect(requests.first?.path == "/v1/messages")
        #expect(requests.first?.body.contains("\"max_tokens\"") == true)
    }

    @Test("A server that ignores stream:true still works")
    func plainJSONResponseIsAccepted() async throws {
        let json = """
        {"model":"m","choices":[{"message":{"role":"assistant","content":"Complete answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2}}
        """
        let server = try MockHTTPServer(contentType: "application/json", body: json)
        server.start()
        defer { server.stop() }

        let client = try ProviderClient(endpoint: endpoint(server, style: .openAI), apiKey: nil)
        let request = ChatRequest(model: "m", messages: [ChatMessage(role: .user, text: "Hi")])

        var text = ""
        for try await event in client.stream(request: request) {
            if case .text(let chunk) = event { text += chunk }
        }
        #expect(text == "Complete answer")
    }

    @Test("The model list is fetched from the server")
    func modelListing() async throws {
        let json = #"{"data":[{"id":"model-a"},{"id":"model-b"}]}"#
        let server = try MockHTTPServer(contentType: "application/json", body: json)
        server.start()
        defer { server.stop() }

        let client = try ProviderClient(endpoint: endpoint(server, style: .openAI), apiKey: nil)
        let models = try await client.listModels()
        #expect(models.map(\.id) == ["model-a", "model-b"])
        #expect(server.requests.first?.path == "/v1/models")
    }

    @Test("Streaming HTTP errors keep the server body")
    func streamErrorBodyIsPreserved() async throws {
        let body = #"{"error":{"message":"tool_calls require content null"}}"#
        let server = try MockHTTPServer(contentType: "application/json", body: body, status: 400)
        server.start()
        defer { server.stop() }

        let client = try ProviderClient(endpoint: endpoint(server, style: .openAI), apiKey: nil)
        let request = ChatRequest(model: "m", messages: [ChatMessage(role: .user, text: "Hi")])

        do {
            for try await _ in client.stream(request: request) { }
            Issue.record("expected the stream to fail")
        } catch let error as HTTPError {
            #expect(error.statusCode == 400)
            #expect(error.body.contains("tool_calls require content null"))
            #expect(error.errorDescription?.contains("tool_calls require content null") == true)
        }
    }

    @Test("HTTP errors are reported")
    func serverErrorIsReported() async throws {
        let server = try MockHTTPServer(contentType: "application/json", body: #"{"error":{"message":"nope"}}"#, status: 401)
        server.start()
        defer { server.stop() }

        let client = try ProviderClient(endpoint: endpoint(server, style: .openAI), apiKey: nil)
        let request = ChatRequest(model: "m", messages: [ChatMessage(role: .user, text: "Hi")])

        var caught: Error?
        do {
            for try await _ in client.stream(request: request) { }
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }
}
