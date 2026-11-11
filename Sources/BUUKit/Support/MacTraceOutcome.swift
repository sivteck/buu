import Foundation

/// Folder categories for automatically archived Mac task traces.
public enum MacTraceOutcome: String, CaseIterable, Codable, Hashable, Sendable {
    case fullySuccessful = "Fully Successful"
    case partialSuccess = "Partial Success"
    case failure = "Failure"
    case stoppedMidway = "Stopped Midway"
    case contextCleared = "User Cleared Context"

    public static func classify(
        status: String,
        log: [String],
        contextCleared: Bool
    ) -> MacTraceOutcome {
        if contextCleared { return .contextCleared }
        switch status {
        case "failed":
            return .failure
        case "paused", "cancelled", "stopped":
            return .stoppedMidway
        case "completed":
            let tail = log.suffix(120).joined(separator: "\n").lowercased()
            let hadProblems = tail.contains("error:")
                || tail.contains("failed")
                || tail.contains("were not applied")
                || tail.contains("interrupt")
            return hadProblems ? .partialSuccess : .fullySuccessful
        default:
            return .stoppedMidway
        }
    }
}

public struct MacTraceAutosavePayload: Codable, Sendable {
    public var taskID: UUID
    public var title: String
    public var status: String
    public var outcome: MacTraceOutcome
    public var savedAt: Date
    public var prompt: String
    public var rounds: Int
    public var log: [String]
    public var renderedTrace: [String]
    public var screenshots: [ScreenshotMetadata]

    public struct ScreenshotMetadata: Codable, Sendable {
        public var id: UUID
        public var round: Int
        public var createdAt: Date
        public var byteCount: Int

        public init(id: UUID, round: Int, createdAt: Date, byteCount: Int) {
            self.id = id
            self.round = round
            self.createdAt = createdAt
            self.byteCount = byteCount
        }
    }

    public init(
        taskID: UUID,
        title: String,
        status: String,
        outcome: MacTraceOutcome,
        savedAt: Date,
        prompt: String,
        rounds: Int,
        log: [String],
        renderedTrace: [String],
        screenshots: [ScreenshotMetadata]
    ) {
        self.taskID = taskID
        self.title = title
        self.status = status
        self.outcome = outcome
        self.savedAt = savedAt
        self.prompt = prompt
        self.rounds = rounds
        self.log = log
        self.renderedTrace = renderedTrace
        self.screenshots = screenshots
    }
}
