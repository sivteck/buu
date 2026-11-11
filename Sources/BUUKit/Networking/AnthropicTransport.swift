import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks the Anthropic `/v1/messages` protocol.
public struct AnthropicTransport: Sendable {
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
                let displayName: String?
                let type: String?

                enum CodingKeys: String, CodingKey {
                    case id, type
                    case displayName = "display_name"
                }
            }
            let data: [Entry]?
        }
        let response = try JSONCoding.decode(Response.self, from: data)
        return (response.data ?? []).compactMap { entry in
            guard let id = entry.id, !id.isEmpty else { return nil }
            return RemoteModel(id: id, displayName: entry.displayName ?? id)
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
                    var state = AnthropicStreamState()

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
        var messages: [AnthropicMessageRequest.Message] = []

        for message in request.messages {
            let role: String
            switch message.role {
            case .system: continue // system messages travel in the dedicated field
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "user" // tool results ride in a user turn
            }

            // A tool result's text belongs inside the tool_result block, not in
            // an extra text block before it.
            var content = message.role == .tool ? [] : message.blocks.compactMap { block -> AnthropicMessageRequest.Content? in
                switch block {
                case .text(let text):
                    guard !text.isEmpty else { return nil }
                    return .text(.init(text: text))
                case .image(let payload):
                    return .image(.init(source: .init(
                        mediaType: payload.mimeType,
                        data: payload.data.base64EncodedString()
                    )))
                }
            }

            for call in message.toolCalls {
                content.append(.toolUse(.init(
                    id: call.id,
                    name: call.name,
                    input: Self.toolInput(from: call.arguments)
                )))
            }

            if message.role == .tool, let callID = message.toolCallID {
                content.append(.toolResult(.init(
                    toolUseID: callID,
                    content: message.text,
                    isError: message.toolIsError
                )))
            }

            guard !content.isEmpty else { continue }

            // Anthropic expects strictly alternating user/assistant turns.
            if let last = messages.last, last.role == role {
                messages[messages.count - 1] = AnthropicMessageRequest.Message(
                    role: last.role,
                    content: last.content + content
                )
            } else {
                messages.append(AnthropicMessageRequest.Message(role: role, content: content))
            }
        }

        var systemBlocks: [AnthropicMessageRequest.TextBlock] = []
        if let system = request.system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemBlocks.append(.init(text: system))
        }

        let body = AnthropicMessageRequest(
            model: request.model,
            maxTokens: request.maxTokens ?? 4096,
            system: systemBlocks.isEmpty ? nil : systemBlocks,
            messages: messages,
            temperature: request.temperature,
            topP: request.topP,
            stream: true,
            stopSequences: request.stopSequences.isEmpty ? nil : request.stopSequences,
            tools: request.tools.isEmpty ? nil : request.tools.map(AnthropicMessageRequest.Tool.init)
        )
        return try JSONCoding.encode(body)
    }

    static func toolInput(from arguments: String) -> JSONValue {
        guard !arguments.isEmpty, let data = arguments.data(using: .utf8) else {
            return .object([:])
        }
        return (try? JSONCoding.decode(JSONValue.self, from: data)) ?? .object([:])
    }

    // MARK: - Decoding

    struct AnthropicStreamState {
        var usage: TokenUsage?
        var stopReason = StopReason.unknown
        var toolIDs: [Int: String] = [:]
        var toolNames: [Int: String] = [:]
        var toolArguments: [Int: String] = [:]
    }

    static func events(from event: SSEEvent, state: inout AnthropicStreamState) throws -> [StreamEvent] {
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return [] }
        guard let data = payload.data(using: .utf8) else { return [] }

        let streamEvent: AnthropicStreamEvent
        do {
            streamEvent = try JSONCoding.decode(AnthropicStreamEvent.self, from: data)
        } catch {
            return []
        }

        let type = streamEvent.type ?? event.name ?? ""

        switch type {
        case "message_start":
            return [.started(model: streamEvent.message?.model)]

        case "content_block_start":
            if let block = streamEvent.contentBlock, block.type == "tool_use", let index = streamEvent.index {
                state.toolIDs[index] = block.id
                state.toolNames[index] = block.name ?? "tool"
                state.toolArguments[index] = ""
            }
            return []

        case "content_block_delta":
            guard let delta = streamEvent.delta else { return [] }
            switch delta.type {
            case "text_delta":
                guard let text = delta.text, !text.isEmpty else { return [] }
                return [.text(text)]
            case "thinking_delta":
                guard let thinking = delta.thinking, !thinking.isEmpty else { return [] }
                return [.reasoning(thinking)]
            case "input_json_delta":
                guard let partial = delta.partialJSON, !partial.isEmpty,
                      let index = streamEvent.index else { return [] }
                state.toolArguments[index, default: ""] += partial
                return []
            default:
                return []
            }

        case "content_block_stop":
            guard let index = streamEvent.index, let name = state.toolNames[index] else { return [] }
            let arguments = state.toolArguments[index] ?? ""
            let id = state.toolIDs[index]
            state.toolIDs.removeValue(forKey: index)
            state.toolNames.removeValue(forKey: index)
            state.toolArguments.removeValue(forKey: index)
            return [.toolCall(id: id, name: name, arguments: arguments)]

        case "message_delta":
            if let reason = streamEvent.delta?.stopReason {
                state.stopReason = StopReason(wireValue: reason)
            }
            if let usage = streamEvent.usage {
                state.usage = TokenUsage(
                    inputTokens: usage.inputTokens ?? state.usage?.inputTokens,
                    outputTokens: usage.outputTokens ?? state.usage?.outputTokens
                )
            }
            return []

        case "error":
            if let error = streamEvent.error {
                throw error
            }
            throw HTTPError(statusCode: 200, body: "Anthropic stream error")

        default:
            return []
        }
    }

    static func events(fromJSON data: Data, state: inout AnthropicStreamState) throws -> [StreamEvent] {
        let response: AnthropicMessageResponse
        do {
            response = try JSONCoding.decode(AnthropicMessageResponse.self, from: data)
        } catch {
            throw HTTPError(statusCode: 200, body: "Unexpected response: \(JSONCoding.describe(error))")
        }
        if let error = response.error {
            throw error
        }
        if let usage = response.tokenUsage {
            state.usage = usage
        }
        if let reason = response.stopReason {
            state.stopReason = StopReason(wireValue: reason)
        }
        var events: [StreamEvent] = []
        if !response.text.isEmpty {
            events.append(.text(response.text))
        }
        if !response.reasoning.isEmpty {
            events.append(.reasoning(response.reasoning))
        }
        for block in response.content ?? [] where block.type == "tool_use" {
            guard let name = block.name, !name.isEmpty else { continue }
            let arguments = block.input.flatMap { try? JSONCoding.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            events.append(.toolCall(id: block.id, name: name, arguments: arguments))
        }
        return events
    }
}
