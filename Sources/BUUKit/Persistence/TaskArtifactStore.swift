import Foundation

/// A file attached to an agentic task. The bytes live in the task's private
/// artifact directory; only this lightweight metadata is persisted in settings.
public enum TaskArtifactGuestState: String, Codable, Hashable, Sendable {
    case queued
    case copying
    case inGuest
    case opened
    case modified
    case failed
}

public struct TaskArtifact: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Original display name.
    public var name: String
    /// Unique, sanitized name inside the task directory.
    public var fileName: String
    public var byteCount: Int
    public var addedAt: Date

    public var sha256: String?
    public var guestName: String?
    public var guestPath: String?
    public var guestState: TaskArtifactGuestState?
    public var guestProgress: Double?
    public var guestByteCount: Int?
    public var lastError: String?
    public var guestModifiedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        byteCount: Int,
        addedAt: Date = Date(),
        sha256: String? = nil,
        guestName: String? = nil,
        guestPath: String? = nil,
        guestState: TaskArtifactGuestState? = nil,
        guestProgress: Double? = nil,
        guestByteCount: Int? = nil,
        lastError: String? = nil,
        guestModifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.byteCount = byteCount
        self.addedAt = addedAt
        self.sha256 = sha256
        self.guestName = guestName
        self.guestPath = guestPath
        self.guestState = guestState
        self.guestProgress = guestProgress
        self.guestByteCount = guestByteCount
        self.lastError = lastError
        self.guestModifiedAt = guestModifiedAt
    }
}

public struct TaskOutput: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var guestPath: String
    public var hostFileName: String
    public var byteCount: Int
    public var sha256: String?
    public var producedAt: Date
    public var guestModifiedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        guestPath: String,
        hostFileName: String,
        byteCount: Int,
        sha256: String? = nil,
        producedAt: Date = Date(),
        guestModifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.guestPath = guestPath
        self.hostFileName = hostFileName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.producedAt = producedAt
        self.guestModifiedAt = guestModifiedAt
    }
}

/// Copies task attachments into a stable per-task folder and gives the agent
/// tools a contained place to read and write files.
public struct TaskArtifactStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.rootURL = base
                .appendingPathComponent("BUU", isDirectory: true)
                .appendingPathComponent("Artifacts", isDirectory: true)
        }
    }

    public func directory(for taskID: UUID) -> URL {
        rootURL.appendingPathComponent(taskID.uuidString.lowercased(), isDirectory: true)
    }

    public func outputsDirectory(for taskID: UUID) -> URL {
        directory(for: taskID).appendingPathComponent("Outputs", isDirectory: true)
    }

    public func url(for artifact: TaskArtifact, taskID: UUID) -> URL {
        directory(for: taskID).appendingPathComponent(artifact.fileName, isDirectory: false)
    }

    public func copy(url source: URL, taskID: UUID, id: UUID = UUID()) throws -> TaskArtifact {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory != true else {
            throw TaskArtifactError.directoryUnsupported(source.lastPathComponent)
        }
        let directory = directory(for: taskID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let originalName = sanitized(source.lastPathComponent)
        let fileName = uniqueFileName(for: originalName, in: directory)
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return TaskArtifact(
            id: id,
            name: originalName,
            fileName: fileName,
            byteCount: size
        )
    }

    public func write(data: Data, name: String, taskID: UUID, id: UUID = UUID()) throws -> TaskArtifact {
        let directory = directory(for: taskID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalName = sanitized(name)
        let fileName = uniqueFileName(for: originalName, in: directory)
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: destination, options: .atomic)
        return TaskArtifact(
            id: id,
            name: originalName,
            fileName: fileName,
            byteCount: data.count
        )
    }

    public func read(_ artifact: TaskArtifact, taskID: UUID) throws -> Data {
        try Data(contentsOf: url(for: artifact, taskID: taskID))
    }

    public func remove(_ artifact: TaskArtifact, taskID: UUID) {
        try? FileManager.default.removeItem(at: url(for: artifact, taskID: taskID))
    }

    public func removeDirectory(for taskID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: taskID))
    }

    public func sha256(for artifact: TaskArtifact, taskID: UUID) throws -> String {
        try SHA256.hash(contentsOf: url(for: artifact, taskID: taskID))
    }

    public func sha256(of url: URL) throws -> String {
        try SHA256.hash(contentsOf: url)
    }

    public func contents(for taskID: UUID) -> [URL] {
        let directory = directory(for: taskID)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func uniqueFileName(for name: String, in directory: URL) -> String {
        let url = URL(fileURLWithPath: name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = name
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }

    private func sanitized(_ value: String) -> String {
        let base = URL(fileURLWithPath: value).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." { return "artifact" }
        return String(base.prefix(180))
    }
}

public enum TaskArtifactError: LocalizedError {
    case directoryUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .directoryUnsupported(let name):
            return "“\(name)” is a folder. Attach individual files instead."
        }
    }
}
