import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

// D-51 P3, piece 5: memory/files-index.json's shape, its round trip, and the lease.

private func entry(_ path: String, _ status: FileIndexEntry.Status = .read) -> FileIndexEntry {
    FileIndexEntry(path: path, size: 26, mtime: 1790582400.123456, digest: String(repeating: "c0", count: 32),
                   status: status, facts: 2, lastRead: 1790582500.5)
}

@Suite("Files index (D-51 P3)")
struct FileIndexTests {
    @Test func theIndexRoundTripsInPathOrder() throws {
        let index = FileIndex(entries: [entry("/home/b.md"), entry("/home/a é.txt", .waiting)])
        let text = try #require(String(data: index.data, encoding: .utf8))
        #expect(text.hasPrefix("{\n \"files\": [\n  {\n   \"path\": \"/home/a é.txt\""))
        #expect(text.contains("\"mtime\": 1790582400.123456") && text.contains("\"last_read\": 1790582500.5"))
        #expect(text.contains("\"status\": \"waiting\"") && text.contains("\"facts\": 2"))
        #expect(FileIndex(data: index.data) == index)
    }

    @Test func aBadEntryIsDroppedAndABadFileIsNotAnIndex() {
        let data = Data(#"{"files": [{"path": "/x", "size": "big"}, {"path": "/y", "size": 1, "mtime": 2, "digest": "", "status": "read", "facts": 0, "last_read": 3}]}"#.utf8)
        #expect(FileIndex(data: data)?.entries.keys.sorted() == ["/y"])
        #expect(FileIndex(data: Data("[1, 2]".utf8)) == nil)
        #expect(FileIndex(data: Data("{\"files\": [".utf8)) == nil)
    }

    @Test func settledStatusesAreNotReadAgain() {
        #expect(FileIndexEntry.Status.allCases.filter(\.isSettled) == [.read, .empty, .unreadable, .duplicate])
    }

    @Test func theStoreLoadsSavesAndRefusesWithoutTheLease() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let root = sb.root.path(percentEncoded: false)
        let store = FileIndexStore(store: try StateStore(root: root, lease: nil))
        #expect(store.load() == FileIndex())                                  // none yet
        let index = FileIndex(entries: [entry("/home/b.md")])
        #expect(store.save(index))
        #expect(store.load() == index)
        #expect(sb.paths.memoryFilesIndex.path(percentEncoded: false).hasSuffix("/memory/files-index.json"))
        try Data("{\"files\": [".utf8).write(to: sb.paths.memoryFilesIndex)
        #expect(store.load() == nil)                                           // damaged

        let other = try Sandbox()
        defer { other.remove() }
        let lease = HandLease(false)
        let refused = FileIndexStore(store: try StateStore(root: other.root.path(percentEncoded: false), lease: lease))
        #expect(!refused.save(index))
        #expect(!FileManager.default.fileExists(atPath: other.root.path(percentEncoded: false) + "/memory"))
        lease.set(true)
        #expect(refused.save(index))
    }
}
