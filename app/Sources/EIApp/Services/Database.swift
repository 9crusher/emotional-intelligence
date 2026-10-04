import Foundation
import SQLite3

/// Minimal wrapper over the SQLite C API. The database is owned by the Python side
/// (`src/ei/db.py` creates it and runs migrations); the app only reads, plus writes
/// rows to `settings` and `triggers`, which the daemon picks up via `PRAGMA data_version`.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

struct SQLRow {
    fileprivate var columns: [String: SQLValue]

    func int(_ key: String) -> Int64? {
        switch columns[key] {
        case .int(let v): v
        case .double(let v): Int64(v)
        default: nil
        }
    }

    func double(_ key: String) -> Double? {
        switch columns[key] {
        case .int(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    func string(_ key: String) -> String? {
        if case .text(let s) = columns[key] { return s }
        return nil
    }
}

struct DatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class Database {
    private var handle: OpaquePointer?

    /// Opens an existing database read-write. Does not create it: the daemon/CLI own creation
    /// and migrations.
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            handle = nil
            throw DatabaseError(message: message)
        }
        sqlite3_busy_timeout(handle, 2000)
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close(handle)
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            var columns: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: columns[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: columns[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: columns[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                default: columns[name] = .null
                }
            }
            rows.append(SQLRow(columns: columns))
        }
        return rows
    }

    @discardableResult
    func execute(_ sql: String, _ params: [SQLValue] = []) throws -> Int64 {
        _ = try query(sql, params)
        return sqlite3_last_insert_rowid(handle)
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    private func lastError() -> DatabaseError {
        DatabaseError(message: String(cString: sqlite3_errmsg(handle)))
    }
}
