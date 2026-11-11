import Foundation

// MARK: - Request

struct AnthropicMessageRequest: Encodable {
    struct TextBlock: Encodable {
        let type: String = "text"
        let text: String
    }

    struct ImageSource: Encodable {
        let type: String = "base64"
        let mediaType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }

    struct TextContent: Encodable {
        let type: String = "text"
        let text: String
    }

    struct ImageContent: Encodable {
        let type: String = "image"
        let source: ImageSource
    }

    struct ToolUseContent: Encodable {
        let type: String = "tool_use"
        let id: String
        let name: String
        let input: JSONValue
    }

    struct ToolResultContent: Encodable {
        let type: String = "tool_result"
        let toolUseID: String
        let content: String
        let isError: Bool?

        enum CodingKeys: String, CodingKey {
            case type, content
            case toolUseID = "tool_use_id"
            case isError = "is_error"
        }
    }

    enum Content: Encodable {
        case text(TextContent)
        case image(ImageContent)
        case toolUse(ToolUseContent)
        case toolResult(ToolResultContent)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value):
                try container.encode(value)
            case .image(let value):
                try container.encode(value)
            case .toolUse(let value):
                try container.encode(value)
            case .toolResult(let value):
                try container.encode(value)
            }
        }
    }

    struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    struct Tool: Encodable {
        let name: String
        let description: String
        let inputSchema: JSONValue

        enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "input_schema"
        }

        init(_ definition: ToolDefinition) {
            self.name = definition.name
            self.description = definition.description
            self.inputSchema = definition.parameters
        }
    }

    let model: String
    let maxTokens: Int
    let system: [TextBlock]?
    let messages: [Message]
    let temperature: Double?
    let topP: Double?
    let stream: Bool
    let stopSequences: [String]?
    let tools: [Tool]?

    enum CodingKeys: String, CodingKey {
        case model, system, messages, temperature, stream, tools
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case stopSequences = "stop_sequences"
    }
}

// MARK: - Response (non streaming)

struct AnthropicMessageResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
        let thinking: String?
        let id: String?
        let name: String?
        let input: JSONValue?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    let id: String?
    let model: String?
    let role: String?
    let content: [Block]?
    let stopReason: String?
    let usage: Usage?
    let error: AnthropicErrorPayload?

    enum CodingKeys: String, CodingKey {
        case id, model, role, content, usage, error
        case stopReason = "stop_reason"
    }

    var text: String {
        (content ?? []).compactMap { $0.text }.joined()
    }

    var reasoning: String {
        (content ?? []).compactMap { $0.thinking }.joined()
    }

    var tokenUsage: TokenUsage? {
        guard let usage else { return nil }
        return TokenUsage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens)
    }
}

struct AnthropicErrorPayload: Decodable, Error {
    let type: String?
    let message: String?

    var displayMessage: String {
        message ?? type ?? "Unknown API error"
    }
}

// MARK: - Streaming

struct AnthropicStreamEvent: Decodable {
    struct MessageStart: Decodable {
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?

            struct Usage: Decodable {
                let inputTokens: Int?
                let outputTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case outputTokens = "output_tokens"
                }
            }
        }
        let message: Message?
    }

    struct ContentBlock: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let id: String?
        let name: String?
    }

    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let partialJSON: String?
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case type, text, thinking
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
        }
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    let type: String?
    let index: Int?
    let message: MessageStart.Message?
    let contentBlock: ContentBlock?
    let delta: Delta?
    let usage: Usage?
    let error: AnthropicErrorPayload?

    enum CodingKeys: String, CodingKey {
        case type, index, message, usage, error
        case contentBlock = "content_block"
        case delta
    }
}
