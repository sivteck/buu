import Foundation
import Testing
@testable import BUUKit

@Suite("Turn metrics")
struct TurnMetricsTests {

    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("Computes TTFT and generation speed from client timings")
    func computesFromTimestamps() {
        let first = start.addingTimeInterval(0.4)
        let finished = first.addingTimeInterval(2.0)

        let metrics = TurnMetricsCalculator.compute(
            startedAt: start,
            firstTokenAt: first,
            finishedAt: finished,
            usage: TokenUsage(inputTokens: 1_970, outputTokens: 1_447)
        )

        #expect(abs((metrics.timeToFirstToken ?? 0) - 0.4) < 0.001)
        // 1447 tokens over 2 s
        #expect(abs((metrics.generationTokensPerSecond ?? 0) - 723.5) < 0.01)
        // 1970 prompt tokens over the 0.4 s prefill window
        #expect(abs((metrics.prefillTokensPerSecond ?? 0) - 4_925) < 0.01)
    }

    @Test("Server reported timings win over client estimates")
    func prefersServerTimings() {
        let first = start.addingTimeInterval(0.4)
        let finished = first.addingTimeInterval(2.0)

        let metrics = TurnMetricsCalculator.compute(
            startedAt: start,
            firstTokenAt: first,
            finishedAt: finished,
            usage: TokenUsage(inputTokens: 100, outputTokens: 200),
            timings: ServerTimings(
                promptTokens: 100,
                prefillTokensPerSecond: 850,
                predictedTokens: 200,
                generationTokensPerSecond: 55.5,
                timeToFirstToken: 0.12
            )
        )

        #expect(metrics.timeToFirstToken == 0.12)
        #expect(metrics.generationTokensPerSecond == 55.5)
        #expect(metrics.prefillTokensPerSecond == 850)
    }

    @Test("Falls back to server token counts when usage is missing")
    func fallsBackToServerCounts() {
        let first = start.addingTimeInterval(0.5)
        let finished = first.addingTimeInterval(1.5)

        let metrics = TurnMetricsCalculator.compute(
            startedAt: start,
            firstTokenAt: first,
            finishedAt: finished,
            usage: nil,
            timings: ServerTimings(promptTokens: 50, predictedTokens: 150)
        )

        #expect(abs((metrics.prefillTokensPerSecond ?? 0) - 100) < 0.01)
        #expect(abs((metrics.generationTokensPerSecond ?? 0) - 100) < 0.01)
    }

    @Test("Does not invent numbers from a zero-length window")
    func ignoresDegenerateWindows() {
        let metrics = TurnMetricsCalculator.compute(
            startedAt: start,
            firstTokenAt: start,
            finishedAt: start,
            usage: TokenUsage(inputTokens: 10, outputTokens: 10)
        )

        #expect(metrics.prefillTokensPerSecond == nil)
        #expect(metrics.generationTokensPerSecond == nil)
        #expect(metrics.timeToFirstToken == 0)
    }

    @Test("Context size is prompt + completion")
    func contextSize() {
        #expect(TokenUsage(inputTokens: 1_970, outputTokens: 1_447).contextTokens == 3_417)
        #expect(TokenUsage(inputTokens: 10).contextTokens == nil)
    }
}

@Suite("Server timings decoding")
struct ServerTimingsDecodingTests {

    @Test("Reads llama.cpp timings from a stream chunk")
    func llamaCpp() throws {
        var state = OpenAITransport.OpenAIStreamState()
        let event = SSEEvent(data: #"""
        {"choices":[],"timings":{"prompt_n":24,"prompt_ms":101.2,"prompt_per_second":237.1,
        "predicted_n":128,"predicted_ms":2100.5,"predicted_per_second":60.9}}
        """#)

        let events = try OpenAITransport.events(from: event, state: &state)
        guard case .timings(let timings)? = events.first else {
            Issue.record("expected a timings event")
            return
        }
        #expect(timings.prefillTokensPerSecond == 237.1)
        #expect(timings.generationTokensPerSecond == 60.9)
        #expect(timings.promptTokens == 24)
        #expect(timings.predictedTokens == 128)
    }

    @Test("Reads LM Studio stats from a stream chunk")
    func lmStudio() throws {
        var state = OpenAITransport.OpenAIStreamState()
        let event = SSEEvent(data: #"{"choices":[],"stats":{"tokens_per_second":41.7,"time_to_first_token":0.21}}"#)

        let events = try OpenAITransport.events(from: event, state: &state)
        guard case .timings(let timings)? = events.first else {
            Issue.record("expected a timings event")
            return
        }
        #expect(timings.generationTokensPerSecond == 41.7)
        #expect(timings.timeToFirstToken == 0.21)
        #expect(timings.prefillTokensPerSecond == nil)
    }

    @Test("No timings event when the server reports nothing")
    func noTimings() throws {
        var state = OpenAITransport.OpenAIStreamState()
        let event = SSEEvent(data: #"{"choices":[{"delta":{"content":"hi"}}]}"#)
        let events = try OpenAITransport.events(from: event, state: &state)
        #expect(events.count == 1)
        if case .timings = events[0] {
            Issue.record("did not expect timings")
        }
    }
}
