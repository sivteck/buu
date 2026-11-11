import AppKit
import Foundation
import Observation
import os
import BUUKit
import VirtualMacKit

// MARK: - Tool catalog

enum VirtualMacToolCatalog {
    static let statusName = "vm_status"
    static let screenshotName = "vm_screenshot"
    static let clickName = "vm_click"
    static let moveName = "vm_move"
    static let dragName = "vm_drag"
    static let scrollName = "vm_scroll"
    static let typeName = "vm_type"
    static let keyName = "vm_key"
    static let listArtifactsName = "list_artifacts"
    static let readArtifactName = "read_artifact"
    static let writeArtifactName = "write_artifact"
    static let openArtifactName = "open_artifact"
    static let revealArtifactName = "reveal_artifact"
    static let extractArtifactTextName = "extract_artifact_text"
    static let frontmostAppName = "guest_frontmost_app"
    static let listWindowsName = "guest_list_windows"

    static let names: Set<String> = [
        statusName, screenshotName, clickName, moveName,
        dragName, scrollName, typeName, keyName,
        listArtifactsName, readArtifactName, writeArtifactName,
        openArtifactName, revealArtifactName, extractArtifactTextName,
        frontmostAppName, listWindowsName,
    ]

    static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: statusName,
            description: "Report whether the virtual Mac is running and whether the guest helper has Screen Recording and Accessibility permissions.",
            parameters: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: screenshotName,
            description: "Capture the virtual Mac's screen. Every x/y used by the other tools is a pixel in this PNG, with a top-left origin.",
            parameters: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: clickName,
            description: "Click in the virtual Mac. clicks: 2 double-clicks, 3 triple-clicks. button: left or right.",
            parameters: objectSchema(
                properties: [
                    "x": integer("Horizontal pixel in the latest screenshot."),
                    "y": integer("Vertical pixel in the latest screenshot."),
                    "button": .object(["type": .string("string"), "enum": .array([.string("left"), .string("right")])]),
                    "clicks": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(3)]),
                ],
                required: ["x", "y"]
            )
        ),
        ToolDefinition(
            name: moveName,
            description: "Move the pointer in the virtual Mac, for example to reveal a hover menu.",
            parameters: objectSchema(properties: ["x": integer("Horizontal pixel."), "y": integer("Vertical pixel.")], required: ["x", "y"])
        ),
        ToolDefinition(
            name: dragName,
            description: "Press the left button at (x,y), drag to (toX,toY), and release inside the virtual Mac.",
            parameters: objectSchema(
                properties: [
                    "x": integer("Start horizontal pixel."),
                    "y": integer("Start vertical pixel."),
                    "toX": integer("End horizontal pixel."),
                    "toY": integer("End vertical pixel."),
                ],
                required: ["x", "y", "toX", "toY"]
            )
        ),
        ToolDefinition(
            name: scrollName,
            description: "Scroll inside the virtual Mac. Negative dy scrolls content down; positive dy scrolls up.",
            parameters: objectSchema(
                properties: [
                    "x": integer("Horizontal pixel."),
                    "y": integer("Vertical pixel."),
                    "dy": integer("Vertical scroll amount, -1000…1000."),
                    "dx": integer("Optional horizontal scroll amount."),
                ],
                required: ["x", "y", "dy"]
            )
        ),
        ToolDefinition(
            name: typeName,
            description: "Type literal text into the focused field in the virtual Mac using real key events, including Spotlight and search fields. Use vm_key for Return, Tab and shortcuts.",
            parameters: objectSchema(properties: ["text": .object(["type": .string("string")])], required: ["text"])
        ),
        ToolDefinition(
            name: keyName,
            description: "Press a key or chord in the virtual Mac: return, tab, escape, cmd+space, cmd+c, cmd+shift+4, …",
            parameters: objectSchema(properties: ["key": .object(["type": .string("string")])], required: ["key"])
        ),
        ToolDefinition(
            name: listArtifactsName,
            description: "List input artifacts in the guest and files produced in BUU Outputs. Returns guest absolute paths, sizes, types, sync state and suggested apps.",
            parameters: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: readArtifactName,
            description: "Read a UTF-8 text or image artifact from the guest copy. Use path from list_artifacts; name is accepted for older prompts. PDFs/Office files should use extract_artifact_text or open_artifact.",
            parameters: objectSchema(
                properties: [
                    "path": .object(["type": .string("string"), "description": .string("Guest absolute path from list_artifacts.")]),
                    "name": .object(["type": .string("string"), "description": .string("File name fallback.")]),
                ],
                required: []
            )
        ),
        ToolDefinition(
            name: openArtifactName,
            description: "Open a guest artifact with its default app or an allowlisted app (Preview, TextEdit, Safari, Pages, Numbers, Keynote, QuickTime Player). Waits briefly for a window.",
            parameters: objectSchema(
                properties: [
                    "path": .object(["type": .string("string"), "description": .string("Guest absolute path under BUU Artifacts/Outputs.")]),
                    "app": .object(["type": .string("string"), "description": .string("Optional allowlisted app name.")]),
                ],
                required: ["path"]
            )
        ),
        ToolDefinition(
            name: revealArtifactName,
            description: "Reveal a guest artifact in a Finder window in the VM.",
            parameters: objectSchema(
                properties: ["path": .object(["type": .string("string"), "description": .string("Guest absolute path.")])],
                required: ["path"]
            )
        ),
        ToolDefinition(
            name: extractArtifactTextName,
            description: "Extract text from a PDF, Office document or image in the guest using PDFKit/textutil/Vision OCR. Optional pages such as 1 or 2-5.",
            parameters: objectSchema(
                properties: [
                    "path": .object(["type": .string("string"), "description": .string("Guest absolute path.")]),
                    "pages": .object(["type": .string("string"), "description": .string("Optional page or range, e.g. 1 or 2-5.")]),
                ],
                required: ["path"]
            )
        ),
        ToolDefinition(
            name: writeArtifactName,
            description: "Write a text or base64 result into the guest's BUU Outputs folder, then sync it to the host task Outputs folder.",
            parameters: objectSchema(
                properties: [
                    "name": .object(["type": .string("string"), "description": .string("File name to create.")]),
                    "content": .object(["type": .string("string"), "description": .string("UTF-8 text content.")]),
                    "base64": .object(["type": .string("string"), "description": .string("Base64 bytes; informational results only.")]),
                ],
                required: ["name"]
            )
        ),
        ToolDefinition(
            name: frontmostAppName,
            description: "Report the frontmost app in the guest without a screenshot.",
            parameters: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: listWindowsName,
            description: "List visible windows in the guest with their app and title.",
            parameters: objectSchema(properties: [:], required: [])
        ),
    ]

    private static func integer(_ description: String) -> JSONValue {
        .object([
            "type": .string("integer"),
            "minimum": .number(0),
            "description": .string(description),
        ])
    }

    private static func objectSchema(
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }
}

