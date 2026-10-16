import Foundation
import SQLite3

enum NativeTimelineSQLValue {
    case text(String), integer(Int64), data(Data), null
}

/// Non-Sendable connection, created and exclusively owned by one NativeTimelineStore actor.
/// FULLMUTEX is defensive SQLite protection; the Swift statement cache relies on actor ownership.
/// Neither the connection nor a statement escapes that actor's synchronous operations.
final class NativeTimelineDatabase {
    private let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]
    private var closed = false

    init(path: String) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open private index"
            sqlite3_close(pointer)
            throw NativeTimelineError.message("Timeline SQLite: \(message)")
        }
        handle = pointer
        sqlite3_busy_timeout(pointer, 2_000)
        do {
            try execute("PRAGMA trusted_schema=OFF")
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA cache_size=-2048")
            try execute("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,device TEXT NOT NULL,inode TEXT NOT NULL,offset INTEGER NOT NULL,line INTEGER NOT NULL,pending_start INTEGER NOT NULL,digest TEXT NOT NULL,terminal_tail INTEGER NOT NULL,previous_cr INTEGER NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,generation INTEGER NOT NULL,id TEXT NOT NULL,timestamp TEXT NOT NULL,source TEXT NOT NULL,rank INTEGER NOT NULL,line INTEGER NOT NULL,kind TEXT NOT NULL,summary TEXT NOT NULL,raw_offset INTEGER NOT NULL,raw_length INTEGER NOT NULL,UNIQUE(generation,id))")
            try execute("CREATE INDEX IF NOT EXISTS chronological ON events(generation,timestamp,rank,line,id)")
            try execute("CREATE INDEX IF NOT EXISTS source_chronological ON events(generation,source,timestamp,rank,line,id)")
            try execute("CREATE INDEX IF NOT EXISTS ingress ON events(generation,sequence)")
            try execute("CREATE TABLE IF NOT EXISTS search_matches(query TEXT NOT NULL,generation INTEGER NOT NULL,sequence INTEGER NOT NULL,PRIMARY KEY(query,generation,sequence)) WITHOUT ROWID")
            try execute("CREATE TABLE IF NOT EXISTS search_progress(query TEXT PRIMARY KEY,generation INTEGER NOT NULL,sequence INTEGER NOT NULL,accessed INTEGER NOT NULL)")
            let generation = String(Int64((Date().timeIntervalSince1970 * 1_000_000).rounded()))
            try execute("INSERT OR IGNORE INTO metadata VALUES('generation',?)", [.text(generation)])
        } catch {
            for statement in statements.values { sqlite3_finalize(statement) }
            statements.removeAll()
            sqlite3_close(pointer)
            closed = true
            throw error
        }
    }

    deinit {
        if !closed {
            for statement in statements.values { sqlite3_finalize(statement) }
            sqlite3_close(handle)
        }
    }

    func withStatement<T>(_ sql: String, _ values: [NativeTimelineSQLValue] = [], _ body: (OpaquePointer) throws -> T) throws -> T {
        let statement: OpaquePointer
        let temporary: Bool
        if let existing = statements[sql], sqlite3_stmt_busy(existing) == 0 {
            statement = existing; temporary = false
        } else {
            var result: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
            statement = result
            temporary = statements[sql] != nil
            if !temporary { statements[sql] = statement }
        }
        defer {
            sqlite3_progress_handler(handle, 0, nil, nil)
            if temporary { sqlite3_finalize(statement) }
            else { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), status: Int32
            switch value {
            case .text(let text):
                guard text.utf8.count <= Int32.max else { throw NativeTimelineError.message("A timeline value exceeds SQLite's supported record size.") }
                status = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient) }
            case .integer(let number): status = sqlite3_bind_int64(statement, index, number)
            case .data(let data):
                guard data.count <= Int32.max else { throw NativeTimelineError.message("A timeline value exceeds SQLite's supported record size.") }
                status = data.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0)
                    : data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        // SQLite calls transaction control "read-only" too. Rollback/commit must remain
        // callable from a cancelled task so interrupted reads cannot poison the connection.
        let operation = sql.split(whereSeparator: \.isWhitespace).first.map { $0.uppercased() } ?? ""
        let readOnly = sqlite3_stmt_readonly(statement) != 0 && !["BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE"].contains(operation)
        if readOnly {
            try Task.checkCancellation()
            // Runs synchronously inside this actor task's sqlite3_step. Do not install this
            // on writes: cancellation must never prevent the enclosing transaction's rollback.
            sqlite3_progress_handler(handle, 10_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        }
        do {
            let result = try body(statement)
            if readOnly { try Task.checkCancellation() }
            return result
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func execute(_ sql: String, _ values: [NativeTimelineSQLValue] = []) throws {
        try withStatement(sql, values) { statement in
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW { code = sqlite3_step(statement) }
            guard code == SQLITE_DONE else { throw failure() }
        }
    }

    func scalar(_ sql: String, _ values: [NativeTimelineSQLValue] = []) throws -> Int64 {
        try withStatement(sql, values) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func text(_ sql: String, _ values: [NativeTimelineSQLValue] = []) throws -> String? {
        try withStatement(sql, values) { statement in
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw failure() }
            return Self.text(statement, 0)
        }
    }

    func failure() -> NativeTimelineError { .message("Timeline SQLite: \(String(cString: sqlite3_errmsg(handle)))") }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    static func data(_ statement: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}
