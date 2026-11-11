import Foundation
import BUUKit
import VirtualMacKit
import VirtualMacCore

struct MacArtifactRunContext: Sendable {
    var manifest: String
    var artifactsRoot: String?
    var outputsRoot: String?
    var warning: String?
    var hasArtifacts: Bool = false
}

extension AppState {

    // MARK: - Limits / lookup

    func macArtifactTransferLimit(for taskID: UUID) -> Int64 {
        let gib = agenticTasks.first(where: { $0.id == taskID })
            .flatMap { macConfiguration(id: $0.configurationID)?.artifactTransferLimitGiB }
            ?? 2
        return Int64(max(1, gib)) * 1_073_741_824
    }

    func macArtifacts(for taskID: UUID) -> [TaskArtifact] {
        agenticTasks.first(where: { $0.id == taskID })?.artifacts ?? []
    }

    func macOutputs(for taskID: UUID) -> [TaskOutput] {
        agenticTasks.first(where: { $0.id == taskID })?.outputs ?? []
    }

    func updateMacArtifact(taskID: UUID, artifactID: UUID, _ mutate: (inout TaskArtifact) -> Void) {
        var tasks = agenticTasks
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let artifactIndex = tasks[taskIndex].artifacts?.firstIndex(where: { $0.id == artifactID }) else {
            return
        }
        mutate(&tasks[taskIndex].artifacts![artifactIndex])
        settings.agenticTasks = tasks
        saveSettings()
    }

    func markMacArtifactOpened(path: String) {
        guard let taskID = activeAgenticTask?.id else { return }
        var tasks = agenticTasks
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var changed = false
        if let index = tasks[taskIndex].artifacts?.firstIndex(where: { $0.guestPath == path }) {
            tasks[taskIndex].artifacts?[index].guestState = .opened
            changed = true
        }
        guard changed else { return }
        settings.agenticTasks = tasks
        saveSettings()
    }

    func recordMacArtifactRename(taskID: UUID, artifactID: UUID, guestName: String, guestPath: String) {
        updateMacArtifact(taskID: taskID, artifactID: artifactID) {
            $0.guestName = guestName
            $0.guestPath = guestPath
        }
    }

    // MARK: - Run preparation

