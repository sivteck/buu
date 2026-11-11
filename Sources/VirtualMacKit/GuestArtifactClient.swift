import CryptoKit
import Foundation
import os
import VirtualMacCore

public struct GuestArtifactFolders: Sendable {
    public var artifactsRoot: String
    public var outputsRoot: String
    public var usedFallback: Bool
    public var home: String

    public init(artifactsRoot: String, outputsRoot: String, usedFallback: Bool, home: String) {
        self.artifactsRoot = artifactsRoot
        self.outputsRoot = outputsRoot
        self.usedFallback = usedFallback
        self.home = home
    }
}

public struct GuestFileInfo: Codable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var size: Int64
    public var modified: Date?
    public var type: String
    public var sha256: String?

    public init(name: String, path: String, size: Int64, modified: Date?, type: String, sha256: String? = nil) {
        self.name = name
        self.path = path
        self.size = size
        self.modified = modified
        self.type = type
        self.sha256 = sha256
    }
}

public struct GuestUploadResult: Sendable {
    public var path: String
    public var name: String
    public var size: Int64
    public var sha256: String
    public var renamed: Bool
    public var modified: Date?
}

public struct GuestReadResult: Sendable {
    public var name: String
    public var path: String
    public var data: Data
    public var mime: String
    public var kind: String
}

public struct GuestTextResult: Sendable {
    public var path: String
    public var text: String
    public var totalCharacters: Int
    public var truncated: Bool
}

public struct GuestOpenResult: Sendable {
    public var app: String
    public var windowTitle: String
    public var opened: Bool
    public var windowFound: Bool
    public var hint: String
}

public struct GuestFrontmostApp: Sendable {
    public var name: String
    public var bundleID: String
    public var pid: Int
}

public struct GuestWindowInfo: Codable, Hashable, Sendable {
    public var app: String
    public var bundleID: String
    public var title: String
}

/// Chunked guest file transport over the existing mailbox. The guest is the
/// authority for paths, collision naming, hashes, disk space and app launching.
public struct GuestArtifactClient: Sendable {
    private static let logger = Logger(subsystem: "com.buu.VirtualMac", category: "artifacts")
    public static let defaultTransferLimit: Int64 = 2 * 1_073_741_824
    public static let chunkSize = 512 * 1024

    private let exchange: URL

    public init(exchange: URL) {
        self.exchange = exchange
    }

    public func ensureFolders() async throws -> GuestArtifactFolders {
        let reply = try await call(Request(action: "artifact_ensure", timeout: 15))
        return GuestArtifactFolders(
            artifactsRoot: reply.values["artifactsRoot"] ?? "",
            outputsRoot: reply.values["outputsRoot"] ?? "",
            usedFallback: reply.values["fallback"] == "true",
            home: reply.values["home"] ?? ""
        )
    }

