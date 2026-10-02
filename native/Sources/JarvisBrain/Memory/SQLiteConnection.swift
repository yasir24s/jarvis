import Foundation
import SQLite3

/// W1: one connection to an SQLite database through the system `SQLite3` module, for the memory
/// index and the web memory (`memory/web/index.sqlite`). Not thread-safe on its own: its owner
/// uses it under a lock. Errors are reported as SQLite's message, which never holds row data.
final class SQLiteConnection: @unchecked Sendable {
    private let handle: OpaquePointer

    /// Opens (creating) the database at `path`, the file 0600.
    static func open(_ path: String) throws(SQLiteError) -> SQLiteConnection {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(message)
        }
        sqlite3_busy_timeout(db, 2_000)
        chmod(path, 0o600)
        return SQLiteConnection(handle: db)
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var lastError: SQLiteError { SQLiteError(String(cString: sqlite3_errmsg(handle))) }

    /// Runs one or more statements that return no rows.
    func exec(_ sql: String) throws(SQLiteError) {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError }
    }

    func prepare(_ sql: String) throws(SQLiteError) -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError
        }
        return SQLiteStatement(statement, connection: self)
    }

    /// `body` inside BEGIN IMMEDIATE ... COMMIT; rolled back when it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }
}

struct SQLiteError: Error, Sendable, Equatable, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// A prepared statement. Bind with 1-based indexes; read columns with 0-based ones.
final class SQLiteStatement {
    private let statement: OpaquePointer
    private let connection: SQLiteConnection
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate init(_ statement: OpaquePointer, connection: SQLiteConnection) {
        self.statement = statement
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(statement)
    }

    @discardableResult
    func bind(_ values: SQLiteValue...) -> SQLiteStatement {
        bind(values)
    }

    @discardableResult
    func bind(_ values: [SQLiteValue]) -> SQLiteStatement {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (k, value) in values.enumerated() {
            let i = Int32(k + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, i)
            case .int(let v): sqlite3_bind_int64(statement, i, v)
            case .double(let v): sqlite3_bind_double(statement, i, v)
            case .text(let v): sqlite3_bind_text(statement, i, v, -1, Self.transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(statement, i, raw.baseAddress, Int32(raw.count), Self.transient)
                }
            }
        }
        return self
    }

    /// One step: true for a row, false when done.
    func step() throws(SQLiteError) -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw connection.lastError
        }
    }

    /// Steps to the end, for a statement that returns no rows.
    func run() throws(SQLiteError) {
        while try step() {}
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    func text(_ column: Int32) -> String {
        guard let c = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: c)
    }

    func blob(_ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}
