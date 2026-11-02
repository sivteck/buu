import Foundation
import Testing
@testable import BUUKit

@Suite("Persistence")
struct PersistenceTests {

    private func makeStore() -> (FileStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("buu-tests-\(UUID().uuidString)")
        return (FileStore(rootURL: root), root)
    }

    @Test("Conversations survive a round trip")
    func conversationRoundTrip() async throws {
        let (store, root) = makeStore()
        let conversations = ConversationStore(fileStore: store)
        defer { try? FileManager.default.removeItem(at: root) }

        var conversation = Conversation(endpointID: UUID(), model: "m")
        conversation.turns = [ChatTurn(role: .user, text: "hello")]
        await conversations.save(conversation)

        let loaded = await conversations.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.turns.first?.text == "hello")

        await conversations.delete(conversation)
        #expect(await conversations.loadAll().isEmpty)
    }

    @Test("Attachments survive a round trip")
    func attachmentRoundTrip() async throws {
        let (store, root) = makeStore()
        let conversations = ConversationStore(fileStore: store)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let attachment = try await conversations.storeAttachment(data: payload, mimeType: "image/png")
        #expect(attachment.fileName.hasSuffix(".png"))

        let loaded = await conversations.loadAttachmentData(attachment)
        #expect(loaded == payload)
    }

    @Test("Settings survive a round trip")
    func settingsRoundTrip() async throws {
        let (store, root) = makeStore()
        let settingsStore = SettingsStore(fileStore: store)
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = AppSettings(endpoints: [])
        settings.selectedModel = "test-model"
        await settingsStore.save(settings)

        let loaded = await settingsStore.load()
        #expect(loaded.selectedModel == "test-model")
    }

    @Test("Attachment names cannot escape the attachment folder")
    func attachmentPathsAreContained() async throws {
        let (store, root) = makeStore()
        let conversations = ConversationStore(fileStore: store)
        defer { try? FileManager.default.removeItem(at: root) }

        let hostile = ImageAttachment(fileName: "../../../../etc/passwd", mimeType: "image/png")
        #expect(await conversations.loadAttachmentData(hostile) == nil)
    }
}
