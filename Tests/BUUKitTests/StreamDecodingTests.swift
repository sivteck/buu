import Foundation
import Testing
@testable import BUUKit

@Suite("Stream decoding")
struct StreamDecodingTests {

    @Test("OpenAI text deltas")
    func openAITextDelta() throws {
        var state = OpenAITransport.OpenAIStreamState()
        let event = SSEEvent(data: #"{"choices":[{"delta":{"content":"Hel"}}]}"#)
        let events = try OpenAITransport.events(from: event, state: &state)
        #expect(events.count == 1)
        guard case .text(let value) = events[0] else {
            Issue.record("expected a text event")
            return
        }
        #expect(value == "Hel")
    }

    @Test("OpenAI reasoning deltas")
    func openAIReasoningDelta() throws {
        var state = OpenAITransport.OpenAIStreamState()
        let event = SSEEvent(data: #"{"choices":[{"delta":{"reasoning_content":"think"}}]}"#)
        let events = try OpenAITransport.events(from: event, state: &state)
        guard case .reasoning(let value) = try #require(events.first) else {
            Issue.record("expected a reasoning event")
            return
        }
        #expect(value == "think")
    }

    @Test("OpenAI finish reason and usage")
    func openAIFinishReasonAndUsage() throws {
        var state = OpenAITransport.OpenAIStreamState()
        let event = SSEEvent(data: #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":4}}"#)
        _ = try OpenAITransport.events(from: event, state: &state)
        #expect(state.stopReason == .endTurn)
        #expect(state.usage?.inputTokens == 10)
        #expect(state.usage?.outputTokens == 4)
    }

    @Test("OpenAI error payloads are thrown")
    func openAIErrorPayloadThrows() {
        var state = OpenAITransport.OpenAIStreamState()
        let event = SSEEvent(data: #"{"error":{"message":"boom","type":"server_error"}}"#)
        #expect(throws: (any Error).self) {
            try OpenAITransport.events(from: event, state: &state)
        }
    }

    @Test("OpenAI model list")
    func openAIModelsParsing() throws {
        let json = #"{"data":[{"id":"qwen2.5-7b","owned_by":"lmstudio"},{"id":"llama-3"}]}"#
        let models = try OpenAITransport.parseModels(Data(json.utf8))
        #expect(models.map(\.id) == ["qwen2.5-7b", "llama-3"])
    }

    // MARK: - Anthropic

    @Test("Anthropic text deltas")
    func anthropicTextDelta() throws {
        var state = AnthropicTransport.AnthropicStreamState()
        let event = SSEEvent(name: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#)
        let events = try AnthropicTransport.events(from: event, state: &state)
        guard case .text(let value) = try #require(events.first) else {
            Issue.record("expected a text event")
            return
        }
        #expect(value == "Hi")
    }

    @Test("Anthropic thinking deltas")
    func anthropicThinkingDelta() throws {
        var state = AnthropicTransport.AnthropicStreamState()
        let event = SSEEvent(data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#)
        let events = try AnthropicTransport.events(from: event, state: &state)
        guard case .reasoning(let value) = try #require(events.first) else {
            Issue.record("expected a reasoning event")
            return
        }
        #expect(value == "hmm")
    }

    @Test("Anthropic message_start reports the model")
    func anthropicMessageStartReportsModel() throws {
        var state = AnthropicTransport.AnthropicStreamState()
        let event = SSEEvent(name: "message_start", data: #"{"type":"message_start","message":{"id":"m","model":"claude-x"}}"#)
        let events = try AnthropicTransport.events(from: event, state: &state)
        guard case .started(let model) = try #require(events.first) else {
            Issue.record("expected a started event")
            return
        }
        #expect(model == "claude-x")
    }

    @Test("Anthropic tool calls are assembled")
    func anthropicToolCallIsAssembled() throws {
        var state = AnthropicTransport.AnthropicStreamState()
        _ = try AnthropicTransport.events(
            from: SSEEvent(data: #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","name":"get_weather"}}"#),
            state: &state
        )
        _ = try AnthropicTransport.events(
            from: SSEEvent(data: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#),
            state: &state
        )
        let events = try AnthropicTransport.events(
            from: SSEEvent(data: #"{"type":"content_block_stop","index":1}"#),
            state: &state
        )
        guard case .toolCall(let name, let arguments) = try #require(events.first) else {
            Issue.record("expected a tool call event")
            return
        }
        #expect(name == "get_weather")
        #expect(arguments == "{\"city\":")
    }

    @Test("Anthropic message_delta sets the stop reason")
    func anthropicMessageDeltaSetsStopReason() throws {
        var state = AnthropicTransport.AnthropicStreamState()
        let event = SSEEvent(data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#)
        _ = try AnthropicTransport.events(from: event, state: &state)
        #expect(state.stopReason == .endTurn)
        #expect(state.usage?.outputTokens == 7)
    }

    @Test("Anthropic model list")
    func anthropicModelsParsing() throws {
        let json = #"{"data":[{"id":"claude-3-5-sonnet","display_name":"Claude 3.5"}]}"#
        let models = try AnthropicTransport.parseModels(Data(json.utf8))
        #expect(models.first?.id == "claude-3-5-sonnet")
        #expect(models.first?.displayName == "Claude 3.5")
    }
}
