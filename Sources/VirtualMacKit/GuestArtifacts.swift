import AppKit
import ApplicationServices
import CoreServices
import CryptoKit
import Foundation
import os
import PDFKit
import Vision
import VirtualMacCore

/// Files live in the logged-in guest user's Desktop so Finder, Preview, TextEdit
/// and other GUI apps can use them. A copy is preferred over exposing the host
/// folder writable: the guest never gets a writable handle to the host original.
@MainActor
final class GuestArtifactService {
    private static let logger = Logger(subsystem: "com.buu.VirtualMac", category: "guest-artifacts")
    static let inlineReadLimit = 8 * 1024 * 1024
    static let textExtractLimit = 1_000_000

    let mailbox: Mailbox
    private(set) var artifactsRoot: URL
    private(set) var outputsRoot: URL
    private(set) var usedFallback = false
    private var transfers: [String: Transfer] = [:]
    private var outputWatcher: GuestOutputWatcher?

    private struct Transfer {
        var root: URL
        var temporary: URL
        var expectedSize: Int
        var expectedSHA256: String
        var desiredName: String
    }

    init(mailbox: Mailbox) throws {
        self.mailbox = mailbox
        let home = FileManager.default.homeDirectoryForCurrentUser
        let preferredArtifacts = home.appendingPathComponent("Desktop/BUU Artifacts", isDirectory: true)
        let preferredOutputs = home.appendingPathComponent("Desktop/BUU Outputs", isDirectory: true)
        do {
            try Self.prepare(preferredArtifacts)
            try Self.prepare(preferredOutputs)
            artifactsRoot = preferredArtifacts
            outputsRoot = preferredOutputs
        } catch {
            // Desktop can be blocked by Files-and-Folders TCC. Fall back to a
            // writable home folder and report the actual path to the host.
            usedFallback = true
            artifactsRoot = home.appendingPathComponent("BUU Artifacts", isDirectory: true)
            outputsRoot = home.appendingPathComponent("BUU Outputs", isDirectory: true)
            try Self.prepare(artifactsRoot)
            try Self.prepare(outputsRoot)
        }
        let watcher = GuestOutputWatcher(path: outputsRoot.path, mailbox: mailbox)
        watcher.start()
        outputWatcher = watcher
    }

