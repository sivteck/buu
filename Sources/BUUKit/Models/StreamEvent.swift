import Foundation

/// Events produced while a response is streaming.
public enum StreamEvent: Sendable {
    /// The server accepted the request.
    case started(model: String?)
    /// A chunk of assistant text.
    case text(String)
    /// A chunk of "thinking"/reasoning text (DeepSeek, Anthropic thinking blocks…).
    case reasoning(String)
    /// A tool call requested by the model. `id` is the provider's call id when
    /// available; preserving it matters for thinking-mode continuity.
    case toolCall(id: String?, name: String, arguments: String)
    /// The server reported its own throughput numbers (llama.cpp, LM Studio).
    case timings(ServerTimings)
    /// Generation finished.
    case finished(reason: StopReason, usage: TokenUsage?)
    /// The stream failed.
    case failed(String)
}
