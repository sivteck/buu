import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A tiny single-shot HTTP server used by the integration tests.
///
/// It accepts one connection, reads the request (headers + body) and answers
/// with a canned response.
final class MockHTTPServer: @unchecked Sendable {

    enum ServerError: Error {
        case socketFailed(String)
        case bindFailed(String)
    }

    struct ReceivedRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: String
    }

    private let listenDescriptor: Int32
    private var thread: Thread?
    private let lock = NSLock()
    private var received: [ReceivedRequest] = []

    let port: UInt16
    let responseDelay: TimeInterval

    /// - Parameters:
    ///   - contentType: value of the `Content-Type` response header.
    ///   - body: the raw response body.
    ///   - status: the HTTP status line code.
    ///   - responseDelay: wait this long after reading the request before answering.
    ///     Used to exercise cancellation of long-poll requests.
    init(contentType: String, body: String, status: Int = 200, responseDelay: TimeInterval = 0) throws {
        var port: UInt16 = 0
        listenDescriptor = try Self.bindLoopback(port: &port)
        self.port = port
        self.responseDelay = responseDelay

        let payload = body
        let header = """
        HTTP/1.1 \(status) OK\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r

        """
        let response = Data((header + payload).utf8)

        let thread = Thread { [weak self] in
            self?.serve(response: response)
        }
        thread.stackSize = 512 * 1024
        self.thread = thread
    }

    func start() {
        thread?.start()
    }

    func stop() {
        if listenDescriptor >= 0 {
            close(listenDescriptor)
        }
    }

    var requests: [ReceivedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    // MARK: - Serving

    private func serve(response: Data) {
        let client = accept(listenDescriptor, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var data = Data()

        // Read the header.
        while true {
            let readCount = read(client, &buffer, buffer.count)
            guard readCount > 0 else { return }
            data.append(contentsOf: buffer[0..<readCount])
            if let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = data[..<headerEnd.lowerBound]
                let headerText = String(decoding: headerData, as: UTF8.self)
                var lines = headerText.components(separatedBy: "\r\n")
                let requestLine = lines.removeFirst()
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    headers[name.lowercased()] = value
                }
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                var bodyData = Data(data[headerEnd.upperBound...])
                while bodyData.count < contentLength {
                    let more = read(client, &buffer, buffer.count)
                    guard more > 0 else { break }
                    bodyData.append(contentsOf: buffer[0..<more])
                }
                let parts = requestLine.split(separator: " ")
                let method = parts.count > 0 ? String(parts[0]) : ""
                let path = parts.count > 1 ? String(parts[1]) : ""
                let request = ReceivedRequest(
                    method: method,
                    path: path,
                    headers: headers,
                    body: String(decoding: bodyData, as: UTF8.self)
                )
                lock.lock()
                received.append(request)
                lock.unlock()
                break
            }
        }

        if responseDelay > 0 {
            Thread.sleep(forTimeInterval: responseDelay)
        }

        // Send the response in two chunks so the client has to stitch them.
        let half = response.count / 2
        if half > 0 {
            response.withUnsafeBytes { raw in
                _ = write(client, raw.baseAddress, half)
            }
        }
        response.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(client, base.advanced(by: half), response.count - half)
        }
    }

    // MARK: - Socket helpers

    private static func bindLoopback(port: inout UInt16) throws -> Int32 {
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let descriptor = socket(AF_INET, streamType, 0)
        guard descriptor >= 0 else { throw ServerError.socketFailed("socket() failed") }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(descriptor)
            throw ServerError.bindFailed("bind() failed")
        }

        guard listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw ServerError.bindFailed("listen() failed")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard nameResult == 0 else {
            close(descriptor)
            throw ServerError.bindFailed("getsockname() failed")
        }
        port = UInt16(bigEndian: bound.sin_port)
        return descriptor
    }
}