    func handle(action: String, arguments: [String: String]) async throws -> [String: String] {
        switch action {
        case "artifact_ensure":
            return foldersReply()
        case "artifact_open_folder":
            let root = try root(for: arguments["root"] ?? "artifacts")
            guard NSWorkspace.shared.open(root) else { throw GuestArtifactError.appFailed("Finder could not open \(root.path)") }
            return ["path": root.path]
        case "artifact_list":
            return try list(arguments)
        case "artifact_put_begin":
            return try putBegin(arguments)
        case "artifact_put_chunk":
            return try putChunk(arguments)
        case "artifact_put_commit":
            return try putCommit(arguments)
        case "artifact_put_abort":
            if let id = arguments["transferID"], let transfer = transfers.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: transfer.temporary)
                try? FileManager.default.removeItem(at: transfer.temporary.deletingPathExtension().appendingPathExtension("json"))
            }
            return [:]
        case "artifact_delete":
            let url = try resolve(arguments["path"] ?? "")
            guard url.path != artifactsRoot.path, url.path != outputsRoot.path else {
                throw GuestArtifactError.permissionDenied("Refusing to delete an artifact root folder")
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw GuestArtifactError.notFound(url.path)
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw GuestArtifactError.permissionDenied("Only files can be deleted")
            }
            try FileManager.default.removeItem(at: url)
            Self.logger.info("delete path=\(url.path, privacy: .public)")
            return ["path": url.path]
        case "artifact_read":
            return try readInline(arguments)
        case "artifact_extract_text":
            return try await extractText(arguments)
        case "artifact_open":
            return try await open(arguments)
        case "artifact_reveal":
            let url = try resolve(arguments["path"] ?? "")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw GuestArtifactError.notFound(url.path)
            }
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            return ["path": url.path]
        case "artifact_get_chunk":
            return try getChunk(arguments)
        case "artifact_outputs":
            return try list(arguments.merging(["root": "outputs"]) { $1 })
        case "guest_frontmost_app":
            let app = NSWorkspace.shared.frontmostApplication
            return [
                "name": app?.localizedName ?? "",
                "bundleID": app?.bundleIdentifier ?? "",
                "pid": app.map { String($0.processIdentifier) } ?? "",
            ]
        case "guest_list_windows":
            return try listWindows()
        default:
            throw GuestArtifactError.unknown(action)
        }
    }

    func foldersReply() -> [String: String] {
        [
            "artifactsRoot": artifactsRoot.path,
            "outputsRoot": outputsRoot.path,
            "fallback": String(usedFallback),
            "home": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
    }

    // MARK: - Upload

    private func putBegin(_ arguments: [String: String]) throws -> [String: String] {
        let transferID = try required("transferID", arguments)
        guard transferID.range(of: "^[A-Za-z0-9-]{1,80}$", options: .regularExpression) != nil else {
            throw GuestArtifactError.invalid("Invalid transfer id")
        }
        let size = Int(arguments["size"] ?? "") ?? -1
        guard size >= 0 else { throw GuestArtifactError.invalid("Invalid transfer size") }
        let limit = Int64(arguments["limit"] ?? "") ?? 2 * 1_073_741_824
        guard Int64(size) <= limit else {
            throw GuestArtifactError.tooLarge("File is \(size) bytes; the configured transfer limit is \(limit) bytes")
        }
        let desired = try sanitizedName(required("name", arguments))
        let sha = try required("sha256", arguments)
        guard sha.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw GuestArtifactError.invalid("Invalid SHA-256")
        }
        let root = try root(for: arguments["root"] ?? "artifacts")
        try Self.requireFreeSpace(at: root, bytes: Int64(size))
        let temporary = root.appendingPathComponent(".buu-part-\(transferID)")
        let sidecar = root.appendingPathComponent(".buu-part-\(transferID).json")
        var offset = 0
        let previous = (try? Data(contentsOf: sidecar)).flatMap {
            try? JSONDecoder().decode([String: String].self, from: $0)
        }
        if previous?["sha256"] == sha, previous?["size"] == String(size),
           let values = try? temporary.resourceValues(forKeys: [.fileSizeKey]),
           let existing = values.fileSize, existing <= size {
            offset = existing
        } else {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: sidecar)
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
        }
        try JSONEncoder().encode(["sha256": sha, "size": String(size)]).write(to: sidecar, options: .atomic)
        Self.logger.info("put begin id=\(transferID, privacy: .public) name=\(desired, privacy: .public) size=\(size) offset=\(offset)")
        transfers[transferID] = Transfer(
            root: root,
            temporary: temporary,
            expectedSize: size,
            expectedSHA256: sha,
            desiredName: desired
        )
        return ["offset": String(offset), "temporary": temporary.lastPathComponent, "root": root.path]
    }

    private func putChunk(_ arguments: [String: String]) throws -> [String: String] {
        let transferID = try required("transferID", arguments)
        guard let transfer = transfers[transferID] else {
            throw GuestArtifactError.invalid("Unknown transfer; call artifact_put_begin again")
        }
        let offset = Int(arguments["offset"] ?? "") ?? -1
        guard offset >= 0, offset <= transfer.expectedSize else {
            throw GuestArtifactError.invalid("Invalid chunk offset")
        }
        let dataName = try required("data", arguments)
        guard let data = try mailbox.read(dataName, limit: 8 * 1024 * 1024) else {
            throw GuestArtifactError.notFound("Chunk payload \(dataName)")
        }
        mailbox.remove(dataName)
        guard offset + data.count <= transfer.expectedSize else {
            throw GuestArtifactError.invalid("Chunk exceeds declared size")
        }
        let handle = try FileHandle(forWritingTo: transfer.temporary)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        return ["offset": String(offset + data.count)]
    }

    private func putCommit(_ arguments: [String: String]) throws -> [String: String] {
        let transferID = try required("transferID", arguments)
        guard let transfer = transfers.removeValue(forKey: transferID) else {
            throw GuestArtifactError.invalid("Unknown transfer; call artifact_put_begin again")
        }
        let sidecar = transfer.temporary.deletingPathExtension().appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: sidecar) }
        let values = try transfer.temporary.resourceValues(forKeys: [.fileSizeKey])
        let size = values.fileSize ?? -1
        guard size == transfer.expectedSize else {
            try? FileManager.default.removeItem(at: transfer.temporary)
            throw GuestArtifactError.checksum("Size mismatch: expected \(transfer.expectedSize), received \(size)")
        }
        let hash = try Self.sha256(contentsOf: transfer.temporary)
        guard hash == transfer.expectedSHA256 else {
            try? FileManager.default.removeItem(at: transfer.temporary)
            throw GuestArtifactError.checksum("SHA-256 mismatch; the copy was discarded. It will resume from zero next time")
        }
        let requested = transfer.root.appendingPathComponent(transfer.desiredName)
        let destination: Uniqueness
        if FileManager.default.fileExists(atPath: requested.path),
           (try? Self.sha256(contentsOf: requested)) == hash,
           ((try? requested.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) == size {
            destination = Uniqueness(url: requested, renamed: false)
        } else {
            destination = try Self.uniqueDestination(for: transfer.desiredName, in: transfer.root)
        }
        if destination.url == requested, FileManager.default.fileExists(atPath: requested.path) {
            try? FileManager.default.removeItem(at: transfer.temporary)
            return [
                "path": destination.url.path,
                "name": destination.url.lastPathComponent,
                "size": String(size),
                "sha256": hash,
                "renamed": "false",
                "modified": Self.modifiedString(destination.url),
            ]
        }
        try FileManager.default.moveItem(at: transfer.temporary, to: destination.url)
        Self.logger.info("put commit path=\(destination.url.path, privacy: .public) sha=\(hash, privacy: .public)")
        return [
            "path": destination.url.path,
            "name": destination.url.lastPathComponent,
            "size": String(size),
            "sha256": hash,
            "renamed": String(destination.renamed),
            "modified": Self.modifiedString(destination.url),
        ]
    }

    // MARK: - Read / extract

    private func readInline(_ arguments: [String: String]) throws -> [String: String] {
        let url = try resolve(arguments["path"] ?? "")
        let data = try Data(contentsOf: url)
        guard data.count <= Self.inlineReadLimit else {
            throw GuestArtifactError.tooLarge("Inline read is limited to 8 MB; use open_artifact or extract_artifact_text")
        }
        let mime = Self.mimeType(for: url.pathExtension)
        let kind: String
        if mime.hasPrefix("image/") { kind = "image" }
        else if String(data: data, encoding: .utf8) != nil { kind = "text" }
        else { kind = "binary" }
        let filename = "artifact-read-\(UUID().uuidString).bin"
        try mailbox.write(data, named: filename)
        return [
            "data": filename,
            "size": String(data.count),
            "mime": mime,
            "kind": kind,
            "name": url.lastPathComponent,
            "path": url.path,
        ]
    }

    private func extractText(_ arguments: [String: String]) async throws -> [String: String] {
        let url = try resolve(arguments["path"] ?? "")
        let pages = arguments["pages"] ?? ""
        let text = try await GuestTextExtractor.extract(url: url, pages: pages)
        let total = text.count
        let truncated = total > Self.textExtractLimit
        let body = truncated ? String(text.prefix(Self.textExtractLimit)) : text
        let filename = "artifact-text-\(UUID().uuidString).txt"
        try mailbox.write(Data(body.utf8), named: filename)
        return [
            "text": filename,
            "characters": String(total),
            "truncated": String(truncated),
            "name": url.lastPathComponent,
            "path": url.path,
        ]
    }

    private func getChunk(_ arguments: [String: String]) throws -> [String: String] {
        let url = try resolve(arguments["path"] ?? "")
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard size >= 0 else { throw GuestArtifactError.notFound(url.path) }
        let offset = Int(arguments["offset"] ?? "") ?? -1
        let length = min(Int(arguments["length"] ?? "") ?? 512 * 1024, 1024 * 1024)
        guard offset >= 0, offset <= size, length > 0 else {
            throw GuestArtifactError.invalid("Invalid read range")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: min(length, size - offset)) ?? Data()
        let filename = "artifact-chunk-\(UUID().uuidString).bin"
        try mailbox.write(data, named: filename)
        return [
            "data": filename,
            "bytes": String(data.count),
            "offset": String(offset),
            "size": String(size),
            "eof": String(offset + data.count >= size),
        ]
    }

    // MARK: - Open / inspect

    private func open(_ arguments: [String: String]) async throws -> [String: String] {
        let url = try resolve(arguments["path"] ?? "")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GuestArtifactError.notFound(url.path)
        }
        let requested = arguments["app"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let app = try Self.application(named: requested)
        if let app {
            let configuration = NSWorkspace.OpenConfiguration()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: ()) }
                }
            }
        } else {
            guard NSWorkspace.shared.open(url) else {
                throw GuestArtifactError.appFailed("No application opened \(url.lastPathComponent)")
            }
        }

        let deadline = Date().addingTimeInterval(6)
        var appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? requested
        var title = ""
        while Date() < deadline {
            let front = NSWorkspace.shared.frontmostApplication
            appName = front?.localizedName ?? appName
            if let front, let first = Self.windowTitles(pid: front.processIdentifier).first {
                title = first
                if !title.isEmpty { break }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return [
            "app": appName,
            "windowTitle": title,
            "opened": "true",
            "windowFound": String(!title.isEmpty),
            "hint": title.isEmpty ? "The file was opened but no window appeared yet. Take a screenshot to check." : "",
        ]
    }

    private func listWindows() throws -> [String: String] {
        var result: [[String: String]] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            for title in Self.windowTitles(pid: app.processIdentifier) where !title.isEmpty {
                result.append([
                    "app": app.localizedName ?? "",
                    "bundleID": app.bundleIdentifier ?? "",
                    "title": title,
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [])
        return ["windows": String(decoding: data, as: UTF8.self)]
    }

    // MARK: - Paths / listing

    private func list(_ arguments: [String: String]) throws -> [String: String] {
        let root = try root(for: arguments["root"] ?? "artifacts")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let formatter = ISO8601DateFormatter()
        let files: [[String: Any]] = urls.prefix(500).compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return [
                "name": url.lastPathComponent,
                "path": url.path,
                "size": values?.fileSize ?? 0,
                "modified": formatter.string(from: values?.contentModificationDate ?? Date.distantPast),
                "type": Self.mimeType(for: url.pathExtension),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: files, options: [])
        return [
            "files": String(decoding: data, as: UTF8.self),
            "root": root.path,
        ]
    }

    private func root(for value: String) throws -> URL {
        switch value {
        case "artifacts": return artifactsRoot
        case "outputs": return outputsRoot
        default: throw GuestArtifactError.invalid("Unknown artifact root '\(value)'")
        }
    }

    private func resolve(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw GuestArtifactError.invalid("Use an absolute guest path") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        let allowed = [artifactsRoot.standardizedFileURL.path, outputsRoot.standardizedFileURL.path]
        guard allowed.contains(where: { resolved.path == $0 || resolved.path.hasPrefix($0 + "/") }) else {
            throw GuestArtifactError.permissionDenied("Path is outside BUU Artifacts/Outputs")
        }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw GuestArtifactError.permissionDenied("Symlinks are not allowed")
        }
        return resolved
    }

    private func required(_ key: String, _ arguments: [String: String]) throws -> String {
        guard let value = arguments[key], !value.isEmpty else {
            throw GuestArtifactError.invalid("Missing \(key)")
        }
        return value
    }

    private func sanitizedName(_ value: String) throws -> String {
        let base = URL(fileURLWithPath: value).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base != ".", base != ".." else {
            throw GuestArtifactError.invalid("Invalid file name")
        }
        return String(base.prefix(180))
    }

    private struct Uniqueness {
        var url: URL
        var renamed: Bool
    }

    private static func uniqueDestination(for name: String, in root: URL) throws -> Uniqueness {
        let url = URL(fileURLWithPath: name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = name
        var suffix = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            suffix += 1
        }
        return Uniqueness(url: root.appendingPathComponent(candidate), renamed: candidate != name)
    }

    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent(".buu-write-test-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            throw GuestArtifactError.permissionDenied("Cannot write to \(directory.path). Allow Files and Folders access for BUUVirtualMacGuest in System Settings.")
        }
    }

    private static func requireFreeSpace(at root: URL, bytes: Int64) throws {
        guard let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return }
        guard available > bytes + 64 * 1024 * 1024 else {
            throw GuestArtifactError.diskFull("Not enough free space in the virtual Mac: \(bytes) bytes needed, \(available) available")
        }
    }

    private static func modifiedString(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return ISO8601DateFormatter().string(from: date)
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

    private static func application(named name: String) throws -> URL? {
        guard !name.isEmpty else { return nil }
        let allowlist: [String: String] = [
            "Preview": "com.apple.Preview",
            "TextEdit": "com.apple.TextEdit",
            "Safari": "com.apple.Safari",
            "Pages": "com.apple.iWork.Pages",
            "Numbers": "com.apple.iWork.Numbers",
            "Keynote": "com.apple.iWork.Keynote",
            "QuickTime Player": "com.apple.QuickTimePlayerX",
            "Finder": "com.apple.finder",
        ]
        let bundleID: String?
        if let mapped = allowlist[name] {
            bundleID = mapped
        } else if allowlist.values.contains(name) {
            bundleID = name
        } else {
            bundleID = nil
        }
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw GuestArtifactError.appFailed("App '\(name)' is not in the allowlist")
        }
        return url
    }

    private static func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else {
                return nil
            }
            return title as? String
        }
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        case "txt", "md", "csv", "log": return "text/plain"
        case "json": return "application/json"
        case "rtf": return "application/rtf"
        case "doc", "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pages": return "application/vnd.apple.pages"
        default: return "application/octet-stream"
        }
    }
}

