import Foundation

/// Very small JSON-file based persistence layer.
public actor FileStore {
    public let rootURL: URL

    private let fileManager = FileManager.default

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.rootURL = base.appendingPathComponent("BUU", isDirectory: true)
        }
    }

    public var conversationsDirectory: URL {
        rootURL.appendingPathComponent("conversations", isDirectory: true)
    }

    public var attachmentsDirectory: URL {
        rootURL.appendingPathComponent("attachments", isDirectory: true)
    }

    public var settingsURL: URL {
        rootURL.appendingPathComponent("settings.json", isDirectory: false)
    }

    public func prepare() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Files

    public func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try write(encoder.encode(value), to: url)
    }

    public func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    public func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func removeItem(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    public func contentsOfDirectory(at url: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }
}
