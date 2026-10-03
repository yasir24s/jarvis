import Foundation
import JarvisCore
import SQLite3

/// One received message as `_recent_messages` reads it: the sender's handle (nil when the
/// handle row is missing) and the plain text.
struct MessageRow: Sendable, Equatable {
    let handle: String?
    let text: String
}

/// Messages' database, read only. `latest` throws on any SQLite failure (no Full Disk Access
/// looks like "unable to open database file").
protocol MessagesReading: Sendable {
    var databaseExists: Bool { get }
    func latest(_ n: Int) throws -> [MessageRow]
}

/// What a platform has before the app gives it the real database: none.
struct NoMessages: MessagesReading {
    var databaseExists: Bool { false }
    func latest(_ n: Int) throws -> [MessageRow] { [] }
}

/// `~/Library/Messages/chat.db` through the system SQLite, opened read only by URI as Python
/// does (`file:<path>?mode=ro`), with Python's query word for word. Needs Full Disk Access.
struct LiveMessages: MessagesReading {
    static let query = "SELECT h.id, m.text FROM message m LEFT JOIN handle h ON m.handle_id=h.ROWID "
        + "WHERE m.is_from_me=0 AND m.text IS NOT NULL AND length(m.text)>0 "
        + "ORDER BY m.date DESC LIMIT ?"
    struct Failure: Error, CustomStringConvertible { let description: String }

    let path: String

    init(home: String) { path = Py.rstrip(home, "/") + "/Library/Messages/chat.db" }
    init(path: String) { self.path = path }

    var databaseExists: Bool { FileManager.default.fileExists(atPath: path) }

    func latest(_ n: Int) throws -> [MessageRow] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw Failure(description: message)
        }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(description: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(n))
        var rows: [MessageRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
            rows.append(MessageRow(handle: Self.text(statement, 0), text: Self.text(statement, 1) ?? ""))
        }
        return rows
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let bytes = sqlite3_column_text(statement, column)
        else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }
}

/// `get_messages`, Python's `_recent_messages` (jarvis.py 2977-2996): the five latest received
/// texts. Untrusted (TaintPolicy), and the turn is tagged with messages and contacts.
struct GetMessages: ToolImpl {
    static let name = "get_messages"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let messages: any MessagesReading

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard messages.databaseExists else { return .text("I can't find your Messages database, sir.") }
        let rows: [MessageRow]
        do { rows = try messages.latest(5) } catch {
            return .text("I couldn't read Messages — please grant Full Disk Access, sir.")
        }
        if rows.isEmpty { return .text("No readable recent messages, sir.") }
        let parts = rows.map { row in
            let handle = row.handle.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            return "From \(handle): \(row.text)"
        }
        return .text("Your latest messages. " + parts.joined(separator: " ... "))
    }
}