    func prepareMacArtifactsForRun(taskID: UUID?) async -> MacArtifactRunContext {
        guard let taskID, agenticTasks.contains(where: { $0.id == taskID }) else {
            return MacArtifactRunContext(manifest: "No artifacts are attached.", artifactsRoot: nil, outputsRoot: nil, warning: nil)
        }
        let attached = macArtifacts(for: taskID)
        if attached.isEmpty {
            return MacArtifactRunContext(
                manifest: "No input artifacts were attached. Do not search Finder, Recents, or an artifacts folder. Save results to ~/Desktop/BUU Outputs/ only if the task produces files.",
                artifactsRoot: nil,
                outputsRoot: "~/Desktop/BUU Outputs",
                warning: nil,
                hasArtifacts: false
            )
        }
        let limit = macArtifactTransferLimit(for: taskID)
        guard virtualMac.vmState == "running" else {
            markMacArtifactsQueued(taskID: taskID)
            let warning = "The virtual Mac is not ready. Attached files are queued and will be copied when the guest is running."
            macArtifactMessage = warning
            return MacArtifactRunContext(manifest: warning, artifactsRoot: nil, outputsRoot: nil, warning: warning, hasArtifacts: true)
        }
        await virtualMac.refreshGuestStatus()
        if virtualMac.guestStatus?.artifactSupport != true {
            let warning = virtualMac.guestStatus == nil
                ? "The guest helper is not running. Open BUUVirtualMacGuest from /Volumes/My Shared Files/tools inside the VM, then run the task again."
                : "The guest helper is out of date. Quit BUUVirtualMacGuest inside the VM, then reopen it from /Volumes/My Shared Files/tools/BUUVirtualMacGuest.app to install helper build 4."
            markMacArtifactsQueued(taskID: taskID, error: warning)
            macArtifactMessage = warning
            return MacArtifactRunContext(manifest: warning, artifactsRoot: nil, outputsRoot: nil, warning: warning, hasArtifacts: true)
        }

        do {
            let folders = try await virtualMac.guestArtifactFolders()
            macArtifactFolders = folders
            macArtifactMessage = folders.usedFallback
                ? "Desktop access was unavailable; using \(folders.artifactsRoot)."
                : nil
            let guestFiles = try await virtualMac.guestListArtifacts(root: "artifacts")
            var byName = Dictionary(uniqueKeysWithValues: guestFiles.map { ($0.name, $0) })

            for artifact in macArtifacts(for: taskID) {
                if Task.isCancelled { break }
                let guestName = artifact.guestName ?? artifact.fileName
                if let info = byName[guestName],
                   ArtifactReconciliation.needsUpload(artifact, guestSize: info.size, guestModified: info.modified) {
                    await syncMacArtifact(taskID: taskID, artifactID: artifact.id, limit: limit, announce: false)
                    byName[guestName] = nil
                } else if let info = byName[guestName] {
                    if artifact.guestPath != info.path || artifact.guestState != .inGuest {
                        updateMacArtifact(taskID: taskID, artifactID: artifact.id) {
                            $0.guestName = info.name
                            $0.guestPath = info.path
                            $0.guestByteCount = Int(info.size)
                            $0.guestModifiedAt = info.modified
                            $0.guestState = .inGuest
                            $0.guestProgress = 1
                            $0.lastError = nil
                        }
                    }
                    byName[guestName] = nil
                } else {
                    await syncMacArtifact(taskID: taskID, artifactID: artifact.id, limit: limit, announce: false)
                }
            }

            // The first screenshot should show the files in Finder.
            try? await virtualMac.guestOpenArtifactsFolder(root: "artifacts")
            startMacOutputPolling(taskID: taskID)
            await refreshMacOutputs(taskID: taskID)

            let fresh = macArtifacts(for: taskID)
            return MacArtifactRunContext(
                manifest: artifactManifest(taskID: taskID, artifacts: fresh, folders: folders),
                artifactsRoot: folders.artifactsRoot,
                outputsRoot: folders.outputsRoot,
                warning: folders.usedFallback ? "Desktop access was unavailable; using \(folders.artifactsRoot)." : nil,
                hasArtifacts: !fresh.isEmpty
            )
        } catch {
            let detail = error.localizedDescription
            let warning: String
            if detail.localizedCaseInsensitiveContains("unknown guest action")
                || detail.localizedCaseInsensitiveContains("unknownAction") {
                warning = "The guest helper is out of date. Quit BUUVirtualMacGuest inside the VM, then reopen it from /Volumes/My Shared Files/tools/BUUVirtualMacGuest.app to install the new artifact-capable helper."
            } else {
                warning = "Could not copy artifacts into the guest: \(detail)"
            }
            markMacArtifactsQueued(taskID: taskID, error: warning)
            macArtifactMessage = warning
            return MacArtifactRunContext(manifest: warning, artifactsRoot: nil, outputsRoot: nil, warning: warning, hasArtifacts: true)
        }
    }

    func artifactManifest(taskID: UUID, artifacts: [TaskArtifact], folders: GuestArtifactFolders) -> String {
        guard !artifacts.isEmpty else {
            return "No input files are attached. Save results to \(folders.outputsRoot)/."
        }
        let lines = artifacts.map { artifact -> String in
            let path = artifact.guestPath ?? "\(folders.artifactsRoot)/\(artifact.guestName ?? artifact.fileName)"
            let state = artifactStateLabel(artifact)
            let app = suggestedApp(for: artifact.name)
            return "- \(artifact.name) (\(ByteCountFormatter.string(fromByteCount: Int64(artifact.byteCount), countStyle: .file)), \(mimeType(for: artifact.name))\(app.isEmpty ? "" : ", open with \(app)")) at \(path) [\(state)]"
        }
        return """
        Attached files are in the VM at \(folders.artifactsRoot)/:
        \(lines.joined(separator: "\n"))
        Save results to \(folders.outputsRoot)/.
        """
    }

