import Foundation

/// Shared JSON coders so encoding/decoding behaves the same everywhere.
public enum JSONCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    /// Human readable description of a decoding failure, useful when a server
    /// returns something that is not quite the documented shape.
    public static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        switch decodingError {
        case .keyNotFound(let key, _):
            return "missing key '\(key.stringValue)'"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(path(for: context))"
        case .valueNotFound(let type, let context):
            return "missing \(type) at \(path(for: context))"
        case .dataCorrupted(let context):
            return "corrupted payload: \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(for context: DecodingError.Context) -> String {
        let components = context.codingPath.map { key -> String in
            if let index = key.intValue { return "[\(index)]" }
            return key.stringValue
        }
        return components.joined(separator: ".")
    }
}
