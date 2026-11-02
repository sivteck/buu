import Foundation

/// An image stored alongside a conversation.
public struct ImageAttachment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// File name inside the attachments directory.
    public var fileName: String
    public var mimeType: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var byteCount: Int

    public init(
        id: UUID = UUID(),
        fileName: String,
        mimeType: String,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        byteCount: Int = 0
    ) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
    }
}

/// A single message inside a conversation.
public struct ChatTurn: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: MessageRole
    public var text: String
    public var images: [ImageAttachment]
    public var reasoning: String
    public var createdAt: Date
    public var errorMessage: String?
    public var stopReason: StopReason?
    public var usage: TokenUsage?
    /// Set while the assistant message is still being streamed.
    public var isStreaming: Bool
    /// Latency and throughput for this answer.
    public var metrics: TurnMetrics?

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String = "",
        images: [ImageAttachment] = [],
        reasoning: String = "",
        createdAt: Date = Date(),
        errorMessage: String? = nil,
        stopReason: StopReason? = nil,
        usage: TokenUsage? = nil,
        isStreaming: Bool = false,
        metrics: TurnMetrics? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.reasoning = reasoning
        self.createdAt = createdAt
        self.errorMessage = errorMessage
        self.stopReason = stopReason
        self.usage = usage
        self.isStreaming = isStreaming
        self.metrics = metrics
    }
}

/// A chat thread.
public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var endpointID: UUID
    public var endpointName: String
    public var model: String
    public var createdAt: Date
    public var updatedAt: Date
    public var turns: [ChatTurn]

    public init(
        id: UUID = UUID(),
        title: String = "New chat",
        endpointID: UUID,
        endpointName: String = "",
        model: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        turns: [ChatTurn] = []
    ) {
        self.id = id
        self.title = title
        self.endpointID = endpointID
        self.endpointName = endpointName
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
    }

    /// Derive a short title from the first user message.
    public static func makeTitle(from text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return "New chat" }
        return collapsed.count <= 48 ? collapsed : String(collapsed.prefix(48)) + "…"
    }
}