private enum GuestTextExtractor {
    static func extract(url: URL, pages: String) async throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else {
                throw GuestArtifactError.permissionDenied("PDFKit could not open \(url.lastPathComponent)")
            }
            let range = pageRange(pages, count: document.pageCount)
            var result = ""
            for index in range {
                if let text = document.page(at: index)?.string, !text.isEmpty {
                    result += text
                    if !result.hasSuffix("\n") { result += "\n" }
                }
            }
            if !result.isEmpty { return result }
            return try await ocr(url: url)
        }
        if ["png", "jpg", "jpeg", "tif", "tiff", "heic", "bmp", "gif"].contains(ext) {
            return try await ocr(url: url)
        }
        if let text = try? String(contentsOf: url, encoding: .utf8), looksTextual(text) {
            return text
        }
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return attributed.string
        }
        return try textutil(url: url)
    }

    private static func pageRange(_ value: String, count: Int) -> Range<Int> {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 1 else { return 0..<count }
        let start = min(count, max(0, max(1, parts[0]) - 1))
        let end = parts.count > 1 ? min(count, max(0, parts[1])) : min(count, start + 1)
        return start..<max(start, end)
    }

    private static func looksTextual(_ text: String) -> Bool {
        let sample = text.prefix(4096)
        let control = sample.unicodeScalars.filter { $0.value < 32 && ![9, 10, 13].contains($0.value) }.count
        return control * 100 <= max(1, sample.unicodeScalars.count)
    }

    private static func textutil(url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw GuestArtifactError.appFailed("No text extractor handled \(url.lastPathComponent)")
        }
        return text
    }

    private static func ocr(url: URL) async throws -> String {
        guard #available(macOS 13.0, *) else {
            throw GuestArtifactError.appFailed("Vision OCR requires macOS 13 or newer")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(url: url)
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// FSEvents watcher writes a tiny dirty marker into the mailbox. The host polls
/// it while a run is active and then pulls new output files in chunks.
private final class GuestOutputWatcher {
    private let path: String
    private let mailbox: Mailbox
    private let queue = DispatchQueue(label: "com.buu.guest.outputs-watcher")
    private var stream: FSEventStreamRef?

    init(path: String, mailbox: Mailbox) {
        self.path = path
        self.mailbox = mailbox
    }

    func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<GuestOutputWatcher>.fromOpaque(info).takeUnretainedValue().markDirty()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            flags
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func markDirty() {
        try? mailbox.write(Data(String(Date().timeIntervalSince1970).utf8), named: "outputs.dirty")
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

private enum GuestArtifactError: LocalizedError {
    case invalid(String)
    case notFound(String)
    case permissionDenied(String)
    case appFailed(String)
    case tooLarge(String)
    case checksum(String)
    case diskFull(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return "invalid: \(message)"
        case .notFound(let path): return "notFound: \(path)"
        case .permissionDenied(let message): return "permissionDenied: \(message)"
        case .appFailed(let message): return "appFailed: \(message)"
        case .tooLarge(let message): return "tooLarge: \(message)"
        case .checksum(let message): return "checksum: \(message)"
        case .diskFull(let message): return "diskFull: \(message)"
        case .unknown(let action): return "unknownAction: \(action)"
        }
    }
}
