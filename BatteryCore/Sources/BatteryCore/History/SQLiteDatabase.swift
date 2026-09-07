import Foundation
import SQLite3

/// `sqlite3_bind_*` destructor telling SQLite to copy the buffer it was handed.
/// The constant is a macro in `sqlite3.h`, so it does not import into Swift.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Anything the C API can hand back that we care to report.
public struct SQLiteError: Error, CustomStringConvertible, Equatable {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        var text = "sqlite error \(code): \(message)"
        if let sql { text += " [\(sql)]" }
        return text
    }
}

/// A minimal wrapper over one `sqlite3*` handle.
///
/// Deliberately tiny and deliberately *not* `Sendable`: it is owned by
/// `HistoryStore`, an actor, and never escapes it. The whole point of using the
/// system SQLite is that the widget extension can link this with no third-party
/// dependency at all (NOTES.md §15).
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    let url: URL

    init(url: URL) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.path)"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: code, message: message, sql: nil)
        }
        self.handle = handle
        // A second process (the app while `tandemctl history` runs, say) may hold
        // the write lock for a moment; wait rather than fail.
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    var errorMessage: String {
        guard let handle else { return "closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed", sql: sql) }
        var raw: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &raw)
        if code != SQLITE_OK {
            let message = raw.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(raw)
            throw SQLiteError(code: code, message: message, sql: sql)
        }
        sqlite3_free(raw)
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed", sql: sql) }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SQLiteError(code: code, message: errorMessage, sql: sql)
        }
        return SQLiteStatement(statement: statement, database: self, sql: sql)
    }

    /// Run `body` inside `BEGIN IMMEDIATE` / `COMMIT`, rolling back on any throw.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// The single scalar of a one-column query, as text. Used for `PRAGMA`s.
    func scalarText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        guard try statement.step() else { return nil }
        return statement.string(0)
    }
}

/// One prepared statement. `finalize()` is idempotent and also runs on `deinit`.
final class SQLiteStatement {
    private var statement: OpaquePointer?
    private let database: SQLiteDatabase
    private let sql: String

    init(statement: OpaquePointer, database: SQLiteDatabase, sql: String) {
        self.statement = statement
        self.database = database
        self.sql = sql
    }

    deinit { finalize() }

    func finalize() {
        if let statement { sqlite3_finalize(statement) }
        statement = nil
    }

    /// `true` when a row is available, `false` at the end of the result set.
    @discardableResult
    func step() throws -> Bool {
        guard let statement else { throw SQLiteError(code: SQLITE_MISUSE, message: "finalized", sql: sql) }
        let code = sqlite3_step(statement)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: code, message: database.errorMessage, sql: sql)
        }
    }

    func reset() {
        guard let statement else { return }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    // MARK: - Binding (1-based, as SQLite counts)

    func bind(_ index: Int32, _ value: Double) { sqlite3_bind_double(statement, index, value) }
    func bind(_ index: Int32, _ value: Int) { sqlite3_bind_int64(statement, index, Int64(value)) }
    func bind(_ index: Int32, _ value: Bool) { sqlite3_bind_int(statement, index, value ? 1 : 0) }

    func bind(_ index: Int32, _ value: Double?) {
        if let value { bind(index, value) } else { sqlite3_bind_null(statement, index) }
    }

    func bind(_ index: Int32, _ value: Int?) {
        if let value { bind(index, value) } else { sqlite3_bind_null(statement, index) }
    }

    func bind(_ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    // MARK: - Reading (0-based, as SQLite counts)

    private func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    func bool(_ index: Int32) -> Bool { sqlite3_column_int(statement, index) != 0 }

    func optionalDouble(_ index: Int32) -> Double? { isNull(index) ? nil : double(index) }
    func optionalInt(_ index: Int32) -> Int? { isNull(index) ? nil : int(index) }

    func string(_ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }
}
