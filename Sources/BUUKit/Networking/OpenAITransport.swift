import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks the OpenAI `/chat/completions` protocol.
public struct OpenAITransport: Sendable {
    public let configuration: ProviderConfiguration

    public init(configuration: ProviderConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Models

    public func listModels() async throws -> [RemoteModel] {
        let request = try RequestBuilder.makeURLRequest(
            url: configuration.modelsURL,
            method: "GET",
            queryItems: configuration.queryItems,
            headers: configuration.headers,
            timeout: min(configuration.timeout, 30)
        )
        let (data, head) = try await HTTPTransport.perform(request)
        guard head.isSuccess else {
            throw HTTPError(statusCode: head.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try Self.parseModels(data)
    }

    static func parseModels(_ data: Data) throws -> [RemoteModel] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let id: String?
                let name: String?
                let displayName: String?
                let ownedBy: String?

                enum CodingKeys: String, CodingKey {
                    case id, name
                    case displayName = "display_name"
                    case ownedBy = "owned_by"
                }
            }
            let data: [Entry]?
            let models: [Entry]?
        }

        let response = try JSONCoding.decode(Response.self, from: data)
        let entries = response.data ?? response.models ?? []
        return entries.compactMap { entry in
            guard let id = entry.id ?? entry.name, !id.isEmpty else { return nil }
            return RemoteModel(id: id, displayName: entry.displayName ?? id, ownedBy: entry.ownedBy)
        }
    }

    // MARK: - Chat

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try Self.makeBody(request)
                    let urlRequest = try RequestBuilder.makeURLRequest(
                        url: configuration.chatURL,
                        method: "POST",
                        queryItems: configuration.queryItems,
                        headers: configuration.headers,
                        body: body,
                        timeout: configuration.timeout
                    )

                    var decoder = SSEDecoder()
                    var jsonBuffer = Data()
                    var failureStatus: Int?
                    var failureBody = Data()
                    var mode = StreamSupport.ResponseMode.unknown
                    var state = OpenAIStreamState()

                    func emit(_ events: [StreamEvent]) {
                        for event in events { continuation.yield(event) }
                    }

                    for try await chunk in HTTPTransport.stream(urlRequest) {
                        switch chunk {
                        case .head(let head):
                            guard head.isSuccess else {
                                failureStatus = head.statusCode
                                continue
                            }
                            let type = head.contentType.lowercased()
                            if type.contains("text/event-stream") {
                                mode = .sse
                            } else if type.contains("json") {
                                mode = .json
                            }
                        case .body(let data):
                            if failureStatus != nil {
                                failureBody.append(data)
                                continue
                            }
                            switch mode {
                            case .json:
                                jsonBuffer.append(data)
                            case .unknown:
                                if StreamSupport.looksLikeSSE(data) {
                                    mode = .sse
                                    for event in decoder.decode(data) {
                                        emit(try Self.events(from: event, state: &state))
                                    }
                                } else {
                                    mode = .json
                                    jsonBuffer.append(data)
                                }
                            case .sse:
                                for event in decoder.decode(data) {
                                    emit(try Self.events(from: event, state: &state))
                                }
                            }
                        case .complete:
                            break
                        }
                    }

                    if let failureStatus {
                        throw HTTPError(
                            statusCode: failureStatus,
                            body: String(decoding: failureBody, as: UTF8.self)
                        )
                    }

                    for event in decoder.finish() {
                        emit(try Self.events(from: event, state: &state))
                    }

                    if mode == .json, !jsonBuffer.isEmpty {
                        emit(try Self.events(fromJSON: jsonBuffer, state: &state))
                    }

                    emit(Self.flushToolCalls(state: &state))
                    continuation.yield(.finished(reason: state.stopReason, usage: state.usage))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Body

    static func makeBody(_ request: ChatRequest) throws -> Data {
        var messages: [OpenAIChatRequest.Message] = []

        if let system = request.system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(OpenAIChatRequest.Message(
                role: "system",
                content: .text(system),
                toolCalls: nil,
                toolCallID: nil,
                reasoningContent: nil
            ))
        }

        for message in request.messages {
            let blocks = message.blocks.filter { block in
                switch block {
                case .text(let text): return !text.isEmpty
                case .image: return true
                }
            }
            let hasToolCalls = !message.toolCalls.isEmpty
            let isToolResult = message.role == .tool && message.toolCallID != nil
            guard !blocks.isEmpty || hasToolCalls || isToolResult else { continue }

            let content: OpenAIChatRequest.Content?
            if blocks.isEmpty {
                content = isToolResult ? .text(message.text) : nil
            } else if blocks.count == 1, case .text(let text) = blocks[0] {
                content = .text(text)
            } else {
                var parts: [OpenAIChatRequest.Part] = []
                for block in blocks {
                    switch block {
                    case .text(let text): parts.append(.text(text))
                    case .image(let payload): parts.append(.image(payload))
                    }
                }
                content = .parts(parts)
            }

            messages.append(OpenAIChatRequest.Message(
                role: Self.wireRole(message.role),
                content: content,
                toolCalls: hasToolCalls ? message.toolCalls.map(OpenAIChatRequest.ToolCall.init) : nil,
                toolCallID: message.toolCallID,
                reasoningContent: message.reasoning
            ))
        }

