import AppKit
import Foundation
import BUUKit

/// Saves user-selected logs to a file chosen in a standard save panel.
struct MacTraceExport: Codable {
    var generatedAt: Date
    var taskID: UUID
    var title: String
    var steers: [SteerItem]
    var queuedTasks: [QueuedTask]
    var log: [String]
    var renderedTrace: [String]?
}

@MainActor
enum LogExporter {
    static func export(
        title: String,
        suggestedName: String,
        sections: [(String, [String])]
    ) -> String? {
        let text = readableText(title: title, sections: sections)
        let panel = NSSavePanel()
        panel.title = "Export logs"
        panel.prompt = "Export"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func readableText(title: String, sections: [(String, [String])]) -> String {
        var text = "# \(title)\n"
        text += "Generated: \(Date().formatted(date: .abbreviated, time: .standard))\n\n"
        for (heading, lines) in sections {
            text += "## \(heading)\n"
            text += lines.isEmpty ? "(no entries)\n" : lines.joined(separator: "\n") + "\n"
            text += "\n"
        }
        return text
    }

    static func exportJSON<T: Encodable>(
        title: String,
        suggestedName: String,
        value: T
    ) -> String? {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = "Export"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func steerLines(_ items: [SteerItem]) -> [String] {
        items.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.createdAt < rhs.createdAt : lhs.order < rhs.order
        }.map { item in
            var parts = [
                "id=\(item.id)",
                "state=\(item.state.rawValue)",
                "order=\(item.order)",
                "created=\(item.createdAt.ISO8601Format())",
            ]
            if let round = item.appliedInRound { parts.append("round=\(round)") }
            if let appliedAt = item.appliedAt { parts.append("appliedAt=\(appliedAt.ISO8601Format())") }
            if !item.attachmentIDs.isEmpty { parts.append("attachments=\(item.attachmentIDs.map(\.uuidString).joined(separator: ","))") }
            if let failure = item.failure { parts.append("failure=\(failure)") }
            let prefix: String
            switch item.state {
            case .queued: prefix = "Steer queued"
            case .applying: prefix = "Steer applying"
            case .applied: prefix = "You steered"
            case .cancelled: prefix = "Steer cancelled by user"
            case .failed: prefix = "Steer failed"
            }
            return prefix + " [user-originated] " + parts.joined(separator: " ") + " text=\(item.text)"
        }
    }

    static func queuedTaskLines(_ tasks: [QueuedTask]) -> [String] {
        tasks.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.createdAt < rhs.createdAt : lhs.order < rhs.order
        }.map { task in
            var parts = [
                "id=\(task.id)",
                "state=\(task.state.rawValue)",
                "order=\(task.order)",
                "created=\(task.createdAt.ISO8601Format())",
                "vm=\(task.vmStatePolicy.rawValue)",
                "continueConversation=\(task.continueConversation)",
            ]
            if let provider = task.providerID { parts.append("provider=\(provider.uuidString)") }
            if let model = task.model { parts.append("model=\(model)") }
            if let rounds = task.maxRounds { parts.append("maxRounds=\(rounds)") }
            if let started = task.startedAt { parts.append("started=\(started.ISO8601Format())") }
            if let finished = task.finishedAt { parts.append("finished=\(finished.ISO8601Format())") }
            if let error = task.lastError { parts.append("error=\(error)") }
            return "Queued task [user-originated] " + parts.joined(separator: " ") + " prompt=\(task.prompt)"
        }
    }

    static func reasoningTraceLines(_ messages: [AgentLoopMessage]) -> [String] {
        var lines: [String] = []
        for (index, message) in messages.enumerated() {
            lines.append("### \(index + 1). \(message.role.rawValue)")
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                lines.append("reasoning_content:")
                lines.append(reasoning)
            }
            if !message.text.isEmpty {
                lines.append("content:")
                lines.append(message.text)
            }
            for call in message.toolCalls {
                lines.append("tool_call: \(call.name) id=\(call.id) arguments=\(call.arguments)")
            }
            if let callID = message.toolCallID {
                lines.append("tool_result: id=\(callID) name=\(message.toolName ?? "") error=\(message.toolIsError == true)")
            }
            lines.append("")
        }
        return lines
    }


}
