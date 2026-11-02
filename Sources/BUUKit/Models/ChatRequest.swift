import Foundation

/// Role of a chat message.
public enum MessageRole: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .user: return "You"
        case .assistant: return "Assistant"
        }
    }
}

/// An image that is sent along with a message.
public struct ImagePayload: Codable, Hashable, Sendable {
    public var mimeType: String
    public var data: Data

    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }

    /// `data:<mime>;base64,<payload>` – the format the OpenAI API expects.
    public var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

/// A single piece of message content.
public enum ContentBlock: Sendable, Hashable {
    case text(String)
    case image(ImagePayload)

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var image: ImagePayload? {
        if case .image(let value) = self { return value }
        return nil
    }
}

/// A message in the neutral representation used by the app.
public struct ChatMessage: Sendable, Hashable {
    public var role: MessageRole
    public var blocks: [ContentBlock]

    public init(role: MessageRole, blocks: [ContentBlock]) {
        self.role = role
        self.blocks = blocks
    }

    public init(role: MessageRole, text: String) {
        self.init(role: role, blocks: text.isEmpty ? [] : [.text(text)])
    }

    public var text: String {
        blocks.compactMap(\.text).joined(separator: "\n")
    }

    public var images: [ImagePayload] {
        blocks.compactMap(\.image)
    }
}

/// A request in the neutral representation used by the app.
public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var system: String?
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var stopSequences: [String]

    public init(
        model: String,
        messages: [ChatMessage],
        system: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        stopSequences: [String] = []
    ) {
        self.model = model
        self.messages = messages
        self.system = system
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
    }
}

/// A model as advertised by a server.
public struct RemoteModel: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var ownedBy: String?

    public init(id: String, displayName: String? = nil, ownedBy: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
        self.ownedBy = ownedBy
    }
}

/// Token accounting, when the server reports it.
public struct TokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Prompt + completion: how many tokens the model holds after this turn.
    public var contextTokens: Int? {
        guard let inputTokens, let outputTokens else { return nil }
        return inputTokens + outputTokens
    }

    public var summary: String? {
        switch (inputTokens, outputTokens) {
        case let (input?, output?): return "\(input) in / \(output) out"
        case let (input?, nil): return "\(input) in"
        case let (nil, output?): return "\(output) out"
        default: return nil
        }
    }
}

/// Why generation stopped.
public enum StopReason: String, Codable, Sendable {
    case endTurn
    case maxTokens
    case stopSequence
    case toolUse
    case cancelled
    case error
    case unknown

    public init(wireValue: String?) {
        guard let wireValue else { self = .unknown; return }
        switch wireValue {
        case "stop", "end_turn": self = .endTurn
        case "length", "max_tokens": self = .maxTokens
        case "stop_sequence": self = .stopSequence
        case "tool_use", "tool_calls": self = .toolUse
        case "cancelled": self = .cancelled
        case "error": self = .error
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .endTurn: return "Finished"
        case .maxTokens: return "Hit token limit"
        case .stopSequence: return "Stopped by sequence"
        case .toolUse: return "Tool use"
        case .cancelled: return "Cancelled"
        case .error: return "Error"
        case .unknown: return "Finished"
        }
    }
}
