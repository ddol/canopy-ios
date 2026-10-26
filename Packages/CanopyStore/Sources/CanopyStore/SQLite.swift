import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, Equatable {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

/// A thin wrapper over one connection to the system SQLite library. Not thread-safe: own it from one actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Opens (creating if needed) the database at `path`, or an in-memory database for ":memory:".
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let error = SQLiteError(code: result, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open")
            sqlite3_close(handle)
            throw error
        }
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var userVersion: Int {
        get throws { try query("PRAGMA user_version") { $0.int(0) }.first ?? 0 }
    }

    /// Runs one or more statements that return no rows.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(error)
            throw SQLiteError(code: result, message: message)
        }
    }

    /// Runs one statement with bound values.
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure(result) }
    }

    /// Runs a query and maps each row.
    func query<T>(_ sql: String, _ values: [SQLiteValue] = [], row: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure(result) }
            rows.append(try row(Row(statement: statement)))
        }
        return rows
    }

    /// Runs `body` in a transaction, rolling back if it throws.
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

    private func prepare(_ sql: String, _ values: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw failure(result) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32 =
                switch value {
                case .null: sqlite3_bind_null(statement, index)
                case .integer(let int): sqlite3_bind_int64(statement, index, int)
                case .real(let double): sqlite3_bind_double(statement, index, double)
                case .text(let text): sqlite3_bind_text(statement, index, text, -1, SQLiteDatabase.transient)
                }
            guard bound == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw failure(bound)
            }
        }
        return statement
    }

    private var lastMessage: String { String(cString: sqlite3_errmsg(handle)) }

    private func failure(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: lastMessage)
    }

    /// Tells SQLite to copy bound text before `sqlite3_bind_text` returns.
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    struct Row {
        let statement: OpaquePointer?

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func string(_ column: Int32) -> String { text(column) ?? "" }

        var columnCount: Int { Int(sqlite3_column_count(statement)) }
    }
}

enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    static func int(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }

    static func optional(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
}
