import Foundation

/// Converts a conversation into a server agnostic request.
public enum ChatRequestBuilder {

    /// - Parameters:
    ///   - turns: The conversation so far.
    ///   - attachments: Binary payload for every referenced attachment.
    ///   - system: System prompt (usually from the endpoint settings).
    public static func build(
        turns: [ChatTurn],
        attachments: [UUID: Data],
        system: String?,
        model: String,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        tools: [ToolDefinition] = []
    ) -> ChatRequest {
        var messages: [ChatMessage] = []

        for turn in turns {
            // Tool results are transient during a tool loop; persisted turns do
            // not carry the call id needed to replay them.
            guard !turn.isStreaming, turn.role != .tool else { continue }
            var blocks: [ContentBlock] = []
            if !turn.text.isEmpty {
                blocks.append(.text(turn.text))
            }
            for image in turn.images {
                guard let data = attachments[image.id] else { continue }
                blocks.append(.image(ImagePayload(mimeType: image.mimeType, data: data)))
            }
            guard !blocks.isEmpty else { continue }
            messages.append(ChatMessage(
                role: turn.role,
                blocks: blocks,
                reasoning: turn.role == .assistant && !turn.reasoning.isEmpty ? turn.reasoning : nil
            ))
        }

        return ChatRequest(
            model: model,
            messages: messages,
            system: system,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            tools: tools
        )
    }
}
