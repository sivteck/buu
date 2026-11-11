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

    @Test("Mac task configurations survive a round trip")
    func macTaskConfigurationsRoundTrip() async throws {
        let (store, root) = makeStore()
        let settingsStore = SettingsStore(fileStore: store)
        defer { try? FileManager.default.removeItem(at: root) }

        let mac = MacTaskConfiguration(name: "Big Sur test", machineName: "big-sur", cpus: 6, memoryGiB: 8, artifactTransferLimitGiB: 4)
        let artifact = TaskArtifact(name: "notes.txt", fileName: "notes.txt", byteCount: 12)
        let output = TaskOutput(name: "result.txt", guestPath: "/Users/buu/Desktop/BUU Outputs/result.txt", hostFileName: "result.txt", byteCount: 20)
        let screenshot = TraceScreenshot(round: 3, png: Data([0x89, 0x50, 0x4E, 0x47]))
        let macTask = AgenticTaskRecord(
            kind: .mac,
            title: "Mac Task 1",
            configurationID: mac.id,
            prompt: "Open Safari",
            agentLoop: [AgentLoopMessage(role: .user, text: "Open Safari")],
            agentLog: ["Round 1"],
            maxAgentRounds: 5,
            artifacts: [artifact],
            outputs: [output],
            traceScreenshots: [screenshot],
            queuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var settings = AppSettings(endpoints: [])
        settings.macTaskConfigurations = [mac]
        settings.activeMacTaskConfigurationID = mac.id
        settings.agenticTasks = [macTask]
        settings.activeAgenticTaskID = macTask.id
        await settingsStore.save(settings)

        let loaded = await settingsStore.load()
        #expect(loaded.macTaskConfigurations == [mac])
        #expect(loaded.activeMacTaskConfigurationID == mac.id)
        #expect(loaded.agenticTasks?.map(\.id) == [macTask.id])
        #expect(loaded.agenticTasks?.map(\.kind) == [.mac])
        #expect(loaded.agenticTasks?.map(\.configurationID) == [mac.id])
        #expect(loaded.agenticTasks?.last?.prompt == "Open Safari")
        #expect(loaded.agenticTasks?.last?.agentLoop?.first?.text == "Open Safari")
        #expect(loaded.agenticTasks?.last?.agentLog == ["Round 1"])
        #expect(loaded.agenticTasks?.last?.maxAgentRounds == 5)
        #expect(loaded.agenticTasks?.last?.artifacts?.map(\.name) == ["notes.txt"])
        #expect(loaded.agenticTasks?.last?.artifacts?.first?.byteCount == 12)
        #expect(loaded.agenticTasks?.last?.queuedAt?.timeIntervalSince1970 == 1_700_000_000)
        #expect(loaded.agenticTasks?.last?.outputs?.first?.name == "result.txt")
        #expect(loaded.agenticTasks?.last?.traceScreenshots?.first?.round == 3)
        #expect(loaded.macTaskConfigurations?.first?.artifactTransferLimitGiB == 4)
        #expect(loaded.activeAgenticTaskID == macTask.id)
    }

    @Test("Settings written before optional fields were added still decode")
    func oldSettingsDecode() throws {
        let json = """
        {"endpoints":[],"selectedModel":"old-model","showReasoning":true,
         "sendSystemPrompt":true,"appearance":"system"}
        """
        let settings = try JSONCoding.decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.selectedModel == "old-model")
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