    public func put(
        hostURL: URL,
        name: String,
        root: String,
        transferID: String,
        limit: Int64 = defaultTransferLimit,
        sha256 providedHash: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> GuestUploadResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: hostURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= limit else {
            throw Failure("File is \(size) bytes; the configured transfer limit is \(limit) bytes. Raise Artifact transfer limit in the VM profile.")
        }
        let hash = try providedHash ?? Self.sha256(contentsOf: hostURL)
        Self.logger.info("put begin name=\(name, privacy: .public) size=\(size) root=\(root, privacy: .public)")
        let mailbox = try Mailbox(exchange)
        let begin = try await mailbox.call(Request(
            action: "artifact_put_begin",
            arguments: [
                "transferID": transferID,
                "name": name,
                "size": String(size),
                "sha256": hash,
                "root": root,
                "limit": String(limit),
            ],
            timeout: 30
        ))
        let offset = Int64(begin.values["offset"] ?? "0") ?? 0
        guard offset >= 0, offset <= size else {
            throw Failure("The guest reported an invalid resume offset.")
        }
        progress?(size == 0 ? 1 : Double(offset) / Double(size))
        let handle = try FileHandle(forReadingFrom: hostURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        do {
            var sent = offset
            while sent < size {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: Self.chunkSize) ?? Data()
                if data.isEmpty { break }
                let payloadName = "artifact-chunk-\(transferID)-\(sent).bin"
                try mailbox.write(data, named: payloadName)
                defer { mailbox.remove(payloadName) }
                _ = try await mailbox.call(Request(
                    action: "artifact_put_chunk",
                    arguments: [
                        "transferID": transferID,
                        "offset": String(sent),
                        "data": payloadName,
                    ],
                    timeout: 60
                ))
                sent += Int64(data.count)
                progress?(Double(sent) / Double(max(1, size)))
            }
            let commit = try await mailbox.call(Request(
                action: "artifact_put_commit",
                arguments: ["transferID": transferID],
                timeout: 120
            ))
            progress?(1)
            let modified = commit.values["modified"].flatMap { value in
                ISO8601DateFormatter().date(from: value)
            }
            let result = GuestUploadResult(
                path: commit.values["path"] ?? "",
                name: commit.values["name"] ?? name,
                size: Int64(commit.values["size"] ?? "") ?? size,
                sha256: commit.values["sha256"] ?? hash,
                renamed: commit.values["renamed"] == "true",
                modified: modified
            )
            Self.logger.info("put commit path=\(result.path, privacy: .public) sha=\(result.sha256, privacy: .public)")
            return result
        } catch {
            Self.logger.error("put failed name=\(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Keep the guest's partial file so the next attempt resumes at its
            // size. Explicit aborts are reserved for cancellation/cleanup.
            throw error
        }
    }

    public func put(
        data: Data,
        name: String,
        root: String,
        transferID: String,
        limit: Int64 = defaultTransferLimit,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> GuestUploadResult {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(".buu-put-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try await put(
            hostURL: temp,
            name: name,
            root: root,
            transferID: transferID,
            limit: limit,
            progress: progress
        )
    }

    public func delete(path: String) async throws {
        _ = try await call(Request(action: "artifact_delete", arguments: ["path": path], timeout: 15))
    }

    public func list(root: String) async throws -> [GuestFileInfo] {
        let action = root == "outputs" ? "artifact_outputs" : "artifact_list"
        let reply = try await call(Request(action: action, arguments: ["root": root], timeout: 20))
        return try Self.decodeList(reply.values["files"])
    }

    public func open(path: String, app: String? = nil) async throws -> GuestOpenResult {
        var args = ["path": path]
        if let app, !app.isEmpty { args["app"] = app }
        Self.logger.info("open path=\(path, privacy: .public) app=\(app ?? "default", privacy: .public)")
        let reply = try await call(Request(action: "artifact_open", arguments: args, timeout: 30))
        return GuestOpenResult(
            app: reply.values["app"] ?? "",
            windowTitle: reply.values["windowTitle"] ?? "",
            opened: reply.values["opened"] == "true",
            windowFound: reply.values["windowFound"] == "true",
            hint: reply.values["hint"] ?? ""
        )
    }

    public func reveal(path: String) async throws {
        _ = try await call(Request(action: "artifact_reveal", arguments: ["path": path], timeout: 15))
    }

    public func openFolder(root: String) async throws {
        _ = try await call(Request(action: "artifact_open_folder", arguments: ["root": root], timeout: 15))
    }

    public func read(path: String) async throws -> GuestReadResult {
        let mailbox = try Mailbox(exchange)
        let reply = try await mailbox.call(Request(action: "artifact_read", arguments: ["path": path], timeout: 30))
        guard let name = reply.values["data"] else { throw Failure("The guest did not return artifact data.") }
        defer { mailbox.remove(name) }
        guard let data = try mailbox.read(name, limit: 12 * 1024 * 1024) else {
            throw Failure("The guest artifact payload was missing.")
        }
        return GuestReadResult(
            name: reply.values["name"] ?? URL(fileURLWithPath: path).lastPathComponent,
            path: reply.values["path"] ?? path,
            data: data,
            mime: reply.values["mime"] ?? "application/octet-stream",
            kind: reply.values["kind"] ?? "binary"
        )
    }

    public func extractText(path: String, pages: String? = nil) async throws -> GuestTextResult {
        let mailbox = try Mailbox(exchange)
        var args = ["path": path]
        if let pages, !pages.isEmpty { args["pages"] = pages }
        let reply = try await mailbox.call(Request(action: "artifact_extract_text", arguments: args, timeout: 120))
        guard let name = reply.values["text"] else { throw Failure("The guest did not return extracted text.") }
        defer { mailbox.remove(name) }
        guard let data = try mailbox.read(name, limit: 2 * 1024 * 1024) else {
            throw Failure("The guest text payload was missing.")
        }
        return GuestTextResult(
            path: reply.values["path"] ?? path,
            text: String(decoding: data, as: UTF8.self),
            totalCharacters: Int(reply.values["characters"] ?? "") ?? 0,
            truncated: reply.values["truncated"] == "true"
        )
    }

    public func fetch(
        path: String,
        to destination: URL,
        limit: Int64 = defaultTransferLimit,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> GuestFileInfo {
        let mailbox = try Mailbox(exchange)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".buu-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        var offset: Int64 = 0
        var total: Int64 = 0
        var info: GuestFileInfo?
        do {
            while true {
                try Task.checkCancellation()
                let reply = try await mailbox.call(Request(
                    action: "artifact_get_chunk",
                    arguments: [
                        "path": path,
                        "offset": String(offset),
                        "length": String(Self.chunkSize),
                    ],
                    timeout: 60
                ))
                guard let name = reply.values["data"] else { throw Failure("The guest did not return a file chunk.") }
                defer { mailbox.remove(name) }
                guard let data = try mailbox.read(name, limit: 2 * 1024 * 1024) else {
                    throw Failure("The guest file chunk was missing.")
                }
                if data.isEmpty { break }
                try output.write(contentsOf: data)
                offset += Int64(data.count)
                total = Int64(reply.values["size"] ?? "") ?? total
                if total > limit {
                    throw Failure("Output is \(total) bytes; the transfer limit is \(limit) bytes.")
                }
                progress?(total > 0 ? Double(offset) / Double(total) : 0)
                info = GuestFileInfo(
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    path: path,
                    size: total,
                    modified: nil,
                    type: reply.values["type"] ?? ""
                )
                if reply.values["eof"] == "true" { break }
            }
            try output.close()
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temp, to: destination)
            let hash = try Self.sha256(contentsOf: destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int(total)
            Self.logger.info("fetch path=\(path, privacy: .public) bytes=\(size) sha=\(hash, privacy: .public)")
            info = GuestFileInfo(
                name: destination.lastPathComponent,
                path: path,
                size: Int64(size),
                modified: Date(),
                type: info?.type ?? "",
                sha256: hash
            )
            progress?(1)
            return info ?? GuestFileInfo(name: destination.lastPathComponent, path: path, size: Int64(size), modified: Date(), type: "", sha256: hash)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    public func frontmostApp() async throws -> GuestFrontmostApp {
        let reply = try await call(Request(action: "guest_frontmost_app", timeout: 10))
        return GuestFrontmostApp(
            name: reply.values["name"] ?? "",
            bundleID: reply.values["bundleID"] ?? "",
            pid: Int(reply.values["pid"] ?? "") ?? 0
        )
    }

    public func windows() async throws -> [GuestWindowInfo] {
        let reply = try await call(Request(action: "guest_list_windows", timeout: 15))
        guard let raw = reply.values["windows"], let data = raw.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([GuestWindowInfo].self, from: data)
    }

    /// The guest FSEvents watcher writes this marker when BUU Outputs changes.
    public func consumeOutputsDirty() throws -> Bool {
        let mailbox = try Mailbox(exchange)
        let dirty = try mailbox.read("outputs.dirty") != nil
        if dirty { mailbox.remove("outputs.dirty") }
        return dirty
    }

    private func call(_ request: Request) async throws -> Reply {
        let mailbox = try Mailbox(exchange)
        return try await mailbox.call(request)
    }

    private static func decodeList(_ raw: String?) throws -> [GuestFileInfo] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GuestFileInfo].self, from: data)
    }

    private static func sha256(contentsOf url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 512 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

