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
                    var mode = StreamSupport.ResponseMode.unknown
                    var state = OpenAIStreamState()

                    func emit(_ events: [StreamEvent]) {
                        for event in events { continuation.yield(event) }
                    }

                    for try await chunk in HTTPTransport.stream(urlRequest) {
                        switch chunk {
                        case .head(let head):
                            guard head.isSuccess else {
                                throw HTTPError(statusCode: head.statusCode, body: "")
                            }
                            let type = head.contentType.lowercased()
                            if type.contains("text/event-stream") {
                                mode = .sse
                            } else if type.contains("json") {
                                mode = .json
                            }
                        case .body(let data):
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

                    for event in decoder.finish() {
                        emit(try Self.events(from: event, state: &state))
                    }

                    if mode == .json, !jsonBuffer.isEmpty {
                        emit(try Self.events(fromJSON: jsonBuffer, state: &state))
                    }

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
            messages.append(OpenAIChatRequest.Message(role: "system", content: .text(system)))
        }

        for message in request.messages {
            let blocks = message.blocks.filter { block in
                switch block {
                case .text(let text): return !text.isEmpty
                case .image: return true
                }
            }
            guard !blocks.isEmpty else { continue }

            let content: OpenAIChatRequest.Content
            if blocks.count == 1, case .text(let text) = blocks[0] {
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
            messages.append(OpenAIChatRequest.Message(role: Self.wireRole(message.role), content: content))
        }

        let body = OpenAIChatRequest(
            model: request.model,
            messages: messages,
            stream: true,
            streamOptions: OpenAIChatRequest.StreamOptions(includeUsage: true),
            temperature: request.temperature,
            topP: request.topP,
            maxTokens: request.maxTokens,
            stop: request.stopSequences.isEmpty ? nil : request.stopSequences
        )
        return try JSONCoding.encode(body)
    }

    static func wireRole(_ role: MessageRole) -> String {
        switch role {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        }
    }

    // MARK: - Decoding

    struct OpenAIStreamState {
        var usage: TokenUsage?
        var stopReason = StopReason.unknown
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
            if let reasoning = choice.delta?.reasoningContent, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            for toolCall in choice.delta?.toolCalls ?? [] {
                let name = toolCall.function?.name ?? toolCall.id ?? "tool"
                let arguments = toolCall.function?.arguments ?? ""
                events.append(.toolCall(name: name, arguments: arguments))
            }
            if let reason = choice.finishReason {
                state.stopReason = StopReason(wireValue: reason)
            }
        }
        return events
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
            if let reasoning = choice.message?.reasoningContent, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            if let reason = choice.finishReason {
                state.stopReason = StopReason(wireValue: reason)
            }
        }
        return events
    }
}