        let body = OpenAIChatRequest(
            model: request.model,
            messages: messages,
            stream: true,
            streamOptions: OpenAIChatRequest.StreamOptions(includeUsage: true),
            temperature: request.temperature,
            topP: request.topP,
            maxTokens: request.maxTokens,
            stop: request.stopSequences.isEmpty ? nil : request.stopSequences,
            tools: request.tools.isEmpty ? nil : request.tools.map(OpenAIChatRequest.Tool.init)
        )
        return try JSONCoding.encode(body)
    }

    static func wireRole(_ role: MessageRole) -> String {
        switch role {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        }
    }

    // MARK: - Decoding

    struct PartialToolCall {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    struct OpenAIStreamState {
        var usage: TokenUsage?
        var stopReason = StopReason.unknown
        var toolCalls: [Int: PartialToolCall] = [:]
    }

    static func events(from event: SSEEvent, state: inout OpenAIStreamState) throws -> [StreamEvent] {
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return [] }
        if payload == "[DONE]" { return [] }

        guard let data = payload.data(using: .utf8) else { return [] }
        let chunk: OpenAIStreamChunk
        do {
            chunk = try JSONCoding.decode(OpenAIStreamChunk.self, from: data)
        } catch {
            // Ignore chunks we do not understand (keep-alives, vendor extensions).
            return []
        }

        if let apiError = chunk.error {
            throw apiError
        }
        if let reported = chunk.tokenUsage {
            state.usage = reported
        }

        var events: [StreamEvent] = []
        if let timings = chunk.serverTimings {
            events.append(.timings(timings))
        }
        for choice in chunk.choices ?? [] {
            if let content = choice.delta?.content, !content.isEmpty {
                events.append(.text(content))
            }
            if let reasoning = choice.delta?.reasoningContent ?? choice.delta?.reasoning, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            for toolCall in choice.delta?.toolCalls ?? [] {
                let index = toolCall.index ?? 0
                var partial = state.toolCalls[index] ?? PartialToolCall()
                if let id = toolCall.id, !id.isEmpty { partial.id = id }
                if let name = toolCall.function?.name, !name.isEmpty {
                    partial.name = (partial.name ?? "") + name
                }
                if let arguments = toolCall.function?.arguments, !arguments.isEmpty {
                    partial.arguments += arguments
                }
                state.toolCalls[index] = partial
            }
            if let reason = choice.finishReason {
                state.stopReason = StopReason(wireValue: reason)
            }
        }
        return events
    }

    /// OpenAI streams tool arguments in pieces. Emit one complete call per index
    /// when the stream ends, not one event per delta.
    static func flushToolCalls(state: inout OpenAIStreamState) -> [StreamEvent] {
        guard !state.toolCalls.isEmpty else { return [] }
        let calls = state.toolCalls
            .sorted { $0.key < $1.key }
            .compactMap { _, partial -> StreamEvent? in
                guard let name = partial.name, !name.isEmpty else { return nil }
                return .toolCall(id: partial.id, name: name, arguments: partial.arguments)
            }
        state.toolCalls.removeAll(keepingCapacity: true)
        return calls
    }

    static func events(fromJSON data: Data, state: inout OpenAIStreamState) throws -> [StreamEvent] {
        let response: OpenAIChatResponse
        do {
            response = try JSONCoding.decode(OpenAIChatResponse.self, from: data)
        } catch {
            throw HTTPError(statusCode: 200, body: "Unexpected response: \(JSONCoding.describe(error))")
        }
        if let apiError = response.error {
            throw apiError
        }
        if let reported = response.tokenUsage {
            state.usage = reported
        }

        var events: [StreamEvent] = []
        for choice in response.choices ?? [] {
            if let content = choice.message?.content ?? choice.delta?.content, !content.isEmpty {
                events.append(.text(content))
            }
            if let reasoning = choice.message?.reasoningContent ?? choice.message?.reasoning, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            for toolCall in choice.message?.toolCalls ?? [] {
                guard let name = toolCall.function?.name, !name.isEmpty else { continue }
                events.append(.toolCall(
                    id: toolCall.id,
                    name: name,
                    arguments: toolCall.function?.arguments ?? ""
                ))
            }
            if let reason = choice.finishReason {
                state.stopReason = StopReason(wireValue: reason)
            }
        }
        return events
    }
}
