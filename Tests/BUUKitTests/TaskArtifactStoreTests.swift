import Foundation
import Testing
@testable import BUUKit

@Suite("Task artifacts")
struct TaskArtifactStoreTests {

    private func makeStore() -> (TaskArtifactStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("buu-artifacts-\(UUID().uuidString)")
        return (TaskArtifactStore(rootURL: root), root)
    }

    @Test("Files are copied into a task-scoped folder")
    func copyIntoTaskFolder() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()
        let source = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source)

        let artifact = try store.copy(url: source, taskID: taskID)
        #expect(artifact.name == "source.txt")
        #expect(artifact.byteCount == 5)
        #expect(FileManager.default.fileExists(atPath: store.url(for: artifact, taskID: taskID).path))
        #expect(try store.read(artifact, taskID: taskID) == Data("hello".utf8))
        #expect(store.contents(for: taskID).map(\.lastPathComponent) == ["source.txt"])
    }

    @Test("Duplicate names are made unique")
    func duplicateNamesAreUnique() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()
        let source = root.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: source)

        let first = try store.copy(url: source, taskID: taskID)
        let second = try store.copy(url: source, taskID: taskID)
        #expect(first.fileName == "notes.md")
        #expect(second.fileName == "notes-2.md")
    }

    @Test("The model can write and read text artifacts")
    func writeAndRead() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()

        let artifact = try store.write(data: Data("result".utf8), name: "report.txt", taskID: taskID)
        #expect(artifact.name == "report.txt")
        #expect(try store.read(artifact, taskID: taskID) == Data("result".utf8))
        #expect(store.contents(for: taskID).count == 1)
    }

    @Test("Artifact names cannot escape the task folder")
    func namesAreContained() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()

        let artifact = try store.write(data: Data("x".utf8), name: "../../escape.txt", taskID: taskID)
        #expect(artifact.fileName == "escape.txt")
        #expect(store.url(for: artifact, taskID: taskID).deletingLastPathComponent().standardizedFileURL
            == store.directory(for: taskID).standardizedFileURL)
    }

    @Test("Directories are rejected")
    func directoriesRejected() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(throws: TaskArtifactError.self) {
            _ = try store.copy(url: directory, taskID: UUID())
        }
    }
}
