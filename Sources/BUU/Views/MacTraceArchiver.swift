import Foundation
import BUUKit

enum MacTraceArchiver {
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    @discardableResult
    static func save(
        rootURL: URL,
        task: AgenticTaskRecord,
        status: String,
        log: [String],
        screenshots: [TraceScreenshot],
        toolCalls: [ToolCall],
        runStartedAt: Date?,
        finishedAt: Date,
        contextCleared: Bool
    ) throws -> URL {
        let outcome = MacTraceOutcome.classify(
            status: status,
            log: log,
            contextCleared: contextCleared
        )
        let runState: MacRunState = switch status {
        case "completed": .finished
        case "failed": .failed
        case "paused", "cancelled", "stopped": .paused
        default: .finished
        }
        let parsed = MacTraceParser.parse(
            log: log,
            toolCalls: toolCalls,
            screenshots: screenshots,
            runState: runState,
            runStartedAt: runStartedAt,
            finishedAt: finishedAt
        )
        let rendered = MacTraceParser.exportLines(parsed)
        let stamp = stampFormatter.string(from: finishedAt)
        let categoryFolder = rootURL.appendingPathComponent(outcome.rawValue, isDirectory: true)
        let taskFolder = categoryFolder.appendingPathComponent(sanitize(task.title), isDirectory: true)
        try FileManager.default.createDirectory(at: taskFolder, withIntermediateDirectories: true)

        let base = "\(stamp)-\(sanitize(task.title))"
        let markdownURL = taskFolder.appendingPathComponent("\(base).md")
        let jsonURL = taskFolder.appendingPathComponent("\(base).json")
        let screenshotFolder = taskFolder.appendingPathComponent("\(base)-screenshots", isDirectory: true)

        let markdown = markdown(
            task: task,
            status: status,
            outcome: outcome,
            savedAt: finishedAt,
            log: log,
            rendered: rendered
        )
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        let metadata = screenshots.map {
            MacTraceAutosavePayload.ScreenshotMetadata(
                id: $0.id,
                round: $0.round,
                createdAt: $0.createdAt,
                byteCount: $0.png.count
            )
        }
        let payload = MacTraceAutosavePayload(
            taskID: task.id,
            title: task.title,
            status: status,
            outcome: outcome,
            savedAt: finishedAt,
            prompt: task.prompt ?? "",
            rounds: parsed.rounds.filter { !$0.isSynthetic }.count,
            log: log,
            renderedTrace: rendered,
            screenshots: metadata
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: jsonURL, options: .atomic)

        if !screenshots.isEmpty {
            try? FileManager.default.createDirectory(at: screenshotFolder, withIntermediateDirectories: true)
            for screenshot in screenshots {
                let name = "round-\(screenshot.round)-\(screenshot.id.uuidString.lowercased()).png"
                try? screenshot.png.write(to: screenshotFolder.appendingPathComponent(name), options: .atomic)
            }
        }
        return markdownURL
    }

    private static func markdown(
        task: AgenticTaskRecord,
        status: String,
        outcome: MacTraceOutcome,
        savedAt: Date,
        log: [String],
        rendered: [String]
    ) -> String {
        var text = "# \(task.title)\n\n"
        text += "- Task ID: `\(task.id.uuidString)`\n"
        text += "- Status: \(status)\n"
        text += "- Outcome: \(outcome.rawValue)\n"
        text += "- Saved: \(savedAt.formatted(date: .complete, time: .standard))\n"
        text += "- Attachment count: \(task.artifacts?.count ?? 0)\n\n"
        if let prompt = task.prompt, !prompt.isEmpty {
            text += "## Prompt\n\n\(prompt)\n\n"
        }
        text += "## Rounds\n\n"
        text += rendered.isEmpty ? "(no rendered rounds)\n" : rendered.joined(separator: "\n") + "\n"
        text += "\n## Raw log\n\n"
        text += log.isEmpty ? "(no log entries)\n" : log.joined(separator: "\n") + "\n"
        return text
    }

    private static func sanitize(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
    }
}