    private func artifactStateLabel(_ artifact: TaskArtifact) -> String {
        switch artifact.guestState ?? .queued {
        case .inGuest: return "in guest"
        case .opened: return "opened by agent"
        case .modified: return "modified"
        case .copying: return "copying"
        case .failed: return "failed: \(artifact.lastError ?? "unknown error")"
        case .queued: return "queued"
        }
    }

    // MARK: - Single-file sync

    @discardableResult
    func syncMacArtifact(taskID: UUID, artifactID: UUID, limit: Int64? = nil, announce: Bool) async -> TaskArtifact? {
        guard let artifact = macArtifacts(for: taskID).first(where: { $0.id == artifactID }) else { return nil }
        let limit = limit ?? macArtifactTransferLimit(for: taskID)
        guard virtualMac.vmState == "running" else {
            updateMacArtifact(taskID: taskID, artifactID: artifactID) {
                $0.guestState = .queued
                $0.lastError = nil
            }
            return nil
        }
        let hostURL = artifactStore.url(for: artifact, taskID: taskID)
        guard FileManager.default.fileExists(atPath: hostURL.path) else {
            updateMacArtifact(taskID: taskID, artifactID: artifactID) {
                $0.guestState = .failed
                $0.lastError = "Host copy is missing"
            }
            return nil
        }

        let hash = (try? artifact.sha256 ?? artifactStore.sha256(for: artifact, taskID: taskID)) ?? nil
        updateMacArtifact(taskID: taskID, artifactID: artifactID) {
            $0.guestState = .copying
            $0.guestProgress = 0
            $0.lastError = nil
            if let hash { $0.sha256 = hash }
        }
        macArtifactProgress[artifact.id] = 0
        do {
            let upload = try await virtualMac.guestPutArtifact(
                hostURL: hostURL,
                name: artifact.fileName,
                root: "artifacts",
                transferID: artifact.id.uuidString,
                limit: limit,
                sha256: artifact.sha256 ?? hash,
                progress: { [weak self] value in
                    Task { @MainActor in
                        guard let self else { return }
                        if value >= (self.macArtifactProgress[artifact.id] ?? 0) {
                            self.macArtifactProgress[artifact.id] = value
                        }
                    }
                }
            )
            updateMacArtifact(taskID: taskID, artifactID: artifactID) {
                $0.guestState = .inGuest
                $0.guestProgress = 1
                $0.guestName = upload.name
                $0.guestPath = upload.path
                $0.guestByteCount = Int(upload.size)
                $0.sha256 = upload.sha256
                $0.guestModifiedAt = upload.modified
                $0.lastError = nil
            }
            macArtifactProgress[artifact.id] = 1
            if announce, virtualMacAgent.isRunning, virtualMacAgent.currentTaskID == taskID {
                let app = suggestedApp(for: artifact.name)
                virtualMacAgent.noteSystem(
                    "Artifact copied into the VM: \(artifact.name) → \(upload.path)\(app.isEmpty ? "" : " (suggested app: \(app))")."
                )
                try? await virtualMac.guestRevealArtifact(path: upload.path)
            }
            return macArtifacts(for: taskID).first(where: { $0.id == artifactID })
        } catch {
            let detail = error.localizedDescription
            let message = (detail.localizedCaseInsensitiveContains("unknown guest action")
                || detail.localizedCaseInsensitiveContains("unknownAction"))
                ? "The guest helper is out of date. Quit BUUVirtualMacGuest inside the VM and reopen it from /Volumes/My Shared Files/tools/BUUVirtualMacGuest.app."
                : detail
            updateMacArtifact(taskID: taskID, artifactID: artifactID) {
                $0.guestState = .failed
                $0.guestProgress = nil
                $0.lastError = message
            }
            macArtifactProgress[artifact.id] = nil
            macArtifactMessage = "Could not copy \(artifact.name) into the guest: \(message)"
            if announce, virtualMacAgent.isRunning, virtualMacAgent.currentTaskID == taskID {
                virtualMacAgent.noteSystem("Artifact copy failed for \(artifact.name): \(error.localizedDescription).")
            }
            return nil
        }
    }

