import Foundation

public enum SteerState: String, Codable, Hashable, Sendable, CaseIterable {
    case queued
    case applying
    case applied
    case cancelled
    case failed
}

public struct SteerItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    /// IDs in the owning task's `artifacts` array.
    public var attachmentIDs: [UUID]
    public var createdAt: Date
    public var state: SteerState
    public var appliedInRound: Int?
    public var appliedAt: Date?
    public var order: Int
    public var failure: String?

    public init(
        id: UUID = UUID(),
        text: String,
        attachmentIDs: [UUID] = [],
        createdAt: Date = Date(),
        state: SteerState = .queued,
        appliedInRound: Int? = nil,
        appliedAt: Date? = nil,
        order: Int = 0,
        failure: String? = nil
    ) {
        self.id = id
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.createdAt = createdAt
        self.state = state
        self.appliedInRound = appliedInRound
        self.appliedAt = appliedAt
        self.order = order
        self.failure = failure
    }

    public var isPending: Bool {
        state == .queued || state == .applying || state == .failed
    }
}

public enum QueuedTaskState: String, Codable, Hashable, Sendable, CaseIterable {
    case queued
    case running
    case done
    case failed
    case cancelled
}

public enum VMStatePolicy: String, Codable, Hashable, Sendable, CaseIterable {
    case keepState
    case freshState

    public var title: String {
        switch self {
        case .keepState: return "Continue from current VM state"
        case .freshState: return "Fresh VM state"
        }
    }

    public var detail: String {
        switch self {
        case .keepState:
            return "Keep running apps and the guest desktop as they are."
        case .freshState:
            return "Start with a fresh model context and restart the guest runtime. Disk changes remain; this build does not restore a base disk snapshot."
        }
    }
}

public struct QueuedTask: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var prompt: String
    /// IDs in the owning task's `artifacts` array.
    public var attachmentIDs: [UUID]
    public var providerID: UUID?
    public var model: String?
    /// nil or 0 means the workspace/task default.
    public var maxRounds: Int?
    public var vmStatePolicy: VMStatePolicy
    public var continueConversation: Bool
    public var state: QueuedTaskState
    public var order: Int
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        prompt: String,
        attachmentIDs: [UUID] = [],
        providerID: UUID? = nil,
        model: String? = nil,
        maxRounds: Int? = nil,
        vmStatePolicy: VMStatePolicy = .freshState,
        continueConversation: Bool = false,
        state: QueuedTaskState = .queued,
        order: Int = 0,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.attachmentIDs = attachmentIDs
        self.providerID = providerID
        self.model = model
        self.maxRounds = maxRounds
        self.vmStatePolicy = vmStatePolicy
        self.continueConversation = continueConversation
        self.state = state
        self.order = order
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastError = lastError
    }

    public var title: String {
        let first = prompt.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? prompt
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled task" : String(trimmed.prefix(100))
    }

    public var isPending: Bool { state == .queued }
}

/// Small screenshot captured during a run. Kept per workspace so trace camera
/// rows can show the screenshot from that exact action, not the latest frame.
public struct TraceScreenshot: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var round: Int
    public var createdAt: Date
    public var png: Data

    public init(id: UUID = UUID(), round: Int, createdAt: Date = Date(), png: Data) {
        self.id = id
        self.round = round
        self.createdAt = createdAt
        self.png = png
    }
}

public struct MacRunHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var status: String
    public var startedAt: Date?
    public var finishedAt: Date
    public var rounds: Int
    public var prompt: String
    public var attachmentIDs: [UUID]
    public var log: [String]
    public var screenshotIDs: [UUID]

    public init(
        id: UUID = UUID(),
        title: String,
        status: String,
        startedAt: Date?,
        finishedAt: Date = Date(),
        rounds: Int,
        prompt: String,
        attachmentIDs: [UUID] = [],
        log: [String] = [],
        screenshotIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.rounds = rounds
        self.prompt = prompt
        self.attachmentIDs = attachmentIDs
        self.log = log
        self.screenshotIDs = screenshotIDs
    }

    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }
}

public enum SteerPlanner {
    public static let maxPending = 10

    public static func pending(_ items: [SteerItem]) -> [SteerItem] {
        items.filter(\.isPending).sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.createdAt < rhs.createdAt : lhs.order < rhs.order
        }
    }

    public static func canMutate(_ item: SteerItem) -> Bool {
        item.state == .queued
    }

    public static func nextOrder(_ items: [SteerItem]) -> Int {
        (items.map(\.order).max() ?? -1) + 1
    }

    public static func normalized(_ items: [SteerItem]) -> [SteerItem] {
        var copy = items.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.createdAt < rhs.createdAt : lhs.order < rhs.order
        }
        for index in copy.indices {
            copy[index].order = index
        }
        return copy
    }
}

public enum QueuedTaskPlanner {
    public static func next(_ tasks: [QueuedTask]) -> QueuedTask? {
        tasks.filter(\.isPending).sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.createdAt < rhs.createdAt : lhs.order < rhs.order
        }.first
    }

    public static func shouldStopOnFailure(_ task: QueuedTask, stopOnFailure: Bool) -> Bool {
        stopOnFailure && task.state == .failed
    }
}
