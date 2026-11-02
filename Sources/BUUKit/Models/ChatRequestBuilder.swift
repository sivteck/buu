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
        maxTokens: Int? = nil
    ) -> ChatRequest {
        var messages: [ChatMessage] = []

        for turn in turns {
            guard !turn.isStreaming else { continue }
            var blocks: [ContentBlock] = []
            if !turn.text.isEmpty {
                blocks.append(.text(turn.text))
            }
            for image in turn.images {
                guard let data = attachments[image.id] else { continue }
                blocks.append(.image(ImagePayload(mimeType: image.mimeType, data: data)))
            }
            guard !blocks.isEmpty else { continue }
            messages.append(ChatMessage(role: turn.role, blocks: blocks))
        }

        return ChatRequest(
            model: model,
            messages: messages,
            system: system,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens
        )
    }
}
