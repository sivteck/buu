import Foundation
import Testing
@testable import BUUKit

@Suite("Steering and queue planning")
struct SteerQueueTests {

    @Test("Pending steers apply in stable order")
    func pendingOrder() {
        let items = [
            SteerItem(text: "third", order: 2),
            SteerItem(text: "first", order: 0),
            SteerItem(text: "second", order: 1),
        ]
        #expect(SteerPlanner.pending(items).map(\.text) == ["first", "second", "third"])
    }

    @Test("Only queued steers are mutable; applying is immutable")
    func mutabilityRace() {
        var queued = SteerItem(text: "queued", state: .queued)
        var applying = SteerItem(text: "applying", state: .applying)
        let applied = SteerItem(text: "applied", state: .applied, appliedInRound: 4)
        #expect(SteerPlanner.canMutate(queued))
        #expect(!SteerPlanner.canMutate(applying))
        #expect(!SteerPlanner.canMutate(applied))
        queued.state = .cancelled
        applying.state = .failed
        #expect(!SteerPlanner.canMutate(queued))
        #expect(!SteerPlanner.canMutate(applying))
    }

    @Test("Steer orders normalize without changing content")
    func normalizeOrders() {
        let items = [
            SteerItem(text: "b", order: 9),
            SteerItem(text: "a", order: 2),
        ]
        let normalized = SteerPlanner.normalized(items)
        #expect(normalized.map(\.text) == ["a", "b"])
        #expect(normalized.map(\.order) == [0, 1])
    }

    @Test("Queue picks the next pending task and applies failure policy")
    func queuePolicy() {
        let running = QueuedTask(prompt: "running", state: .running, order: 0)
        let next = QueuedTask(prompt: "next", state: .queued, order: 1)
        let later = QueuedTask(prompt: "later", state: .queued, order: 2)
        #expect(QueuedTaskPlanner.next([running, later, next])?.prompt == "next")

        var failed = next
        failed.state = .failed
        #expect(QueuedTaskPlanner.shouldStopOnFailure(failed, stopOnFailure: true))
        #expect(!QueuedTaskPlanner.shouldStopOnFailure(failed, stopOnFailure: false))

        var done = next
        done.state = .done
        #expect(!QueuedTaskPlanner.shouldStopOnFailure(done, stopOnFailure: true))
    }

    @Test("Steer and queued task models survive a settings round trip")
    func persistenceRoundTrip() throws {
        let artifactID = UUID()
        let steer = SteerItem(
            text: "Check page 2",
            attachmentIDs: [artifactID],
            state: .applied,
            appliedInRound: 34,
            order: 0
        )
        let queued = QueuedTask(
            prompt: "Save the summary",
            attachmentIDs: [artifactID],
            providerID: UUID(),
            model: "test-model",
            maxRounds: 12,
            vmStatePolicy: .keepState,
            continueConversation: true,
            state: .queued,
            order: 1
        )
        let task = AgenticTaskRecord(
            kind: .mac,
            title: "Workspace",
            configurationID: UUID(),
            steers: [steer],
            queuedTasks: [queued],
            queueStopOnFailure: true,
            queuePaused: false
        )
        let data = try JSONCoding.encode(task)
        let decoded = try JSONCoding.decode(AgenticTaskRecord.self, from: data)
        #expect(decoded.steers?.first?.appliedInRound == 34)
        #expect(decoded.steers?.first?.attachmentIDs == [artifactID])
        #expect(decoded.queuedTasks?.first?.model == "test-model")
        #expect(decoded.queuedTasks?.first?.vmStatePolicy == .keepState)
        #expect(decoded.queuedTasks?.first?.continueConversation == true)
        #expect(decoded.queueStopOnFailure == true)
    }

    @Test("Steer cap is enforced by the pending count")
    func steerCap() {
        let items = (0..<SteerPlanner.maxPending).map { SteerItem(text: "\($0)", order: $0) }
        #expect(SteerPlanner.pending(items).count == SteerPlanner.maxPending)
        #expect(SteerPlanner.pending(items + [SteerItem(text: "extra", order: 99)]).count == SteerPlanner.maxPending + 1)
    }
}
