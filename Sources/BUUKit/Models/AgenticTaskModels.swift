import Foundation

/// A named virtual-Mac recipe used by Mac Tasks.
public struct MacTaskConfiguration: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var machineName: String
    /// Optional path to a local `.ipsw`/raw restore image. Empty means download
    /// Apple's latest compatible image.
    public var restoreImagePath: String?
    public var cpus: Int
    public var memoryGiB: Int
    public var diskGiB: Int
    public var width: Int
    public var height: Int
    public var network: Bool
    public var scale: Int

    // Optional profile metadata. Optional so settings written before the
    // profile redesign keep decoding.
    public var profileDescription: String?
    public var macOSVersion: String?
    public var architecture: String?
    public var imageType: String?
    public var storageLocation: String?
    public var sharedFolderEnabled: Bool?
    public var graphicsMode: String?
    /// Maximum artifact transfer size in GiB. nil means the 2 GiB default.
    public var artifactTransferLimitGiB: Int?
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String = "New Mac task",
        machineName: String = "default",
        restoreImagePath: String? = nil,
        cpus: Int = 4,
        memoryGiB: Int = 4,
        diskGiB: Int = 64,
        width: Int = 1280,
        height: Int = 800,
        network: Bool = true,
        scale: Int = 2,
        profileDescription: String? = nil,
        macOSVersion: String? = nil,
        architecture: String? = "arm64",
        imageType: String? = "ipsw",
        storageLocation: String? = nil,
        sharedFolderEnabled: Bool? = true,
        graphicsMode: String? = "automatic",
        artifactTransferLimitGiB: Int? = 2,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.machineName = machineName
        self.restoreImagePath = restoreImagePath
        self.cpus = cpus
        self.memoryGiB = memoryGiB
        self.diskGiB = diskGiB
        self.width = width
        self.height = height
        self.network = network
        self.scale = scale
        self.profileDescription = profileDescription
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.imageType = imageType
        self.storageLocation = storageLocation
        self.sharedFolderEnabled = sharedFolderEnabled
        self.graphicsMode = graphicsMode
        self.artifactTransferLimitGiB = artifactTransferLimitGiB
        self.lastUsedAt = lastUsedAt
    }
}

/// Which agentic surface a task belongs to.
public enum AgenticTaskKind: String, Codable, Hashable, Sendable, CaseIterable {
    case agent
    case mac
}

/// A compact, Codable form of one agent-loop message. Image blocks are not
/// persisted; a resumed loop can take a fresh screenshot when needed.
public struct AgentLoopMessage: Codable, Hashable, Sendable {
    public var role: MessageRole
    public var text: String
    public var reasoning: String?
    public var toolCalls: [ToolCall]
    public var toolCallID: String?
    public var toolName: String?
    public var toolIsError: Bool?

    public init(
        role: MessageRole,
        text: String = "",
        reasoning: String? = nil,
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolIsError: Bool? = nil
    ) {
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolIsError = toolIsError
    }

    public init(_ message: ChatMessage) {
        self.init(
            role: message.role,
            text: message.text,
            reasoning: message.reasoning,
            toolCalls: message.toolCalls,
            toolCallID: message.toolCallID,
            toolName: message.toolName,
            toolIsError: message.toolIsError
        )
    }

    public var chatMessage: ChatMessage {
        ChatMessage(
            role: role,
            blocks: text.isEmpty ? [] : [.text(text)],
            toolCalls: toolCalls,
            toolCallID: toolCallID,
            toolName: toolName,
            toolIsError: toolIsError,
            reasoning: reasoning
        )
    }
}

/// A user-created task lane. It references a reusable configuration profile and
/// owns its own remote task / VM state while the task is tracked in the sidebar.
public struct AgenticTaskRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: AgenticTaskKind
    public var title: String
    public var configurationID: UUID
    public var createdAt: Date
    public var prompt: String?
    public var lastStatus: String?
    public var lastRunAt: Date?
    /// Persisted Mac Task agent history, so Resume can continue rather than restart.
    public var agentLoop: [AgentLoopMessage]?
    public var agentLog: [String]?
    /// nil or 0 means unlimited.
    public var maxAgentRounds: Int?
    /// Files copied into this task's private artifact directory.
    public var artifacts: [TaskArtifact]?
    /// Files produced in the guest's BUU Outputs folder and synced to the host.
    public var outputs: [TaskOutput]?
    /// Persistent steer queue for this Mac workspace.
    public var steers: [SteerItem]?
    /// Tasks that run after the current run in this workspace.
    public var queuedTasks: [QueuedTask]?
    public var queueStopOnFailure: Bool?
    public var queuePaused: Bool?
    /// Historical trace screenshot thumbnails for this workspace.
    public var traceScreenshots: [TraceScreenshot]?
    /// Completed/paused/failed run summaries for the run switcher.
    public var runHistory: [MacRunHistoryEntry]?
    /// Non-nil while this Mac Task is waiting in the sequential run queue.
    public var queuedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: AgenticTaskKind,
        title: String,
        configurationID: UUID,
        createdAt: Date = Date(),
        prompt: String? = nil,
        lastStatus: String? = nil,
        lastRunAt: Date? = nil,
        agentLoop: [AgentLoopMessage]? = nil,
        agentLog: [String]? = nil,
        maxAgentRounds: Int? = nil,
        artifacts: [TaskArtifact]? = nil,
        outputs: [TaskOutput]? = nil,
        steers: [SteerItem]? = nil,
        queuedTasks: [QueuedTask]? = nil,
        queueStopOnFailure: Bool? = true,
        queuePaused: Bool? = false,
        traceScreenshots: [TraceScreenshot]? = nil,
        runHistory: [MacRunHistoryEntry]? = nil,
        queuedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.configurationID = configurationID
        self.createdAt = createdAt
        self.prompt = prompt
        self.lastStatus = lastStatus
        self.lastRunAt = lastRunAt
        self.agentLoop = agentLoop
        self.agentLog = agentLog
        self.maxAgentRounds = maxAgentRounds
        self.artifacts = artifacts
        self.outputs = outputs
        self.steers = steers
        self.queuedTasks = queuedTasks
        self.queueStopOnFailure = queueStopOnFailure
        self.queuePaused = queuePaused
        self.traceScreenshots = traceScreenshots
        self.runHistory = runHistory
        self.queuedAt = queuedAt
    }
}