// MARK: - Tool execution

struct VirtualMacToolOutcome: Sendable {
    var text: String
    var image: ImagePayload?
    var isError: Bool

    static func success(_ text: String, image: ImagePayload? = nil) -> Self {
        Self(text: text, image: image, isError: false)
    }

    static func failure(_ text: String) -> Self {
        Self(text: text, image: nil, isError: true)
    }
}

@MainActor
struct VirtualMacToolExecutor {
    private static let logger = Logger(subsystem: "com.buu", category: "agent-tools")
    let vm: VirtualMacController
    let artifactDirectory: URL?
    let appState: AppState?
    let taskID: UUID?

    func execute(_ call: ToolCall) async -> VirtualMacToolOutcome {
        let started = Date()
        let outcome = await executeUnlogged(call)
        let duration = Date().timeIntervalSince(started)
        Self.logger.info("tool=\(call.name, privacy: .public) error=\(outcome.isError) ms=\(Int(duration * 1000))")
        return outcome
    }

    private func executeUnlogged(_ call: ToolCall) async -> VirtualMacToolOutcome {
        guard VirtualMacToolCatalog.names.contains(call.name) else {
            return .failure("Unknown virtual Mac tool '\(call.name)'.")
        }

        do {
            switch call.name {
            case VirtualMacToolCatalog.statusName:
                await vm.refreshGuestStatus()
                let guest = vm.guestStatus
                return .success([
                    "vm=\(vm.vmState)",
                    "ready=\(guest?.isReady == true)",
                    "screenRecording=\(guest?.screenRecording == true)",
                    "accessibility=\(guest?.accessibility == true)",
                    "screen=\(guest?.width ?? 0)x\(guest?.height ?? 0)",
                ].joined(separator: "\n"))

            case VirtualMacToolCatalog.screenshotName:
                let data = try await vm.captureScreenshot()
                return .success(
                    "Screenshot captured (\(vm.screenshotSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown")).",
                    image: ImagePayload(mimeType: "image/png", data: data)
                )

            case VirtualMacToolCatalog.clickName:
                let args = try decode(ClickArguments.self, call)
                try await vm.click(x: args.x, y: args.y, button: args.button, clicks: args.clicks ?? 1)
                return .success("Clicked \(args.x),\(args.y).")

            case VirtualMacToolCatalog.moveName:
                let args = try decode(PointArguments.self, call)
                try await vm.move(x: args.x, y: args.y)
                return .success("Moved pointer to \(args.x),\(args.y).")

            case VirtualMacToolCatalog.dragName:
                let args = try decode(DragArguments.self, call)
                try await vm.drag(x: args.x, y: args.y, toX: args.toX, toY: args.toY)
                return .success("Dragged \(args.x),\(args.y) → \(args.toX),\(args.toY).")

            case VirtualMacToolCatalog.scrollName:
                let args = try decode(ScrollArguments.self, call)
                try await vm.scroll(x: args.x, y: args.y, dy: args.dy, dx: args.dx ?? 0)
                return .success("Scrolled \(args.dy) at \(args.x),\(args.y).")

            case VirtualMacToolCatalog.typeName:
                let args = try decode(TypeArguments.self, call)
                try await vm.typeText(args.text)
                return .success("Typed \(args.text.count) character(s).")

            case VirtualMacToolCatalog.keyName:
                let args = try decode(KeyArguments.self, call)
                try await vm.key(args.key)
                return .success("Pressed \(args.key).")

            case VirtualMacToolCatalog.listArtifactsName:
                return listArtifacts()

            case VirtualMacToolCatalog.readArtifactName:
                let args = try decode(ArtifactPathArguments.self, call)
                return try await readArtifact(args)

            case VirtualMacToolCatalog.openArtifactName:
                let args = try decode(OpenArtifactArguments.self, call)
                return try await openArtifact(args)

            case VirtualMacToolCatalog.revealArtifactName:
                let args = try decode(ArtifactPathArguments.self, call)
                let path = try resolveGuestPath(path: args.path, name: args.name)
                try await vm.guestRevealArtifact(path: path)
                return .success("Revealed \(path) in Finder.")

            case VirtualMacToolCatalog.extractArtifactTextName:
                let args = try decode(ExtractArtifactTextArguments.self, call)
                let path = try resolveGuestPath(path: args.path, name: nil)
                let result = try await vm.guestExtractArtifactText(path: path, pages: args.pages)
                let limit = 250_000
                let body = result.text.count > limit
                    ? String(result.text.prefix(limit)) + "\n\n[truncated; total \(result.totalCharacters) characters]"
                    : result.text
                return .success(
                    "Extracted \(result.totalCharacters) characters from \(URL(fileURLWithPath: path).lastPathComponent)\(result.truncated ? " (guest truncated)" : ""):\n\(body)"
                )

            case VirtualMacToolCatalog.writeArtifactName:
                let args = try decode(WriteArtifactArguments.self, call)
                return try await writeArtifact(args)

            case VirtualMacToolCatalog.frontmostAppName:
                let app = try await vm.guestFrontmostApp()
                return .success("Frontmost app: \(app.name) (\(app.bundleID)), pid \(app.pid).")

            case VirtualMacToolCatalog.listWindowsName:
                let windows = try await vm.guestListWindows()
                guard !windows.isEmpty else { return .success("No visible windows were reported.") }
                return .success(windows.prefix(80).map { "\($0.app) — \($0.title)" }.joined(separator: "\n"))

            default:
                return .failure("Unknown virtual Mac tool '\(call.name)'.")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func listArtifacts() -> VirtualMacToolOutcome {
        if let appState, let taskID {
            let artifacts = appState.macArtifacts(for: taskID)
            let outputs = appState.macOutputs(for: taskID)
            let folders = appState.macArtifactFolders
            guard !artifacts.isEmpty || !outputs.isEmpty else {
                let root = folders?.artifactsRoot ?? "~/Desktop/BUU Artifacts"
                return .success("No input artifacts or outputs yet. Inputs appear in \(root).")
            }
            var lines: [String] = []
            if !artifacts.isEmpty {
                lines.append("Inputs:")
                for artifact in artifacts {
                    let app = appState.suggestedApp(for: artifact.name)
                    let path = artifact.guestPath ?? "\(folders?.artifactsRoot ?? "~/Desktop/BUU Artifacts")/\(artifact.guestName ?? artifact.fileName)"
                    lines.append(
                        "- \(artifact.name) | \(artifact.byteCount) bytes | \(appState.mimeType(for: artifact.name)) | "
                        + "state=\(stateLabel(artifact.guestState, error: artifact.lastError)) | guest=\(path)"
                        + (app.isEmpty ? "" : " | suggestedApp=\(app)")
                    )
                }
            }
            if !outputs.isEmpty {
                lines.append("Outputs:")
                for output in outputs {
                    lines.append("- \(output.name) | \(output.byteCount) bytes | guest=\(output.guestPath) | host=Outputs/\(output.hostFileName)")
                }
            }
            if let root = folders?.outputsRoot {
                lines.append("Save results to \(root).")
            }
            return .success(lines.joined(separator: "\n"))
        }

        guard let directory = artifactDirectory else {
            return .failure("No artifact workspace is configured for this task.")
        }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        guard !urls.isEmpty else { return .success("No artifacts are attached to this task.") }
        let lines = urls
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(200)
            .map { url -> String in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return "\(url.lastPathComponent) — \(size) bytes"
            }
        return .success(lines.joined(separator: "\n"))
    }

    private func readArtifact(_ args: ArtifactPathArguments) async throws -> VirtualMacToolOutcome {
        if appState != nil, taskID != nil {
            let path = try resolveGuestPath(path: args.path, name: args.name)
            let result = try await vm.guestReadArtifact(path: path)
            switch result.kind {
            case "image":
                return .success(
                    "Read image artifact \(result.name) from the guest copy (\(result.data.count) bytes).",
                    image: ImagePayload(mimeType: result.mime, data: result.data)
                )
            case "text":
                guard let text = String(data: result.data, encoding: .utf8) else {
                    return .failure("Artifact \(result.name) is not valid UTF-8.")
                }
                let limit = 250_000
                let body = text.count > limit ? String(text.prefix(limit)) + "\n\n[truncated]" : text
                return .success("Artifact \(result.name) (\(result.data.count) bytes):\n\(body)")
            default:
                return .failure("Artifact \(result.name) is binary. Use open_artifact with the suggested app, or extract_artifact_text for documents/PDFs.")
            }
        }

        guard let directory = artifactDirectory, let name = args.name ?? args.path.map({ URL(fileURLWithPath: $0).lastPathComponent }) else {
            return .failure("A guest path or artifact name is required.")
        }
        let url = try artifactURL(named: name, in: directory)
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else {
            return .failure("Artifact \(url.lastPathComponent) is \(data.count) bytes; the inline read limit is 8 MB.")
        }
        if let mime = imageMIMEType(for: url.pathExtension) {
            return .success(
                "Read image artifact \(url.lastPathComponent) (\(data.count) bytes).",
                image: ImagePayload(mimeType: mime, data: data)
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure("Artifact \(url.lastPathComponent) is binary. Only UTF-8 text and images can be read inline.")
        }
        let limit = 250_000
        let body = text.count > limit ? String(text.prefix(limit)) + "\n\n[truncated]" : text
        return .success("Artifact \(url.lastPathComponent) (\(data.count) bytes):\n\(body)")
    }

    private func openArtifact(_ args: OpenArtifactArguments) async throws -> VirtualMacToolOutcome {
        let path = try resolveGuestPath(path: args.path, name: nil)
        let result = try await vm.guestOpenArtifact(path: path, app: args.app)
        appState?.markMacArtifactOpened(path: path)
        var text = "Opened \(URL(fileURLWithPath: path).lastPathComponent) with \(result.app)."
        if !result.windowTitle.isEmpty {
            text += " Window: \(result.windowTitle)."
        }
        if !result.windowFound {
            return .failure("timeout: \(text) \(result.hint.isEmpty ? "Take a screenshot to check." : result.hint)")
        }
        return .success(text)
    }

    private func writeArtifact(_ args: WriteArtifactArguments) async throws -> VirtualMacToolOutcome {
        guard let appState, let taskID else {
            return .failure("The guest artifact service is unavailable.")
        }
        let data: Data
        if let base64 = args.base64, !base64.isEmpty {
            guard let decoded = Data(base64Encoded: base64) else {
                return .failure("The base64 content is invalid.")
            }
            data = decoded
        } else if let content = args.content {
            data = Data(content.utf8)
        } else {
            return .failure("Provide content or base64.")
        }
        guard data.count <= 2_000_000 else {
            return .failure("Artifact content is too large; the inline write limit is 2 MB.")
        }
        let upload = try await appState.writeGuestArtifact(
            name: args.name,
            data: data,
            taskID: taskID
        )
        return .success("Wrote \(upload.name) into the guest at \(upload.path) and synced it to the host Outputs folder.")
    }

    private func resolveGuestPath(path: String?, name: String?) throws -> String {
        guard let appState, let taskID else {
            throw VirtualMacToolError.badArguments("The guest artifact service is unavailable.")
        }
        if let path, !path.isEmpty {
            guard appState.isAllowedGuestArtifactPath(path, taskID: taskID) else {
                throw VirtualMacToolError.badArguments("Path is outside the task's BUU Artifacts/Outputs folders.")
            }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        if let name, let path = appState.guestPathForArtifact(named: name, taskID: taskID) {
            return path
        }
        throw VirtualMacToolError.badArguments("Artifact was not found in the guest yet. Call list_artifacts and check its state.")
    }

    private func stateLabel(_ state: TaskArtifactGuestState?, error: String?) -> String {
        switch state ?? .queued {
        case .inGuest: return "in-guest"
        case .opened: return "opened"
        case .modified: return "modified"
        case .copying: return "copying"
        case .failed: return "failed: \(error ?? "unknown")"
        case .queued: return "queued"
        }
    }

    private func artifactURL(named name: String, in directory: URL) throws -> URL {
        let base = URL(fileURLWithPath: name).lastPathComponent
        guard !base.isEmpty, base != ".", base != ".." else {
            throw VirtualMacToolError.badArguments("A valid artifact file name is required.")
        }
        let url = directory.appendingPathComponent(base, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VirtualMacToolError.badArguments("Artifact '\(base)' was not found. Call list_artifacts to see available files.")
        }
        return url
    }

    private func imageMIMEType(for pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return nil
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ call: ToolCall) throws -> T {
        guard !call.arguments.isEmpty, let data = call.arguments.data(using: .utf8) else {
            throw VirtualMacToolError.badArguments("Missing JSON arguments for \(call.name).")
        }
        return try JSONCoding.decode(type, from: data)
    }

    private struct ClickArguments: Decodable {
        var x: Int
        var y: Int
        var button: String?
        var clicks: Int?
    }
    private struct PointArguments: Decodable { var x: Int; var y: Int }
    private struct DragArguments: Decodable { var x: Int; var y: Int; var toX: Int; var toY: Int }
    private struct ScrollArguments: Decodable { var x: Int; var y: Int; var dy: Int; var dx: Int? }
    private struct TypeArguments: Decodable { var text: String }
    private struct KeyArguments: Decodable { var key: String }
    private struct ArtifactPathArguments: Decodable { var path: String?; var name: String? }
    private struct OpenArtifactArguments: Decodable { var path: String; var app: String? }
    private struct ExtractArtifactTextArguments: Decodable { var path: String; var pages: String? }
    private struct WriteArtifactArguments: Decodable { var name: String; var content: String?; var base64: String? }
}

enum VirtualMacToolError: LocalizedError {
    case badArguments(String)
    var errorDescription: String? {
        switch self { case .badArguments(let message): return message }
    }
}

// MARK: - Agent loop

enum MacLoopPhase: String, Sendable {
    case idle
    case modelThinking
    case toolRunning
    case betweenRounds
    case paused
}

enum MacRunState: String, Sendable {
    case idle
    case running
    case paused
    case finished
    case failed
}

struct MacLoopSnapshot: Equatable, Sendable {
    var round: Int
    var phase: MacLoopPhase
    var nextSafeBoundaryRound: Int?
    var pendingSteerCount: Int
    var interruptRequested: Bool
}

@MainActor
@Observable
final class VirtualMacAgentModel {
    private static let logger = Logger(subsystem: "com.buu", category: "mac-steering")

    var selectedEndpointID: UUID?
    var model = ""
    var instructions = ""
    var availableModels: [RemoteModel] = []
    var isLoadingModels = false
    var modelError: String?
    var isRunning = false
    var hasResumableSession = false
    var errorMessage: String?
    var log: [String] = []
    var steerItems: [SteerItem] = []
    var currentRound = 0
    var phase: MacLoopPhase = .idle
    var nextSafeBoundaryRound: Int?
    var runEndedWithPendingSteers = false
    var pendingSteersAtEnd = 0
    var lastRunStatus: String?
    var runStartedAt: Date?
    /// True when the user cleared the model context during the current run.
    var didClearContextDuringRun = false

    @ObservationIgnored var interruptRequested = false
    @ObservationIgnored var stopAfterCurrentRound = false
    @ObservationIgnored var clearContextAfterRound = false
    @ObservationIgnored private var snapshotContinuation: AsyncStream<MacLoopSnapshot>.Continuation?

    @ObservationIgnored weak var appState: AppState?
    @ObservationIgnored var onRunFinished: (@MainActor (UUID, String) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var logPersistTask: Task<Void, Never>?
    @ObservationIgnored private var activeTaskID: UUID?
    @ObservationIgnored private var sessionMessages: [ChatMessage] = []
    @ObservationIgnored private var liveMessages: [ChatMessage] = []
    @ObservationIgnored private(set) var runToolCalls: [ToolCall] = []

    var currentTaskID: UUID? { activeTaskID }

    var runState: MacRunState {
        if isRunning { return .running }
        if phase == .paused { return .paused }
        switch lastRunStatus {
        case "failed": return .failed
        case "paused": return .paused
        case "completed", "stopped", "cancelled": return .finished
        default: return hasResumableSession ? .finished : .idle
        }
    }

    var hasContext: Bool {
        !liveMessages.isEmpty || !sessionMessages.isEmpty || !log.isEmpty
    }

    /// True when there is a model conversation to clear. The trace and VM state
    /// do not count; clearing an already-empty context must be a no-op.
    var hasModelContext: Bool {
        !liveMessages.isEmpty || !sessionMessages.isEmpty
    }

    /// The current in-memory trace, including a round that is still running.
    var traceMessages: [AgentLoopMessage] {
        let messages = liveMessages.isEmpty ? sessionMessages : liveMessages
        return messages.map(AgentLoopMessage.init)
    }

    func loadModels(endpoint: ProviderEndpoint, apiKey: String?) async {
        guard endpoint.listsModels else {
            availableModels = endpoint.defaultModel.isEmpty ? [] : [RemoteModel(id: endpoint.defaultModel)]
            if model.isEmpty { model = endpoint.defaultModel }
            return
        }
        isLoadingModels = true
        modelError = nil
        defer { isLoadingModels = false }
        do {
            let client = try ProviderClient(endpoint: endpoint, apiKey: apiKey)
            availableModels = try await client.listModels()
            if model.isEmpty {
                model = availableModels.first?.id ?? endpoint.defaultModel
            }
        } catch {
            availableModels = []
            modelError = error.localizedDescription
        }
    }

    func loadSession(for task: AgenticTaskRecord?) {
        guard !isRunning else { return }
        activeTaskID = task?.id
        steerItems = task?.steers ?? []
        runEndedWithPendingSteers = false
        pendingSteersAtEnd = 0
        guard let id = task?.id, let state = appState?.loadMacAgentLoop(taskID: id) else {
            sessionMessages = []
            liveMessages = []
            log = []
            hasResumableSession = false
            errorMessage = nil
            lastRunStatus = task?.lastStatus
            phase = task?.lastStatus == "paused" ? .paused : .idle
            currentRound = 0
            emitSnapshot()
            return
        }
        sessionMessages = state.messages
        liveMessages = state.messages
        log = state.log
        hasResumableSession = true
        errorMessage = nil
        let storedStatus = task?.lastStatus
        if storedStatus == "running" {
            lastRunStatus = "paused"
            phase = .paused
            appState?.updateTaskStatus(taskID: id, status: "paused")
        } else {
            lastRunStatus = storedStatus
            phase = storedStatus == "paused" ? .paused : .idle
        }
        currentRound = Self.lastRound(in: state.log)
        refreshSteers()
        emitSnapshot()
    }

    func resetSession() {
        guard !isRunning, hasModelContext else { return }
        if let id = activeTaskID {
            appState?.autosaveMacTraceForContextClear(taskID: id)
        }
        clearContextState()
    }

    private func clearContextState() {
        if isRunning { didClearContextDuringRun = true }
        sessionMessages = []
        liveMessages = []
        hasResumableSession = false
        errorMessage = nil
        runEndedWithPendingSteers = false
        pendingSteersAtEnd = 0
        append("Context cleared")
        persist([])
        emitSnapshot()
    }

    func requestClearContextAfterRound() {
        clearContextAfterRound = true
        append("System: Clear context requested after the current step.")
        emitSnapshot()
    }

    /// Fresh model context for a queued workspace task. Trace is kept; only the
    /// model conversation is reset.
    func beginFreshRunContext() {
        sessionMessages = []
        liveMessages = []
        hasResumableSession = false
        errorMessage = nil
        runEndedWithPendingSteers = false
        pendingSteersAtEnd = 0
        append("System: Started a fresh model context for the queued task.")
        emitSnapshot()
    }

    var snapshot: MacLoopSnapshot {
        MacLoopSnapshot(
            round: currentRound,
            phase: phase,
            nextSafeBoundaryRound: nextSafeBoundaryRound,
            pendingSteerCount: SteerPlanner.pending(steerItems).count,
            interruptRequested: interruptRequested
        )
    }

    func snapshots() -> AsyncStream<MacLoopSnapshot> {
        AsyncStream { continuation in
            Task { @MainActor in
                self.snapshotContinuation = continuation
                continuation.yield(self.snapshot)
            }
        }
    }

    func noteSystem(_ text: String) {
        append("System: \(text)")
    }

    @discardableResult
    func enqueueSteer(text: String, attachmentIDs: [UUID] = [], interrupt: Bool = false) -> SteerItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let taskID = activeTaskID else { return nil }
        guard isRunning || hasResumableSession else {
            errorMessage = "Steering is available only while a run is active or paused."
            return nil
        }
        guard SteerPlanner.pending(steerItems).count < SteerPlanner.maxPending else {
            errorMessage = "You can queue at most \(SteerPlanner.maxPending) steering messages."
            return nil
        }
        guard let item = appState?.addMacSteer(taskID: taskID, text: trimmed, attachmentIDs: attachmentIDs) else {
            return nil
        }
        refreshSteers()
        append("System: Steer queued (\(item.text)).")
        if interrupt {
            interruptRequested = true
            append("System: Interrupt requested. The current round will stop at the next safe point.")
        }
        Self.logger.info("steer queued id=\(item.id.uuidString, privacy: .public) interrupt=\(interrupt)")
        emitSnapshot()
        return item
    }

    @discardableResult
    func editSteer(id: UUID, text: String) -> Bool {
        guard let taskID = activeTaskID,
              let item = steerItems.first(where: { $0.id == id }),
              item.state == .queued else { return false }
        guard appState?.updateMacSteer(taskID: taskID, id: id, text: text) == true else { return false }
        refreshSteers()
        append("System: Steer edited before applying.")
        emitSnapshot()
        return true
    }

    @discardableResult
    func deleteSteer(id: UUID) -> Bool {
        guard let taskID = activeTaskID,
              let cancelled = appState?.cancelMacSteer(taskID: taskID, id: id) else { return false }
        refreshSteers()
        append("System: Steer cancelled by user (original): \(cancelled.text)")
        emitSnapshot()
        return true
    }

    @discardableResult
    func retrySteer(id: UUID) -> Bool {
        guard let taskID = activeTaskID,
              steerItems.first(where: { $0.id == id })?.state == .failed else { return false }
        appState?.retryMacSteer(taskID: taskID, id: id)
        refreshSteers()
        append("System: Steer retry queued.")
        emitSnapshot()
        return true
    }

    func reorderSteers(ids: [UUID]) {
        guard let taskID = activeTaskID else { return }
        appState?.reorderMacSteers(taskID: taskID, ids: ids)
        refreshSteers()
        emitSnapshot()
    }

    @discardableResult
    func interruptSteer(id: UUID) -> Bool {
        guard steerItems.first(where: { $0.id == id })?.state == .queued else { return false }
        interruptRequested = true
        append("System: “Send now” requested. Interrupting at the next safe point.")
        emitSnapshot()
        return true
    }

    func discardPendingSteers() {
        guard let taskID = activeTaskID else { return }
        let pending = SteerPlanner.pending(steerItems).filter { $0.state == .queued || $0.state == .failed }
        for item in pending {
            _ = appState?.cancelMacSteer(taskID: taskID, id: item.id)
            append("System: Steer cancelled by user (original): \(item.text)")
        }
        refreshSteers()
        runEndedWithPendingSteers = false
        pendingSteersAtEnd = 0
        emitSnapshot()
    }

    func clearSteerEndPrompt() {
        runEndedWithPendingSteers = false
        pendingSteersAtEnd = 0
    }

    func requestStopAfterCurrentRound() {
        stopAfterCurrentRound = true
        append("System: Stop after the current round requested.")
        emitSnapshot()
    }

    func cancel(markPaused: Bool = true) {
        generation &+= 1
        task?.cancel()
        task = nil
        isRunning = false
        runStartedAt = nil
        interruptRequested = false
        stopAfterCurrentRound = false
        clearContextAfterRound = false
        lastRunStatus = nil
        phase = markPaused ? .paused : .idle
        nextSafeBoundaryRound = nil
        refreshSteers()
        if markPaused, let id = activeTaskID {
            recordPendingSteersAtEnd()
            appState?.updateTaskStatus(taskID: id, status: "paused")
            appState?.handleMacRunCancelled(taskID: id)
        }
        persist(sessionMessages)
        emitSnapshot()
    }

    private func refreshSteers() {
        if let id = activeTaskID {
            steerItems = appState?.macSteers(for: id) ?? steerItems
        }
    }

    private func recordPendingSteersAtEnd() {
        let count = SteerPlanner.pending(steerItems).filter { $0.state == .queued }.count
        pendingSteersAtEnd = count
        runEndedWithPendingSteers = count > 0
        if count > 0 {
            append("System: \(count) steer(s) were not applied because the run ended.")
        }
    }

    private func emitSnapshot() {
        snapshotContinuation?.yield(snapshot)
    }

    @discardableResult
    func steer(_ text: String) -> Bool {
        enqueueSteer(text: text) != nil
    }

    func start(
        endpoint: ProviderEndpoint,
        apiKey: String?,
        model: String,
        instructions: String,
        vm: VirtualMacController,
        maxRoundsOverride: Int? = nil
    ) {
        cancel(markPaused: false)
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !model.isEmpty else { return }

        if activeTaskID == nil {
            activeTaskID = appState?.activeAgenticTask?.id
        }
        let maxRounds = maxRoundsOverride ?? activeTaskID.flatMap { appState?.maxAgentRounds(for: $0) }
        var artifactDirectory: URL?
        if let activeTaskID {
            artifactDirectory = appState?.artifactDirectory(for: activeTaskID)
        }

        var messages = sessionMessages
        if messages.isEmpty {
            messages = [ChatMessage(role: .user, text: trimmed)]
        } else if messages.last?.role == .assistant {
            messages.append(ChatMessage(role: .user, text: trimmed))
        }
        sessionMessages = messages
        liveMessages = messages
        errorMessage = nil
        lastRunStatus = nil
        currentRound = 0
        phase = .idle
        nextSafeBoundaryRound = nil
        interruptRequested = false
        stopAfterCurrentRound = false
        clearContextAfterRound = false
        runEndedWithPendingSteers = false
        pendingSteersAtEnd = 0
        didClearContextDuringRun = false
        runToolCalls = []
        runStartedAt = Date()
        refreshSteers()
        isRunning = true
        generation &+= 1
        let generation = self.generation
        persist(messages)
        emitSnapshot()
        task = Task { [weak self] in
            await self?.run(
                endpoint: endpoint,
                apiKey: apiKey,
                model: model,
                vm: vm,
                messages: messages,
                maxRounds: maxRounds,
                artifactDirectory: artifactDirectory,
                generation: generation
            )
        }
    }

    private func run(
        endpoint: ProviderEndpoint,
        apiKey: String?,
        model: String,
        vm: VirtualMacController,
        messages initialMessages: [ChatMessage],
        maxRounds: Int?,
        artifactDirectory: URL?,
        generation: UInt64
    ) async {
        defer {
            if self.generation == generation {
                isRunning = false
                runStartedAt = nil
                recordPendingSteersAtEnd()
                phase = lastRunStatus == "paused" ? .paused : .idle
                nextSafeBoundaryRound = nil
                emitSnapshot()
                if let status = lastRunStatus, let id = activeTaskID {
                    onRunFinished?(id, status)
                }
            }
        }

        let attachedCount: Int
        if let id = activeTaskID, let appState {
            attachedCount = appState.macArtifacts(for: id).count
        } else {
            attachedCount = 0
        }
        let artifactPreparation: MacArtifactRunContext?
        if attachedCount > 0 {
            append("Preparing guest artifacts…")
            artifactPreparation = await appState?.prepareMacArtifactsForRun(taskID: activeTaskID)
        } else {
            append("No input artifacts attached; skipping the artifacts folder.")
            artifactPreparation = nil
        }
        let hasArtifacts = artifactPreparation?.hasArtifacts == true
        let manifest = artifactPreparation?.manifest
            ?? "No input artifacts were attached. Do not search Finder, Recents, or an artifacts folder."
        if let warning = artifactPreparation?.warning { append("Artifacts: \(warning)") }
        let artifactInstructions: String
        if hasArtifacts {
            artifactInstructions = """
            Guest artifact folders are real Finder folders in the logged-in VM, not host paths.
            \(manifest)

            Playbook:
            - Find the exact file with list_artifacts. Do not search Finder Recents or elsewhere.
            - Open files with open_artifact(path, app) (or double-click in Finder/Preview).
            - Take a screenshot after opening to confirm the window and app.
            - For long PDFs or documents, prefer extract_artifact_text(path, pages) before scrolling. \
              Use the GUI only when visual layout or app-specific interaction matters.
            - Save results into the shown BUU Outputs folder. Apps may also save there with Save As.
            - Report each output path when done. If a permission dialog appears, stop and report it.
            """
        } else {
            artifactInstructions = """
            No input artifacts were attached to this task. Do not search Finder, Recents, or an artifacts folder.
            If the task needs to produce files, save them under ~/Desktop/BUU Outputs/ and report their paths.
            """
        }

        let system = """
        You control a separate macOS virtual machine through tools. Never use or claim access to the \
        user's host Mac: every virtual-Mac action must be one of the provided vm_* tools. Call vm_screenshot first, \
        and use pixel coordinates from that image (top-left origin). Take another screenshot after \
        meaningful actions to verify the result. If the guest is at its login screen, at a macOS \
        permission prompt, or reports missing permissions, stop and ask the user to handle it inside \
        the guest window. When the requested task is complete, stop calling tools and reply with a \
        short final answer. Do not keep taking screenshots after the goal has been verified.

        \(artifactInstructions)
        """

        var messages = initialMessages
        let tools = VirtualMacToolCatalog.definitions
        let executor = VirtualMacToolExecutor(
            vm: vm,
            artifactDirectory: artifactDirectory,
            appState: appState,
            taskID: activeTaskID
        )

        do {
            let client = try ProviderClient(endpoint: endpoint, apiKey: apiKey)
            var round = 0
            while !Task.isCancelled, self.generation == generation {
                phase = .betweenRounds
                nextSafeBoundaryRound = max(1, round)
                emitSnapshot()
                refreshSteers()
                if interruptRequested {
                    interruptRequested = false
                    append("System: Interrupt applied at the next safe boundary.")
                }
                if clearContextAfterRound {
                    clearContextAfterRound = false
                    clearContextState()
                    phase = .paused
                    lastRunStatus = "paused"
                    if let id = activeTaskID {
                        appState?.updateTaskStatus(taskID: id, status: "paused")
                    }
                    persist(sessionMessages)
                    emitSnapshot()
                    return
                }
                let beforeApply = messages.count
                messages = await applyReadySteers(to: messages, round: round + 1)
                if pendingQueuedSteerCount() > 0, messages.count == beforeApply {
                    append("System: Waiting for steer attachment copies before continuing.")
                    persist(messages)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                if stopAfterCurrentRound {
                    stopAfterCurrentRound = false
                    append("System: Stopping after the current round for the next queued task.")
                    persist(messages)
                    if let id = activeTaskID {
                        await appState?.refreshMacOutputs(taskID: id)
                        appState?.updateTaskStatus(taskID: id, status: "completed")
                    }
                    lastRunStatus = "completed"
                    return
                }

                if let maxRounds, maxRounds > 0, round >= maxRounds {
                    let message = "Paused after \(maxRounds) rounds. Press Resume to continue."
                    errorMessage = message
                    append(message)
                    persist(messages)
                    if let id = activeTaskID {
                        await appState?.refreshMacOutputs(taskID: id)
                        appState?.updateTaskStatus(taskID: id, status: "paused")
                    }
                    lastRunStatus = "paused"
                    return
                }

                round += 1
                currentRound = round
                phase = .modelThinking
                nextSafeBoundaryRound = round
                emitSnapshot()
                append("Round \(round)")
                let reasoningMessages = messages.filter {
                    $0.role == .assistant && !($0.reasoning ?? "").isEmpty
                }.count
                append("Context: \(messages.count) messages, \(reasoningMessages) assistant reasoning payload(s)")

                let request = ChatRequest(
                    model: model,
                    messages: messages,
                    system: system,
                    tools: tools
                )

                var roundText = ""
                var roundReasoning = ""
                var toolCalls: [ToolCall] = []
                for try await event in client.stream(request: request) {
                    if Task.isCancelled || self.generation != generation {
                        lastRunStatus = "cancelled"
                        return
                    }
                    if interruptRequested { break }
                    switch event {
                    case .text(let chunk):
                        roundText += chunk
                    case .reasoning(let chunk):
                        roundReasoning += chunk
                    case .toolCall(let id, let name, let arguments):
                        toolCalls.append(ToolCall(
                            id: id ?? "call_\(UUID().uuidString)",
                            name: name,
                            arguments: arguments
                        ))
                    case .failed(let message):
                        throw VirtualMacToolError.badArguments(message)
                    default:
                        break
                    }
                }

                if interruptRequested {
                    interruptRequested = false
                    append("System: Interrupt — current model round cancelled; applying steering now.")
                    phase = .betweenRounds
                    emitSnapshot()
                    persist(messages)
                    continue
                }

                if !roundText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    append("Assistant: \(roundText)")
                }

                runToolCalls.append(contentsOf: toolCalls)
                let assistantMessage = ChatMessage(
                    role: .assistant,
                    text: roundText,
                    toolCalls: toolCalls,
                    reasoning: roundReasoning
                )
                messages.append(assistantMessage)
                liveMessages = messages

                if toolCalls.isEmpty {
                    let pending = pendingQueuedSteerCount()
                    if pending > 0 {
                        append("System: Agent was about to finish. Continuing with your steer.")
                        let before = messages.count
                        messages = await applyReadySteers(to: messages, round: max(1, round))
                        if messages.count == before {
                            append("System: Waiting for steer attachment copies before continuing.")
                            persist(messages)
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        } else {
                            persist(messages)
                        }
                        continue
                    }
                    persist(messages)
                    if let id = activeTaskID {
                        await appState?.refreshMacOutputs(taskID: id)
                        appState?.updateTaskStatus(taskID: id, status: "completed")
                    }
                    lastRunStatus = "completed"
                    return
                }

                phase = .toolRunning
                emitSnapshot()
                for call in toolCalls {
                    if Task.isCancelled || self.generation != generation {
                        lastRunStatus = "cancelled"
                        return
                    }
                    append("→ \(call.name)")
                    let toolStarted = Date()
                    let outcome = await executor.execute(call)
                    let toolMilliseconds = Int(Date().timeIntervalSince(toolStarted) * 1000)
                    append(outcome.isError
                        ? "  error: \(outcome.text) [\(toolMilliseconds) ms]"
                        : "  \(outcome.text) [\(toolMilliseconds) ms]")
                    if call.name == VirtualMacToolCatalog.screenshotName, let id = activeTaskID {
                        let thumbnail = outcome.image.flatMap { Self.traceThumbnail(from: $0.data) } ?? Data()
                        appState?.appendMacTraceScreenshot(taskID: id, round: currentRound, png: thumbnail)
                    }
                    messages.append(.toolResult(
                        callID: call.id,
                        name: call.name,
                        text: outcome.text,
                        isError: outcome.isError
                    ))
                    if let image = outcome.image {
                        messages.append(ChatMessage(role: .user, blocks: [
                            .text("Screenshot returned by \(call.name)."),
                            .image(image),
                        ]))
                    }
                    liveMessages = messages
                }

                persist(messages)
                phase = .betweenRounds
                emitSnapshot()
            }
            if Task.isCancelled || self.generation != generation {
                append("Cancelled.")
                persist(messages)
                lastRunStatus = "cancelled"
            }
        } catch is CancellationError {
            append("Cancelled.")
            persist(messages)
            lastRunStatus = "cancelled"
        } catch {
            errorMessage = error.localizedDescription
            append("Error: \(error.localizedDescription)")
            persist(messages)
            if let id = activeTaskID {
                await appState?.refreshMacOutputs(taskID: id)
                appState?.updateTaskStatus(taskID: id, status: "failed")
            }
            lastRunStatus = "failed"
        }
    }

    private static func traceThumbnail(from data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let maxSize = NSSize(width: 160, height: 100)
        let scale = min(maxSize.width / image.size.width, maxSize.height / image.size.height)
        let target = NSSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func pendingQueuedSteerCount() -> Int {
        SteerPlanner.pending(steerItems).filter { $0.state == .queued }.count
    }

    private func applyReadySteers(to messages: [ChatMessage], round: Int) async -> [ChatMessage] {
        guard let taskID = activeTaskID else { return messages }
        refreshSteers()
        let pending = SteerPlanner.pending(steerItems).filter { $0.state == .queued }
        guard !pending.isEmpty else { return messages }

        var ready: [SteerItem] = []
        for item in pending {
            if let failure = appState?.steerAttachmentFailure(item, taskID: taskID) {
                if failure.localizedCaseInsensitiveContains("still copying") {
                    continue
                }
                appState?.failMacSteer(taskID: taskID, id: item.id, error: failure)
                append("System: Steer failed before applying: \(failure)")
                continue
            }
            ready.append(item)
        }
        guard !ready.isEmpty else {
            refreshSteers()
            emitSnapshot()
            return messages
        }

        for item in ready {
            appState?.setMacSteerState(taskID: taskID, id: item.id, state: .applying)
        }
        refreshSteers()
        emitSnapshot()
        await Task.yield()

        var result = messages
        let artifacts = appState?.macArtifacts(for: taskID) ?? []
        for item in ready {
            var text = "Steering instruction: \(item.text)"
            if !item.attachmentIDs.isEmpty {
                let files = artifacts.filter { item.attachmentIDs.contains($0.id) }
                if !files.isEmpty {
                    text += "\nAttached files for this steer:"
                    for file in files {
                        text += "\n- \(file.name) at \(file.guestPath ?? file.fileName)"
                    }
                }
            }
            result.append(ChatMessage(role: .user, text: text))
            let stamp = Date().formatted(date: .omitted, time: .standard)
            append("You steered (round \(round), \(stamp)): \(item.text)")
            appState?.applyMacSteer(taskID: taskID, id: item.id, round: round)
            Self.logger.info("steer applied id=\(item.id.uuidString, privacy: .public) round=\(round)")
        }
        refreshSteers()
        liveMessages = result
        emitSnapshot()
        return result
    }

    private static func lastRound(in log: [String]) -> Int {
        log.compactMap { line -> Int? in
            guard line.hasPrefix("Round ") else { return nil }
            return Int(line.dropFirst(6))
        }.last ?? 0
    }

    private func persist(_ messages: [ChatMessage]) {
        logPersistTask?.cancel()
        sessionMessages = messages
        liveMessages = messages
        guard let id = activeTaskID, let appState else { return }
        appState.saveMacAgentLoop(taskID: id, messages: messages, log: log)
    }

    private func schedulePersist() {
        logPersistTask?.cancel()
        logPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persist(self.sessionMessages)
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 400 {
            log.removeFirst(log.count - 400)
        }
        schedulePersist()
    }
}
