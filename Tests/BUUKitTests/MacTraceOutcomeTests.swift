import Foundation
import Testing
@testable import BUUKit

@Suite("Mac trace outcomes")
struct MacTraceOutcomeTests {
    @Test("Completed without errors is fully successful")
    func fullySuccessful() {
        #expect(MacTraceOutcome.classify(status: "completed", log: ["Round 1", "Assistant: Done."], contextCleared: false) == .fullySuccessful)
    }

    @Test("Completed with a tool error is partial success")
    func partialSuccess() {
        #expect(MacTraceOutcome.classify(status: "completed", log: ["Round 1", "  error: click failed"], contextCleared: false) == .partialSuccess)
    }

    @Test("Failure and stopped states")
    func failureAndStopped() {
        #expect(MacTraceOutcome.classify(status: "failed", log: [], contextCleared: false) == .failure)
        #expect(MacTraceOutcome.classify(status: "cancelled", log: [], contextCleared: false) == .stoppedMidway)
        #expect(MacTraceOutcome.classify(status: "paused", log: [], contextCleared: false) == .stoppedMidway)
    }

    @Test("Manual context clear takes precedence")
    func contextCleared() {
        #expect(MacTraceOutcome.classify(status: "completed", log: ["Context cleared"], contextCleared: true) == .contextCleared)
    }
}