    func markMacArtifactsQueued(taskID: UUID, error: String? = nil) {
        for artifact in macArtifacts(for: taskID) where artifact.guestState != .inGuest {
            updateMacArtifact(taskID: taskID, artifactID: artifact.id) {
                $0.guestState = .queued
                if let error { $0.lastError = error }
            }
        }
    }

    // MARK: - Add / remove from UI

    @discardableResult
    func addMacArtifactsAndSync(_ urls: [URL], for taskID: UUID) async throws -> [TaskArtifact] {
        let added = try addMacArtifacts(urls, for: taskID)
        guard !added.isEmpty else { return [] }
        guard virtualMac.vmState == "running" else {
            markMacArtifactsQueued(taskID: taskID)
            macArtifactMessage = "Files added. They will be copied when the virtual Mac is ready."
            return added
        }
        if macArtifactFolders == nil {
            macArtifactFolders = try? await virtualMac.guestArtifactFolders()
        }
        for artifact in added {
            await syncMacArtifact(taskID: taskID, artifactID: artifact.id, announce: true)
        }
        return added
    }

    func removeMacArtifactEverywhere(_ artifactID: UUID, for taskID: UUID) async {
        guard let artifact = macArtifacts(for: taskID).first(where: { $0.id == artifactID }) else { return }
        let guestPath = artifact.guestPath
        removeMacArtifact(artifactID, for: taskID)
        if let guestPath, virtualMac.vmState == "running" {
            try? await virtualMac.guestDeleteArtifact(path: guestPath)
        }
        if virtualMacAgent.isRunning, virtualMacAgent.currentTaskID == taskID {
            virtualMacAgent.noteSystem("Artifact removed from the VM and host: \(artifact.name).")
        }
    }

    func cleanupMacGuestArtifacts(task: AgenticTaskRecord) async {
        guard virtualMac.vmState == "running" else { return }
        for artifact in task.artifacts ?? [] {
            if let path = artifact.guestPath { try? await virtualMac.guestDeleteArtifact(path: path) }
        }
        for output in task.outputs ?? [] {
            try? await virtualMac.guestDeleteArtifact(path: output.guestPath)
        }
    }

    // MARK: - Outputs

    func refreshMacOutputs(taskID: UUID) async {
        guard virtualMac.vmState == "running" else { return }
        do {
            let files = try await virtualMac.guestListArtifacts(root: "outputs")
            guard !files.isEmpty else { return }
            let destination = artifactStore.outputsDirectory(for: taskID)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var tasks = agenticTasks
            guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            var outputs = tasks[taskIndex].outputs ?? []
            var changed = false
            let limit = macArtifactTransferLimit(for: taskID)
            for file in files {
                let claimedByOtherTask = agenticTasks.contains { task in
                    task.id != taskID && (task.outputs ?? []).contains { $0.guestPath == file.path }
                }
                if claimedByOtherTask { continue }
                if let existing = outputs.first(where: { $0.guestPath == file.path }),
                   existing.byteCount == Int(file.size),
                   existing.guestModifiedAt == file.modified {
                    continue
                }
                let safeName = URL(fileURLWithPath: file.name).lastPathComponent
                let hostURL = destination.appendingPathComponent(safeName)
                do {
                    let fetched = try await virtualMac.guestFetchOutput(path: file.path, to: hostURL, limit: limit)
                    if let index = outputs.firstIndex(where: { $0.guestPath == file.path }) {
                        outputs[index].byteCount = Int(fetched.size)
                        outputs[index].sha256 = fetched.sha256
                        outputs[index].guestModifiedAt = file.modified
                        outputs[index].producedAt = Date()
                    } else {
                        outputs.append(TaskOutput(
                            name: file.name,
                            guestPath: file.path,
                            hostFileName: file.name,
                            byteCount: Int(fetched.size),
                            sha256: fetched.sha256,
                            producedAt: Date(),
                            guestModifiedAt: file.modified
                        ))
                    }
                    changed = true
                    macArtifactMessage = "Synced output \(file.name) from the guest."
                } catch {
                    macArtifactMessage = "Could not sync output \(file.name): \(error.localizedDescription)"
                }
            }
            if changed {
                tasks[taskIndex].outputs = outputs
                settings.agenticTasks = tasks
                saveSettings()
            }
        } catch {
            macArtifactMessage = "Could not list guest outputs: \(error.localizedDescription)"
        }
    }

