import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The pieces of an HTTP response we care about.
public struct HTTPResponseHead: Sendable, Hashable {
    public var statusCode: Int
    public var headers: [String: String]

    public init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = headers
    }

    public var contentType: String {
        headers.first { $0.key.lowercased() == "content-type" }?.value ?? ""
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// A piece of a streamed HTTP response.
public enum HTTPChunk: Sendable {
    case head(HTTPResponseHead)
    case body(Data)
    case complete
}

public struct HTTPError: LocalizedError, Sendable {
    public var statusCode: Int
    public var body: String

    public init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    public var errorDescription: String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "HTTP \(statusCode)" }
        return "HTTP \(statusCode): \(trimmed.prefix(500))"
    }
}

/// Small portability wrapper around `URLSession`.
///
/// The streaming path uses a delegate instead of `URLSession.bytes(for:)` so the
/// exact same code compiles and behaves identically on Linux and macOS.
public enum HTTPTransport {

    /// Perform a request and wait for the whole body.
    public static func perform(_ request: URLRequest) async throws -> (Data, HTTPResponseHead) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let http = response as? HTTPURLResponse
                let head = HTTPResponseHead(statusCode: http?.statusCode ?? 0, headers: headers(of: http))
                continuation.resume(returning: (data ?? Data(), head))
            }
            task.resume()
        }
    }

    /// Perform a request and receive the response incrementally.
    public static func stream(_ request: URLRequest) -> AsyncThrowingStream<HTTPChunk, Error> {
        AsyncThrowingStream { continuation in
            let delegate = ResponseStreamDelegate(continuation: continuation)
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 300
            configuration.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            let task = session.dataTask(with: request)
            delegate.task = task
            continuation.onTermination = { @Sendable _ in delegate.cancel() }
            task.resume()
        }
    }

    static func headers(of response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key).lowercased()] = String(describing: value)
        }
        return result
    }
}

private final class ResponseStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<HTTPChunk, Error>.Continuation
    private let lock = NSLock()
    private var didSendHead = false
    private var didFinish = false

    var session: URLSession?
    var task: URLSessionTask?

    init(continuation: AsyncThrowingStream<HTTPChunk, Error>.Continuation) {
        self.continuation = continuation
        super.init()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let head = HTTPResponseHead(statusCode: http?.statusCode ?? 0, headers: HTTPTransport.headers(of: http))
        lock.lock()
        let alreadySent = didSendHead
        didSendHead = true
        lock.unlock()
        if !alreadySent {
            continuation.yield(.head(head))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        continuation.yield(.body(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let alreadyFinished = didFinish
        didFinish = true
        lock.unlock()
        guard !alreadyFinished else { return }

        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: error)
            }
        } else {
            continuation.yield(.complete)
            continuation.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
