import AppKit
import Foundation
import Observation
import SwiftUI
import BUUKit

/// An image the user attached to the message they are about to send.
struct PendingImage: Identifiable {
    var id = UUID()
    var payload: ImagePayload
    var thumbnail: NSImage
}

/// Central state of the application.
@MainActor
@Observable
final class AppState {

    // MARK: - Persisted state

    var settings: AppSettings = AppSettings()
    var conversations: [Conversation] = []

    // MARK: - Transient state

    var activeConversationID: UUID?
    var availableModels: [RemoteModel] = []
    var isRefreshingModels = false
    var isSending = false
    var composerText = ""
    var pendingImages: [PendingImage] = []
    var showSettings = false
    var endpointStatus: [UUID: String] = [:]
    /// Incremented for every streamed delta. Cheap signal for the transcript's
    /// follow-the-stream logic, instead of a string that changes per token.
    var streamTick = 0
    var errorMessage: String?
    /// The attachment currently shown in the full size image preview.
    var previewedImage: ImageAttachment?
    /// Incremented to ask the composer to take focus (⌘K).
    var focusComposerToken = 0

    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let conversationStore = ConversationStore()
    @ObservationIgnored private var apiKeys: [UUID: String] = [:]
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    // MARK: - Derived state

    var activeEndpoint: ProviderEndpoint? { settings.activeEndpoint }

    var currentModel: String {
        if !settings.selectedModel.isEmpty { return settings.selectedModel }
        if let endpoint = activeEndpoint, !endpoint.defaultModel.isEmpty { return endpoint.defaultModel }
        return availableModels.first?.id ?? ""
    }

    var currentConversation: Conversation? {
        guard let activeConversationID else { return nil }
        return conversations.first { $0.id == activeConversationID }
    }

