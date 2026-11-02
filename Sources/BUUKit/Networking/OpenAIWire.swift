import Foundation

// MARK: - Request

struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: Content
    }

    enum Content: Encodable {
        case text(String)
        case parts([Part])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value): try container.encode(value)
            case .parts(let parts): try container.encode(parts)
            }
        }
    }

    struct Part: Encodable {
        let type: String
        let text: String?
        let imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }

        struct ImageURL: Encodable {
            let url: String
        }

        static func text(_ value: String) -> Part {
            Part(type: "text", text: value, imageURL: nil)
        }

        static func image(_ payload: ImagePayload) -> Part {
            Part(type: "image_url", text: nil, imageURL: ImageURL(url: payload.dataURL))
        }
    }

    struct StreamOptions: Encodable {
        let includeUsage: Bool

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    let model: String
    let messages: [Message]
    let stream: Bool
    let streamOptions: StreamOptions?
    let temperature: Double?
    let topP: Double?
    let maxTokens: Int?
    let stop: [String]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, stop
        case streamOptions = "stream_options"
        case topP = "top_p"
        case maxTokens = "max_tokens"
    }
}

// MARK: - Response (non streaming)

struct OpenAIChatResponse: Decodable {
    struct MessageContent: Decodable {
        let role: String?
        let content: String?
        let reasoningContent: String?
    }

    struct Choice: Decodable {
        let index: Int?
        let message: MessageContent?
        let delta: MessageContent?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, message, delta
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    let model: String?
    let choices: [Choice]?
    let usage: Usage?
    let error: OpenAIErrorPayload?

    var tokenUsage: TokenUsage? {
        guard let usage else { return nil }
        return TokenUsage(inputTokens: usage.promptTokens, outputTokens: usage.completionTokens)
    }
}

// MARK: - Streaming

struct OpenAIStreamChunk: Decodable {
    struct Delta: Decodable {
        let role: String?
        let content: String?
        let reasoningContent: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCall: Decodable {
        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }
        let index: Int?
        let id: String?
        let type: String?
        let function: Function?
    }

    struct Choice: Decodable {
        let index: Int?
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    /// llama.cpp reports `timings` on the final chunk.
    struct Timings: Decodable {
        let promptN: Int?
        let predictedN: Int?
        let promptPerSecond: Double?
        let predictedPerSecond: Double?

        enum CodingKeys: String, CodingKey {
            case promptN = "prompt_n"
            case predictedN = "predicted_n"
            case promptPerSecond = "prompt_per_second"
            case predictedPerSecond = "predicted_per_second"
        }
    }

    /// LM Studio reports `stats` on the final chunk.
    struct Stats: Decodable {
        let tokensPerSecond: Double?
        let timeToFirstToken: Double?

        enum CodingKeys: String, CodingKey {
            case tokensPerSecond = "tokens_per_second"
            case timeToFirstToken = "time_to_first_token"
        }
    }

    let model: String?
    let choices: [Choice]?
    let usage: Usage?
    let timings: Timings?
    let stats: Stats?
    let error: OpenAIErrorPayload?

    var tokenUsage: TokenUsage? {
        guard let usage else { return nil }
        return TokenUsage(inputTokens: usage.promptTokens, outputTokens: usage.completionTokens)
    }

    var serverTimings: ServerTimings? {
        var result = ServerTimings()

        if let timings {
            result.promptTokens = timings.promptN
            result.predictedTokens = timings.predictedN
            result.prefillTokensPerSecond = timings.promptPerSecond
            result.generationTokensPerSecond = timings.predictedPerSecond
        }

        if let stats {
            result.generationTokensPerSecond = result.generationTokensPerSecond ?? stats.tokensPerSecond
            result.timeToFirstToken = stats.timeToFirstToken
        }

        return result.isEmpty ? nil : result
    }
}

struct OpenAIErrorPayload: Decodable, Error {
    struct Payload: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }

    let message: String?
    let type: String?
    let code: String?

    var displayMessage: String {
        message ?? code ?? type ?? "Unknown API error"
    }
}
