import Foundation

/// A single server-sent event.
public struct SSEEvent: Sendable, Hashable {
    public var name: String?
    public var data: String
    public var id: String?

    public init(name: String? = nil, data: String = "", id: String? = nil) {
        self.name = name
        self.data = data
        self.id = id
    }
}

/// Incremental `text/event-stream` parser.
///
/// Feed it raw bytes with ``decode(_:)``; it returns the events that became
/// complete. Byte oriented so UTF-8 sequences split across chunk boundaries are
/// handled correctly (the delimiters we look for are ASCII and can never appear
/// inside a multi byte sequence).
public struct SSEDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func decode(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []
        while let separator = Self.findSeparator(in: buffer) {
            let block = buffer.prefix(separator.contentEnd)
            buffer.removeFirst(separator.contentEnd + separator.separatorLength)
            if let event = Self.parse(block) {
                events.append(event)
            }
        }
        return events
    }

    /// Flush whatever is left in the buffer (used when the stream ends without a trailing blank line).
    public mutating func finish() -> [SSEEvent] {
        guard !buffer.isEmpty else { return [] }
        let block = buffer
        buffer.removeAll(keepingCapacity: true)
        return Self.parse(block).map { [$0] } ?? []
    }

    private struct Separator {
        var contentEnd: Int
        var separatorLength: Int
    }

    private static func findSeparator(in data: Data) -> Separator? {
        let bytes = [UInt8](data)
        var best: Separator?
        for index in 0..<bytes.count {
            // "\n\n"
            if bytes[index] == 0x0A, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                let candidate = Separator(contentEnd: index, separatorLength: 2)
                if best == nil || candidate.contentEnd < best!.contentEnd { best = candidate }
                continue
            }
            // "\r\n\r\n"
            if bytes[index] == 0x0D, index + 3 < bytes.count,
               bytes[index + 1] == 0x0A, bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                let candidate = Separator(contentEnd: index, separatorLength: 4)
                if best == nil || candidate.contentEnd < best!.contentEnd { best = candidate }
                continue
            }
            // "\r\r"
            if bytes[index] == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0D {
                let candidate = Separator(contentEnd: index, separatorLength: 2)
                if best == nil || candidate.contentEnd < best!.contentEnd { best = candidate }
                continue
            }
        }
        return best
    }

    private static func parse(_ block: Data) -> SSEEvent? {
        guard !block.isEmpty else { return nil }
        let text = String(decoding: block, as: UTF8.self)
        var name: String?
        var id: String?
        var dataLines: [String] = []

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            if line.hasPrefix(":") { continue } // comment / keep-alive
            guard let colon = line.firstIndex(of: ":") else {
                // A field name without a colon is treated as a field with an empty value.
                continue
            }
            let field = String(line[line.startIndex..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "event": name = value
            case "data": dataLines.append(value)
            case "id": id = value
            default: break
            }
        }

        guard !dataLines.isEmpty || name != nil else { return nil }
        return SSEEvent(name: name, data: dataLines.joined(separator: "\n"), id: id)
    }
}
