import Foundation
import Testing
@testable import BUUKit

@Suite("Tool wire")
struct ToolWireTests {
    private let tool = ToolDefinition(
        name: "vm_click",
        description: "Click the guest.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "x": .object(["type": .string("integer")]),
                "y": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("x"), .string("y")]),
        ])
    )

    private func object(_ data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        return try #require(value as? [String: Any])
    }

    @Test("OpenAI encodes tool definitions, calls and results")
    func openAITools() throws {
        let call = ToolCall(id: "call_vm", name: "vm_click", arguments: #"{"x":10,"y":20}"#)
        let request = ChatRequest(
            model: "m",
            messages: [
                ChatMessage(role: .assistant, text: "", toolCalls: [call], reasoning: "I will click."),
                .toolResult(callID: "call_vm", name: "vm_click", text: "Clicked."),
            ],
            tools: [tool]
        )
        let json = try object(try OpenAITransport.makeBody(request))
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages[0]["role"] as? String == "assistant")
        #expect(messages[0]["content"] is NSNull)
        #expect(messages[0]["reasoning_content"] as? String == "I will click.")
        #expect((messages[0]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call_vm")
        #expect(messages[1]["role"] as? String == "tool")
        #expect(messages[1]["tool_call_id"] as? String == "call_vm")
    }

    @Test("Anthropic encodes input schemas, tool_use and tool_result")
    func anthropicTools() throws {
        let call = ToolCall(id: "call_vm", name: "vm_click", arguments: #"{"x":10,"y":20}"#)
        let request = ChatRequest(
            model: "claude",
            messages: [
                ChatMessage(role: .assistant, text: "", toolCalls: [call]),
                .toolResult(callID: "call_vm", name: "vm_click", text: "Clicked."),
            ],
            tools: [tool]
        )
        let json = try object(try AnthropicTransport.makeBody(request))
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "vm_click")
        #expect(tools.first?["input_schema"] != nil)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(assistant.first?["type"] as? String == "tool_use")
        let user = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(user.first?["type"] as? String == "tool_result")
    }
}
