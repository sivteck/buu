import Foundation

/// A small JSON value used for tool schemas and parsed tool arguments. Keeping
/// this in the neutral model avoids provider specific dictionaries leaking into
/// the app target.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A tool call requested by the model. `id` is what the matching tool result
/// must reference in the next request.
public struct ToolCall: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The raw JSON object the model produced, before validation.
    public var arguments: String

    public init(id: String = "call_\(UUID().uuidString)", name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var parsedArguments: JSONValue? {
        guard let data = arguments.data(using: .utf8), !arguments.isEmpty else { return nil }
        return try? JSONCoding.decode(JSONValue.self, from: data)
    }
}

/// A function the model may call.
public struct ToolDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}
