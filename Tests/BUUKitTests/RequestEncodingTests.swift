import Foundation
import Testing
@testable import BUUKit

@Suite("Request encoding")
struct RequestEncodingTests {

    private func decode(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    // MARK: - OpenAI

    @Test("Text messages are encoded as strings")
    func openAIBodyContainsTextMessages() throws {
        let request = ChatRequest(
            model: "gpt-4o-mini",
            messages: [ChatMessage(role: .user, text: "Hello")],
            system: "Be brief",
            temperature: 0.5,
            maxTokens: 256
        )
        let body = try OpenAITransport.makeBody(request)
        let json = try decode(body)

        #expect(json["model"] as? String == "gpt-4o-mini")
        #expect(json["stream"] as? Bool == true)
        #expect(json["max_tokens"] as? Int == 256)
        #expect(json["temperature"] as? Double == 0.5)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "Be brief")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "Hello")
    }

    @Test("Images are encoded as data URLs")
    func openAIBodyEncodesImagesAsDataURL() throws {
        let payload = ImagePayload(mimeType: "image/jpeg", data: Data([0x01, 0x02, 0x03]))
        let request = ChatRequest(
            model: "vision",
            messages: [ChatMessage(role: .user, blocks: [.text("What is this?"), .image(payload)])]
        )
        let body = try OpenAITransport.makeBody(request)
        let json = try decode(body)

        let messages = try #require(json["messages"] as? [[String: Any]])
        let parts = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts[0]["type"] as? String == "text")
        #expect(parts[0]["text"] as? String == "What is this?")
        #expect(parts[1]["type"] as? String == "image_url")

        let imageURL = try #require(parts[1]["image_url"] as? [String: Any])
        let url = try #require(imageURL["url"] as? String)
        #expect(url.hasPrefix("data:image/jpeg;base64,"))
    }

    // MARK: - Anthropic

    @Test("The system prompt uses the dedicated field")
    func anthropicBodyUsesSystemFieldAndContentBlocks() throws {
        let payload = ImagePayload(mimeType: "image/png", data: Data([0x10, 0x20]))
        let request = ChatRequest(
            model: "claude-3-5-sonnet-latest",
            messages: [ChatMessage(role: .user, blocks: [.text("Describe"), .image(payload)])],
            system: "You are helpful",
            maxTokens: 1024
        )
        let body = try AnthropicTransport.makeBody(request)
        let json = try decode(body)

        #expect(json["model"] as? String == "claude-3-5-sonnet-latest")
        #expect(json["max_tokens"] as? Int == 1024)
        #expect(json["stream"] as? Bool == true)

        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.first?["type"] as? String == "text")
        #expect(system.first?["text"] as? String == "You are helpful")

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")

        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "text")
        #expect(content[1]["type"] as? String == "image")

        let source = try #require(content[1]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == "ECA=")
    }

    @Test("Consecutive messages with the same role are merged")
    func anthropicMergesConsecutiveSameRoleMessages() throws {
        let request = ChatRequest(
            model: "claude",
            messages: [
                ChatMessage(role: .user, text: "first"),
                ChatMessage(role: .user, text: "second")
            ]
        )
        let body = try AnthropicTransport.makeBody(request)
        let json = try decode(body)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.count == 2)
    }

    @Test("System role messages are not sent as messages")
    func anthropicIgnoresSystemRoleMessages() throws {
        let request = ChatRequest(
            model: "claude",
            messages: [
                ChatMessage(role: .system, text: "ignored"),
                ChatMessage(role: .user, text: "hello")
            ]
        )
        let body = try AnthropicTransport.makeBody(request)
        let json = try decode(body)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
    }

    // MARK: - Conversation -> request

    @Test("Images are attached to the matching turn")
    func chatRequestBuilderIncludesImages() {
        let attachment = ImageAttachment(fileName: "a.jpg", mimeType: "image/jpeg")
        let turns = [
            ChatTurn(role: .user, text: "hi", images: [attachment]),
            ChatTurn(role: .assistant, text: "hello", isStreaming: false)
        ]
        let request = ChatRequestBuilder.build(
            turns: turns,
            attachments: [attachment.id: Data([0x01])],
            system: nil,
            model: "m"
        )
        #expect(request.messages.count == 2)
        #expect(request.messages[0].blocks.count == 2)
        #expect(request.messages[1].text == "hello")
    }
}
