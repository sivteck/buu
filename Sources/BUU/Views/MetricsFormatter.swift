import Foundation
import BUUKit

/// Compact, localised formatting for the performance numbers.
enum MetricsFormatter {

    /// `48.3 tok/s`
    static func tokensPerSecond(_ value: Double?) -> String? {
        guard let value, value.isFinite, value > 0 else { return nil }
        if value >= 100 {
            return "\(Int(value.rounded())) tok/s"
        }
        return String(format: "%.1f tok/s", value)
    }

    /// `0.42 s`
    static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 10 {
            return String(format: "%.2f s", seconds)
        }
        return String(format: "%.1f s", seconds)
    }

    /// `3,417`
    static func count(_ value: Int?) -> String? {
        guard let value, value >= 0 else { return nil }
        return value.formatted()
    }

    /// `3,417 tok` / `1.4k tok`
    static func compactCount(_ value: Int?) -> String? {
        guard let value, value >= 0 else { return nil }
        if value >= 10_000 {
            return String(format: "%.1fk", Double(value) / 1000)
        }
        return "\(value.formatted()) tok"
    }
}

extension TurnMetrics {
    /// `0.42 s first · 48.3 tok/s · prefill 312 tok/s`
    var compactSummary: String {
        var parts: [String] = []
        if let ttft = MetricsFormatter.duration(timeToFirstToken) {
            parts.append("\(ttft) first token")
        }
        if let generation = MetricsFormatter.tokensPerSecond(generationTokensPerSecond) {
            parts.append(generation)
        }
        if let prefill = MetricsFormatter.tokensPerSecond(prefillTokensPerSecond) {
            parts.append("prefill \(prefill)")
        }
        return parts.joined(separator: " · ")
    }
}
