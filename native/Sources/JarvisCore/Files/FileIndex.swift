import Foundation

// D-51 P3, piece 5: memory/files-index.json, what the scanner knows about every document it
// has seen, so an unchanged file is never read twice. Written atomically under the lease.

/// One document in the index.
public struct FileIndexEntry: Sendable, Equatable {
    public enum Status: String, Sendable, CaseIterable {
        case read          // read for facts (possibly none)
        case empty         // no text once extracted and redacted
        case unreadable    // its text (or its bytes) could not be read
        case duplicate     // the same bytes as a document already read
        case waiting       // needs Claude, and that hour's reads were used: read later
        case failed        // a reader failed: tried again on the next pass

        /// Settled entries are not read again while the file stays the same.
        public var isSettled: Bool {
            switch self {
            case .read, .empty, .unreadable, .duplicate: true
            case .waiting, .failed: false
            }
        }
    }

    public var path: String
    public var size: Int
    public var mtime: Double       // epoch seconds
    public var digest: String      // SHA-256 of the bytes, lower-case hex; "" when unread
    public var status: Status
    public var facts: Int          // facts kept from it (new or refreshed)
    public var lastRead: Double    // epoch seconds of the last attempt

    public init(path: String, size: Int, mtime: Double, digest: String, status: Status, facts: Int = 0,
                lastRead: Double) {
        self.path = path
        self.size = size
        self.mtime = mtime
        self.digest = digest
        self.status = status
        self.facts = facts
        self.lastRead = lastRead
    }

    var json: JSONValue {
        .object(JSONObject([
            .init(key: "path", value: .string(path)),
            .init(key: "size", value: .int(Int64(size))),
            .init(key: "mtime", value: .double(mtime)),
            .init(key: "digest", value: .string(digest)),
            .init(key: "status", value: .string(status.rawValue)),
            .init(key: "facts", value: .int(Int64(facts))),
            .init(key: "last_read", value: .double(lastRead)),
        ]))
    }

    init?(json: JSONValue) {
        guard let o = json.objectValue,
              let path = o["path"]?.stringValue,
              case .int(let size)? = o["size"],
              let mtime = o["mtime"]?.pyFloat,
              let digest = o["digest"]?.stringValue,
              let status = o["status"]?.stringValue.flatMap(Status.init(rawValue:)),
              case .int(let facts)? = o["facts"],
              let lastRead = o["last_read"]?.pyFloat
        else { return nil }
        self.init(path: path, size: Int(size), mtime: mtime, digest: digest, status: status,
                  facts: Int(facts), lastRead: lastRead)
    }
}

/// The whole index, by path.
public struct FileIndex: Sendable, Equatable {
    public var entries: [String: FileIndexEntry]

    public init(entries: [FileIndexEntry] = []) {
        self.entries = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// `{"files": [...]}` in path order, indent 1, non-ASCII kept.
    public var data: Data {
        let files = entries.keys.sorted().compactMap { entries[$0]?.json }
        let object = JSONObject([.init(key: "files", value: .array(files))])
        return Data(PyJSON.dumps(.object(object), indent: 1, ensureASCII: false).utf8)
    }

    /// nil unless `data` is an index. An entry of the wrong shape is dropped.
    public init?(data: Data) {
        guard let value = try? PyJSON.loads(data), let files = value.objectValue?["files"]?.arrayValue
        else { return nil }
        self.init(entries: files.compactMap(FileIndexEntry.init(json:)))
    }
}

/// files-index.json through the lease-holding `StateStore`.
public final class FileIndexStore: Sendable {
    private let store: StateStore

    public init(store: StateStore) {
        self.store = store
    }

    /// The index: empty when there is none yet, nil when one exists and cannot be read.
    public func load() -> FileIndex? {
        guard let data = store.read(.filesIndex) else {
            return FileManager.default.fileExists(atPath: store.path(.filesIndex)) ? nil : FileIndex()
        }
        return FileIndex(data: data)
    }

    /// Saves atomically. False when the lease is not held or the write failed.
    @discardableResult
    public func save(_ index: FileIndex) -> Bool {
        store.write(index.data, to: .filesIndex)
    }
}