    func startMacOutputPolling(taskID: UUID) {
        macOutputPollTask?.cancel()
        macOutputPollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.virtualMac.vmState == "running" else { continue }
                let dirty = (try? self.virtualMac.consumeGuestOutputsDirty()) ?? false
                if dirty || tick % 5 == 0 {
                    await self.refreshMacOutputs(taskID: taskID)
                }
                tick += 1
            }
        }
    }

    func stopMacOutputPolling() {
        macOutputPollTask?.cancel()
        macOutputPollTask = nil
    }

    // MARK: - Tool support

    func guestPathForArtifact(named name: String, taskID: UUID) -> String? {
        if let path = macArtifacts(for: taskID)
            .first(where: { $0.name == name || $0.fileName == name || $0.guestName == name })?.guestPath {
            return path
        }
        return macOutputs(for: taskID)
            .first(where: { $0.name == name || $0.hostFileName == name })?.guestPath
    }

    func syncQueuedMacArtifacts(taskID: UUID, announce: Bool = true) async {
        guard virtualMac.vmState == "running" else { return }
        if macArtifactFolders == nil {
            macArtifactFolders = try? await virtualMac.guestArtifactFolders()
        }
        let limit = macArtifactTransferLimit(for: taskID)
        for artifact in macArtifacts(for: taskID) where artifact.guestState == .queued {
            await syncMacArtifact(taskID: taskID, artifactID: artifact.id, limit: limit, announce: announce)
        }
        if virtualMacAgent.isRunning, virtualMacAgent.currentTaskID == taskID {
            startMacOutputPolling(taskID: taskID)
            await refreshMacOutputs(taskID: taskID)
        }
    }

    func isAllowedGuestArtifactPath(_ path: String, taskID: UUID) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let folders = macArtifactFolders {
            return [folders.artifactsRoot, folders.outputsRoot].contains {
                normalized == $0 || normalized.hasPrefix($0 + "/")
            }
        }
        return macArtifacts(for: taskID).contains { $0.guestPath == normalized }
    }

    func writeGuestArtifact(name: String, content: String, taskID: UUID) async throws -> GuestUploadResult {
        try await writeGuestArtifact(name: name, data: Data(content.utf8), taskID: taskID)
    }

    func writeGuestArtifact(name: String, data: Data, taskID: UUID) async throws -> GuestUploadResult {
        let base = URL(fileURLWithPath: name).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base != ".", base != ".." else {
            throw Failure("A valid artifact file name is required.")
        }
        guard data.count <= 2_000_000 else {
            throw Failure("Artifact content is too large; the inline write limit is 2 MB.")
        }
        let limit = macArtifactTransferLimit(for: taskID)
        let upload = try await virtualMac.guestPutData(
            data,
            name: base,
            root: "outputs",
            transferID: "write-\(UUID().uuidString)",
            limit: limit
        )
        await refreshMacOutputs(taskID: taskID)
        return upload
    }

    func suggestedApp(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "pdf": return "Preview"
        case "txt", "md", "rtf", "doc", "docx", "pages": return "TextEdit"
        case "csv", "xls", "xlsx", "numbers": return "Numbers"
        case "png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "bmp": return "Preview"
        case "html", "htm", "webarchive": return "Safari"
        case "mp4", "mov", "m4v": return "QuickTime Player"
        default: return ""
        }
    }

    func mimeType(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "txt", "md", "csv", "log": return "text/plain"
        case "json": return "application/json"
        case "doc", "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        default: return "application/octet-stream"
        }
    }
}
