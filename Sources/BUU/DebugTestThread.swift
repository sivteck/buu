import Foundation
import BUUKit

/// Generates a long conversation that mixes short replies, 9-row tables and
/// 300-line code blocks — the shapes that used to make scrolling jumpy.
enum TestThreadFactory {

    static func turns(count: Int) -> [ChatTurn] {
        (0..<count).map { index in
            makeTurn(index: index)
        }
    }

    private static func makeTurn(index: Int) -> ChatTurn {
        switch index % 6 {
        case 0:
            return ChatTurn(
                role: .user,
                text: "Message \(index + 1): show me the numbers."
            )

        case 1:
            return ChatTurn(
                role: .assistant,
                text: "Short reply \(index + 1). Two lines at most, just to vary the row heights.",
                usage: TokenUsage(inputTokens: 120, outputTokens: 24)
            )

        case 2:
            return ChatTurn(
                role: .user,
                text: "do a table"
            )

        case 3:
            return ChatTurn(
                role: .assistant,
                text: "Here is the overview for batch \(index + 1):\n\n" + table(index: index),
                reasoning: "Build a 9-row table with seven columns and long cells.",
                usage: TokenUsage(inputTokens: 1970, outputTokens: 1447)
            )

        case 4:
            return ChatTurn(
                role: .assistant,
                text: "A three hundred line implementation:\n\n```swift\n" + code(index: index) + "\n```",
                usage: TokenUsage(inputTokens: 640, outputTokens: 4302)
            )

        default:
            return ChatTurn(
                role: .assistant,
                text: """
                Paragraph reply \(index + 1). A few sentences that wrap over several lines so the \
                transcript has a realistic mix of row heights while scrolling in both directions.

                - first bullet with `inline code`
                - second bullet with a [link](https://example.com)
                """,
                usage: TokenUsage(inputTokens: 310, outputTokens: 96)
            )
        }
    }

    private static func table(index: Int) -> String {
        var lines = [
            "| # | Thumbnail text | Channel | Views | Published | Duration | Notes |",
            "|:--|:--|:--|--:|:--|--:|:-:|",
        ]

        for row in 1...9 {
            lines.append(
                "| \(row) | Row \(row) of table \(index + 1) — a deliberately long thumbnail title that has to wrap | channel-\(row) | \(row * 12_345),678 | 2024-11-0\(row % 9 + 1) | \(10 + row):42 | **note \(row)** |"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func code(index: Int) -> String {
        (1...300)
            .map { line in
                "let value\(line) = decoder.decode(chunk) // batch \(index + 1), line \(line)"
            }
            .joined(separator: "\n")
    }
}

extension AppState {

    /// Inserts a generated conversation and selects it.
    func loadTestThread(messageCount: Int = 200) {
        let endpoint = activeEndpoint
        var conversation = Conversation(
            endpointID: endpoint?.id ?? UUID(),
            endpointName: endpoint?.name ?? "test",
            model: currentModel.isEmpty ? "test-model" : currentModel
        )
        conversation.title = "Load test · \(messageCount) messages"
        conversation.turns = TestThreadFactory.turns(count: messageCount)
        conversation.updatedAt = Date()

        conversations.insert(conversation, at: 0)
        activeConversationID = conversation.id
        MessageCache.shared.warm(conversation.turns)
    }

    /// State used by the "Load test thread" previews.
    static func debugPreviewState(messageCount: Int) -> AppState {
        let state = AppState()
        state.loadTestThread(messageCount: messageCount)
        return state
    }
}