    var canSend: Bool {
        !isSending && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty)
    }

    /// Tokens currently in the model's context, taken from the most recent
    /// answer's usage (prompt + completion).
    var contextTokenCount: Int? {
        guard let turns = currentConversation?.turns else { return nil }
        for turn in turns.reversed() where turn.role == .assistant {
            guard let usage = turn.usage,
                  let prompt = usage.inputTokens,
                  let completion = usage.outputTokens else { continue }
            return prompt + completion
        }
        return nil
    }

    var canRegenerate: Bool {
        guard !isSending, let conversation = currentConversation else { return false }
        return conversation.turns.contains { $0.role == .user }
    }

    func focusComposer() {
        focusComposerToken += 1
    }

    func useSuggestion(_ text: String) {
        composerText = text
        focusComposer()
    }

    // MARK: - Image preview

    func previewImage(_ attachment: ImageAttachment) {
        previewedImage = attachment
        // The composer keeps the responder chain; release it so keystrokes do
        // not reach the text behind the overlay.
        _ = NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func dismissImagePreview() {
        previewedImage = nil
    }


    // MARK: - Lifecycle

    func bootstrap() async {
        settings = await settingsStore.load()
        conversations = await conversationStore.loadAll()
        for endpoint in settings.endpoints {
            if let key = KeychainStore.get(for: endpoint.id.uuidString), !key.isEmpty {
                apiKeys[endpoint.id] = key
            }
        }
        if activeConversationID == nil {
            activeConversationID = conversations.first?.id
        }
        await refreshModels(silently: true)
    }

    func saveSettings() {
        let snapshot = settings
        Task { await settingsStore.save(snapshot) }
    }

    // MARK: - Conversations

    func newConversation() {
        let endpoint = activeEndpoint
        let conversation = Conversation(
            endpointID: endpoint?.id ?? UUID(),
            endpointName: endpoint?.name ?? "",
            model: currentModel
        )
        conversations.insert(conversation, at: 0)
        activeConversationID = conversation.id
        composerText = ""
        pendingImages = []
        Task { await conversationStore.save(conversation) }
    }

    func selectConversation(_ id: UUID) {
        activeConversationID = id
    }

    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        if activeConversationID == conversation.id {
            activeConversationID = conversations.first?.id
        }
        Task { await conversationStore.delete(conversation) }
    }

    func renameConversation(_ conversation: Conversation, to title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].title = title
        Task { await conversationStore.save(conversations[index]) }
    }

    func duplicate(_ conversation: Conversation) {
        var copy = conversation
        copy.id = UUID()
        copy.title = conversation.title + " copy"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.turns = conversation.turns
        conversations.insert(copy, at: 0)
        activeConversationID = copy.id
        Task { await conversationStore.save(copy) }
    }

    // MARK: - Endpoints

    func addEndpoint(_ endpoint: ProviderEndpoint) {
        settings.endpoints.append(endpoint)
        settings.activeEndpointID = endpoint.id
        saveSettings()
    }

    func removeEndpoint(_ endpoint: ProviderEndpoint) {
        settings.endpoints.removeAll { $0.id == endpoint.id }
        if settings.activeEndpointID == endpoint.id {
            settings.activeEndpointID = settings.endpoints.first?.id
        }
        apiKeys[endpoint.id] = nil
        saveSettings()
    }

    func selectEndpoint(_ endpoint: ProviderEndpoint) {
        settings.activeEndpointID = endpoint.id
        settings.selectedModel = ""
        saveSettings()
        Task { await refreshModels() }
    }

    func apiKey(for endpoint: ProviderEndpoint) -> String {
        apiKeys[endpoint.id] ?? ""
    }

    func setAPIKey(_ value: String, for endpoint: ProviderEndpoint) {
        apiKeys[endpoint.id] = value
        try? KeychainStore.set(value, for: endpoint.id.uuidString)
    }

    func refreshModels(silently: Bool = false) async {
        guard let endpoint = activeEndpoint else { return }

        // Some servers do not implement /models – respect the setting instead of
        // showing an error for a perfectly usable endpoint.
        guard endpoint.listsModels else {
            availableModels = endpoint.defaultModel.isEmpty
                ? []
                : [RemoteModel(id: endpoint.defaultModel)]
            endpointStatus[endpoint.id] = "Using the configured model"
            return
        }

        isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            let client = try ProviderClient(endpoint: endpoint, apiKey: apiKeys[endpoint.id])
            let models = try await client.listModels()
            availableModels = models
            endpointStatus[endpoint.id] = "\(models.count) model\(models.count == 1 ? "" : "s") available"
        } catch {
            availableModels = []
            endpointStatus[endpoint.id] = error.localizedDescription
            if !silently {
                errorMessage = error.localizedDescription
            }
        }
    }

    func testConnection(to endpoint: ProviderEndpoint) async {
        do {
            let configuration = try ProviderConfiguration.make(endpoint: endpoint, apiKey: apiKeys[endpoint.id])
            let (data, head) = try await HTTPTransport.perform(
                RequestBuilderForTesting.makeRequest(for: configuration)
            )
            endpointStatus[endpoint.id] = head.isSuccess
                ? "Connected (\(head.statusCode))"
                : "HTTP \(head.statusCode): \(String(decoding: data, as: UTF8.self).prefix(120))"
        } catch {
            endpointStatus[endpoint.id] = error.localizedDescription
        }
    }

    // MARK: - Attachments

    func addImages(at urls: [URL]) async {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                errorMessage = "Could not read \(url.lastPathComponent)"
                continue
            }
            addImageData(data)
        }
    }

    func addImageData(_ data: Data) {
        do {
            let payload = try ImageProcessor.prepare(data: data)
            let thumbnail = NSImage(data: payload.data) ?? NSImage(size: NSSize(width: 64, height: 64))
            pendingImages.append(PendingImage(payload: payload, thumbnail: thumbnail))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pasteImageFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else {
            errorMessage = "The clipboard does not contain an image"
            return
        }
        addImageData(data)
    }

    func removeImage(_ image: PendingImage) {
        pendingImages.removeAll { $0.id == image.id }
    }

    func clearPendingImages() {
        pendingImages.removeAll()
    }

    // MARK: - Model

    func selectModel(_ id: String) {
        settings.selectedModel = id
        saveSettings()
    }

    // MARK: - Sending

    func send() {
        guard canSend else { return }
        guard let endpoint = activeEndpoint else {
            errorMessage = "Configure a server in Settings first."
            showSettings = true
            return
        }
        let model = currentModel
        guard !model.isEmpty else {
            errorMessage = "Select a model first."
            return
        }

        let text = composerText
        let images = pendingImages
        composerText = ""
        pendingImages = []
        isSending = true

        streamTask = Task { [weak self] in
            await self?.streamReply(
                endpoint: endpoint,
                model: model,
                newUserMessage: (text: text, images: images)
            )
        }
    }

    /// Drops the answer to the last question and asks again.
    func regenerate() {
        guard !isSending, let endpoint = activeEndpoint, var conversation = currentConversation else { return }
        guard let lastUserIndex = conversation.turns.lastIndex(where: { $0.role == .user }) else { return }
        let model = conversation.model.isEmpty ? currentModel : conversation.model
        guard !model.isEmpty else {
            errorMessage = "Select a model first."
            return
        }

        if lastUserIndex + 1 < conversation.turns.count {
            conversation.turns.removeSubrange((lastUserIndex + 1)..<conversation.turns.count)
        }
        conversation.updatedAt = Date()
        update(conversation)
        isSending = true

        streamTask = Task { [weak self] in
            await self?.streamReply(endpoint: endpoint, model: model, newUserMessage: nil)
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isSending = false
    }

    private func streamReply(
        endpoint: ProviderEndpoint,
        model: String,
        newUserMessage: (text: String, images: [PendingImage])?
    ) async {
        defer { isSending = false }

        // Timings: measured client side, overridden by server values if reported.
        let startedAt = Date()
        var firstTokenAt: Date?
        var serverTimings: ServerTimings?

        var conversation = currentConversation ?? makeConversation(endpoint: endpoint, model: model)
        if currentConversation == nil {
            conversations.insert(conversation, at: 0)
            activeConversationID = conversation.id
        }
        let conversationID = conversation.id

        if let newUserMessage {
            var attachments: [ImageAttachment] = []
            for image in newUserMessage.images {
                if let attachment = try? await conversationStore.storeAttachment(
                    data: image.payload.data,
                    mimeType: image.payload.mimeType
                ) {
                    attachments.append(attachment)
                }
            }
            conversation.turns.append(
                ChatTurn(role: .user, text: newUserMessage.text, images: attachments)
            )
        }

        let assistantTurn = ChatTurn(role: .assistant, isStreaming: true)
        conversation.turns.append(assistantTurn)
        conversation.model = model
        conversation.endpointID = endpoint.id
        conversation.endpointName = endpoint.name
        conversation.updatedAt = Date()
        if conversation.title == "New chat", let text = newUserMessage?.text, !text.isEmpty {
            conversation.title = Conversation.makeTitle(from: text)
        }
        update(conversation)

        // Load the binary payload of every referenced image.
        var payloads: [UUID: Data] = [:]
        for turn in conversation.turns {
            for attachment in turn.images {
                if let data = await conversationStore.loadAttachmentData(attachment) {
                    payloads[attachment.id] = data
                }
            }
        }

        let system = settings.sendSystemPrompt ? endpoint.systemPrompt : nil
        let request = ChatRequestBuilder.build(
            turns: conversation.turns,
            attachments: payloads,
            system: system,
            model: model,
            temperature: endpoint.temperature,
            topP: endpoint.topP,
            maxTokens: endpoint.maxTokens
        )

        do {
            let client = try ProviderClient(endpoint: endpoint, apiKey: apiKeys[endpoint.id])
            for try await event in client.stream(request: request) {
                if Task.isCancelled { break }

                switch event {
                case .text, .reasoning:
                    if firstTokenAt == nil { firstTokenAt = Date() }
                case .timings(let timings):
                    serverTimings = timings
                default:
                    break
                }

                apply(event: event, to: assistantTurn.id, in: conversationID)
            }
        } catch {
            if Task.isCancelled {
                apply(event: .finished(reason: .cancelled, usage: nil), to: assistantTurn.id, in: conversationID)
            } else {
                apply(event: .failed(error.localizedDescription), to: assistantTurn.id, in: conversationID)
            }
        }

        // Latency / throughput for this answer.
        let finishedAt = Date()
        if let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
           let turnIndex = conversations[conversationIndex].turns.firstIndex(where: { $0.id == assistantTurn.id }) {
            let usage = conversations[conversationIndex].turns[turnIndex].usage
            conversations[conversationIndex].turns[turnIndex].metrics = TurnMetricsCalculator.compute(
                startedAt: startedAt,
                firstTokenAt: firstTokenAt,
                finishedAt: finishedAt,
                usage: usage,
                timings: serverTimings
            )
        }

        // Make sure the assistant turn never stays in the "streaming" state.
        if let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
           let turnIndex = conversations[conversationIndex].turns.firstIndex(where: { $0.id == assistantTurn.id }),
           conversations[conversationIndex].turns[turnIndex].isStreaming {
            conversations[conversationIndex].turns[turnIndex].isStreaming = false
            if conversations[conversationIndex].turns[turnIndex].stopReason == nil {
                conversations[conversationIndex].turns[turnIndex].stopReason = .cancelled
            }
        }

        // Save the conversation that actually streamed, even if the user moved
        // to another conversation (or deleted it) meanwhile.
        if let streamed = conversations.first(where: { $0.id == conversationID }) {
            await conversationStore.save(streamed)
        }
    }

    private func makeConversation(endpoint: ProviderEndpoint, model: String) -> Conversation {
        Conversation(
            endpointID: endpoint.id,
            endpointName: endpoint.name,
            model: model
        )
    }

    private func update(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
    }

    private func apply(event: StreamEvent, to turnID: UUID, in conversationID: UUID) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard let turnIndex = conversations[conversationIndex].turns.firstIndex(where: { $0.id == turnID }) else { return }

        switch event {
        case .started:
            break
        case .text(let chunk):
            conversations[conversationIndex].turns[turnIndex].text += chunk
            if conversationID == activeConversationID { streamTick &+= 1 }
        case .reasoning(let chunk):
            conversations[conversationIndex].turns[turnIndex].reasoning += chunk
            if conversationID == activeConversationID { streamTick &+= 1 }
        case .toolCall(let name, let arguments):
            conversations[conversationIndex].turns[turnIndex].text += "\n\n**Tool call:** `\(name)(\(arguments))`\n"
            if conversationID == activeConversationID { streamTick &+= 1 }
        case .finished(let reason, let usage):
            conversations[conversationIndex].turns[turnIndex].stopReason = reason
            conversations[conversationIndex].turns[turnIndex].usage = usage
            conversations[conversationIndex].turns[turnIndex].isStreaming = false
        case .timings:
            break
        case .failed(let message):
            conversations[conversationIndex].turns[turnIndex].errorMessage = message
            conversations[conversationIndex].turns[turnIndex].isStreaming = false
        }
        conversations[conversationIndex].updatedAt = Date()
    }
}

/// Small helper that turns a provider configuration into a request the test
/// connection button can use.
enum RequestBuilderForTesting {
    static func makeRequest(for configuration: ProviderConfiguration) -> URLRequest {
        var request = URLRequest(url: configuration.modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (key, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}
