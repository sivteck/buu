import Foundation

/// Timings reported by the server itself (llama.cpp `timings`, LM Studio
/// `stats`). Every field is optional: most servers report nothing at all.
public struct ServerTimings: Codable, Hashable, Sendable {
    /// Prompt tokens counted by the server during prefill.
    public var promptTokens: Int?
    /// Prefill throughput in tokens per second.
    public var prefillTokensPerSecond: Double?
    /// Tokens generated.
    public var predictedTokens: Int?
    /// Generation throughput in tokens per second.
    public var generationTokensPerSecond: Double?
    /// Time from request to first token, in seconds.
    public var timeToFirstToken: TimeInterval?

    public init(
        promptTokens: Int? = nil,
        prefillTokensPerSecond: Double? = nil,
        predictedTokens: Int? = nil,
        generationTokensPerSecond: Double? = nil,
        timeToFirstToken: TimeInterval? = nil
    ) {
        self.promptTokens = promptTokens
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.predictedTokens = predictedTokens
        self.generationTokensPerSecond = generationTokensPerSecond
        self.timeToFirstToken = timeToFirstToken
    }

    public var isEmpty: Bool {
        promptTokens == nil
            && prefillTokensPerSecond == nil
            && predictedTokens == nil
            && generationTokensPerSecond == nil
            && timeToFirstToken == nil
    }
}

/// Per-answer performance numbers, stored with the turn.
public struct TurnMetrics: Codable, Hashable, Sendable {
    /// Seconds from sending the request to the first token.
    public var timeToFirstToken: TimeInterval?
    /// Prompt processing throughput in tokens per second.
    public var prefillTokensPerSecond: Double?
    /// Generation throughput in tokens per second.
    public var generationTokensPerSecond: Double?

    public init(
        timeToFirstToken: TimeInterval? = nil,
        prefillTokensPerSecond: Double? = nil,
        generationTokensPerSecond: Double? = nil
    ) {
        self.timeToFirstToken = timeToFirstToken
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.generationTokensPerSecond = generationTokensPerSecond
    }

    public var isEmpty: Bool {
        timeToFirstToken == nil
            && prefillTokensPerSecond == nil
            && generationTokensPerSecond == nil
    }
}

/// Pure metrics math, so it can be unit tested without a network.
public enum TurnMetricsCalculator {

    /// - Parameters:
    ///   - startedAt: when the request was sent.
    ///   - firstTokenAt: when the first text/reasoning delta arrived.
    ///   - finishedAt: when the stream completed.
    ///   - usage: token counts reported by the server.
    ///   - timings: timings reported by the server (wins over estimates).
    public static func compute(
        startedAt: Date,
        firstTokenAt: Date?,
        finishedAt: Date,
        usage: TokenUsage?,
        timings: ServerTimings? = nil
    ) -> TurnMetrics {
        let measuredFirstToken = firstTokenAt.map { $0.timeIntervalSince(startedAt) }
        let timeToFirstToken = timings?.timeToFirstToken ?? measuredFirstToken

        let generationWindow = firstTokenAt.map { finishedAt.timeIntervalSince($0) }
            ?? finishedAt.timeIntervalSince(startedAt)

        var prefill = timings?.prefillTokensPerSecond
        if prefill == nil,
           let ttft = timeToFirstToken,
           ttft > 0.02,
           let promptTokens = usage?.inputTokens ?? timings?.promptTokens,
           promptTokens > 0 {
            prefill = Double(promptTokens) / ttft
        }

        var generation = timings?.generationTokensPerSecond
        if generation == nil,
           generationWindow > 0.05,
           let completionTokens = usage?.outputTokens ?? timings?.predictedTokens,
           completionTokens > 0 {
            generation = Double(completionTokens) / generationWindow
        }

        return TurnMetrics(
            timeToFirstToken: sanitiseDuration(timeToFirstToken),
            prefillTokensPerSecond: sanitiseRate(prefill),
            generationTokensPerSecond: sanitiseRate(generation)
        )
    }

    /// Discards nonsense (negative, zero, NaN, absurd values) so the UI never
    /// prints "inf tok/s" or a negative duration.
    private static func sanitiseRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value < 100_000 else { return nil }
        return value
    }

    /// A zero duration is legitimate (the first chunk arrived immediately).
    private static func sanitiseDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value < 3_600 else { return nil }
        return value
    }
}
