import Foundation
import Testing
@testable import BUUKit

@Suite("Artifact transfer")
struct ArtifactTransferTests {

    @Test("SHA-256 matches known vectors")
    func shaVectors() {
        var empty = SHA256()
        #expect(empty.finalize() == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        var abc = SHA256()
        abc.update(Data("abc".utf8))
        #expect(abc.finalize() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        var split = SHA256()
        split.update(Data("a".utf8))
        split.update(Data("bc".utf8))
        #expect(split.finalize() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Streaming file hash matches in-memory hash")
    func fileHash() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("buu-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.txt")
        let data = Data(repeating: 0x5a, count: 200_000)
        try data.write(to: url)

        var inline = SHA256()
        inline.update(data)
        #expect(try SHA256.hash(contentsOf: url, chunkSize: 4096) == inline.finalize())
    }

    @Test("Reconciliation re-copies missing, failed, changed and recreated files")
    func reconciliation() {
        let artifact = TaskArtifact(
            name: "report.pdf",
            fileName: "report.pdf",
            byteCount: 100,
            guestState: .inGuest,
            guestModifiedAt: Date(timeIntervalSince1970: 100)
        )
        #expect(!ArtifactReconciliation.needsUpload(artifact, guestSize: 100, guestModified: Date(timeIntervalSince1970: 100)))
        #expect(ArtifactReconciliation.needsUpload(artifact, guestSize: 99, guestModified: Date(timeIntervalSince1970: 100)))
        #expect(ArtifactReconciliation.needsUpload(artifact, guestSize: 100, guestModified: Date(timeIntervalSince1970: 200)))

        var queued = artifact
        queued.guestState = .queued
        #expect(ArtifactReconciliation.needsUpload(queued, guestSize: 100, guestModified: Date(timeIntervalSince1970: 100)))

        var failed = artifact
        failed.guestState = .failed
        #expect(ArtifactReconciliation.needsUpload(failed, guestSize: 100, guestModified: Date(timeIntervalSince1970: 100)))
    }

    @Test("Artifact metadata round-trips guest sync state")
    func metadataRoundTrip() throws {
        let artifact = TaskArtifact(
            name: "report.pdf",
            fileName: "report.pdf",
            byteCount: 42,
            sha256: String(repeating: "a", count: 64),
            guestName: "report-2.pdf",
            guestPath: "/Users/buu/Desktop/BUU Artifacts/report-2.pdf",
            guestState: .inGuest,
            guestByteCount: 42
        )
        let data = try JSONCoding.encode(artifact)
        let decoded = try JSONCoding.decode(TaskArtifact.self, from: data)
        #expect(decoded.guestState == .inGuest)
        #expect(decoded.guestPath == artifact.guestPath)
        #expect(decoded.guestName == "report-2.pdf")
    }
}
