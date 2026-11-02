import Foundation
import Testing
@testable import BUUKit

@Suite("SSE decoding")
struct SSEDecoderTests {

    @Test("Decodes a simple event")
    func decodesSimpleEvent() {
        var decoder = SSEDecoder()
        let events = decoder.decode(Data("data: hello\n\n".utf8))
        #expect(events.count == 1)
        #expect(events.first?.data == "hello")
        #expect(events.first?.name == nil)
    }

    @Test("Decodes an event with a name")
    func decodesEventWithName() {
        var decoder = SSEDecoder()
        let events = decoder.decode(Data("event: ping\ndata: {}\n\n".utf8))
        #expect(events.count == 1)
        #expect(events.first?.name == "ping")
        #expect(events.first?.data == "{}")
    }

    @Test("Keeps incomplete events until the separator arrives")
    func handlesPartialChunks() {
        var decoder = SSEDecoder()
        #expect(decoder.decode(Data("data: {\"a\"".utf8)).isEmpty)
        #expect(decoder.decode(Data(": 1}".utf8)).isEmpty)
        let events = decoder.decode(Data("\n\n".utf8))
        #expect(events.count == 1)
        #expect(events.first?.data == "{\"a\": 1}")
    }

    @Test("Handles CRLF line endings")
    func handlesCarriageReturnLineFeed() {
        var decoder = SSEDecoder()
        let events = decoder.decode(Data("data: one\r\n\r\ndata: two\r\n\r\n".utf8))
        #expect(events.map(\.data) == ["one", "two"])
    }

    @Test("Joins multiple data lines")
    func joinsMultipleDataLines() {
        var decoder = SSEDecoder()
        let events = decoder.decode(Data("data: a\ndata: b\n\n".utf8))
        #expect(events.first?.data == "a\nb")
    }

    @Test("Ignores comments")
    func ignoresComments() {
        var decoder = SSEDecoder()
        let events = decoder.decode(Data(": keep-alive\ndata: value\n\n".utf8))
        #expect(events.count == 1)
        #expect(events.first?.data == "value")
    }

    @Test("Flushes the remainder when the stream ends")
    func finishFlushesRemainingData() {
        var decoder = SSEDecoder()
        #expect(decoder.decode(Data("data: tail".utf8)).isEmpty)
        let events = decoder.finish()
        #expect(events.count == 1)
        #expect(events.first?.data == "tail")
    }

    @Test("Handles UTF-8 sequences split across chunks")
    func handlesUTF8SplitAcrossChunks() {
        var decoder = SSEDecoder()
        let bytes = Array("data: 👋\n\n".utf8)
        let head = Data(bytes[0..<8])
        let tail = Data(bytes[8...])
        #expect(decoder.decode(head).isEmpty)
        let events = decoder.decode(tail)
        #expect(events.count == 1)
        #expect(events.first?.data == "👋")
    }
}
