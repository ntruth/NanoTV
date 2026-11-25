import Foundation
import SQLite3

enum SQLiteError: LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "无法打开数据库：\(message)"
        case .prepare(let message): return "SQL 准备失败：\(message)"
        case .step(let message): return "SQL 执行失败：\(message)"
        case .execute(let message): return "SQL 执行失败：\(message)"
        }
    }
}

enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var int64: Int64? {
        switch self {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        case .text(let value): return Int64(value)
        default: return nil
        }
    }

    var int: Int? {
        int64.map { Int($0) }
    }

    var double: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        case .text(let value): return Double(value)
        default: return nil
        }
    }

    var string: String? {
        switch self {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .blob(let data): return String(data: data, encoding: .utf8)
        case .null: return nil
        }
    }

    var data: Data? {
        if case .blob(let data) = self { return data }
        return nil
    }

    var bool: Bool {
        (int64 ?? 0) != 0
    }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    /// 系统 libsqlite3 以 THREADSAFE=2（multi-thread）编译：同一个连接禁止跨线程并发使用。
    /// 索引库会被主线程（计数、地点、侧边栏）和多个后台 Task 同时查询，
    /// 并发操作同一 handle 会写坏连接内部的 lookaside / 内存分配，
    /// 表现为 sqlite3RunParser 里的随机 SIGSEGV / SIGBUS。这里把所有入口串行化。
    private let lock = NSRecursiveLock()
    let path: String

    /// `wal` 只对可写库有效：索引是一次性构建、之后只读打开，
    /// 必须保持普通回滚日志模式，否则 WAL 旁路文件一旦没跟着主文件走，只读连接会全部查询失败。
    init(path: String, readonly: Bool, wal: Bool = true) throws {
        self.path = path
        let flags: Int32 = readonly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
            throw SQLiteError.open(message)
        }
        sqlite3_busy_timeout(handle, 3000)
        if !readonly {
            if wal { try execute("PRAGMA journal_mode=WAL;") }
            try execute("PRAGMA synchronous=NORMAL;")
        } else {
            // 只读库：加大页缓存并启用 mmap，减少大图库（几十 GB）扫描时的随机磁盘读取。
            sqlite3_exec(handle,
                         "PRAGMA cache_size=-131072; PRAGMA temp_store=MEMORY; PRAGMA mmap_size=536870912;",
                         nil, nil, nil)
        }
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    func execute(_ sql: String, _ binds: [Any?] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, binds)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func query(_ sql: String, _ binds: [Any?] = []) throws -> [[String: SQLiteValue]] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, binds)
        defer { sqlite3_finalize(statement) }

        let columnCount = sqlite3_column_count(statement)
        var names: [String] = []
        names.reserveCapacity(Int(columnCount))
        for index in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(statement, index)))
        }

        var rows: [[String: SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)))
            }
            var row: [String: SQLiteValue] = [:]
            row.reserveCapacity(Int(columnCount))
            for index in 0..<columnCount {
                row[names[Int(index)]] = value(statement: statement, column: index)
            }
            rows.append(row)
        }
        return rows
    }

    /// 批量执行同一条 INSERT：只准备一次语句，逐行绑定后重置。
    /// 百万级索引写入时，反复 prepare 会成为主要开销。
    func executeMany(_ sql: String, rows: [[Any?]]) throws {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            for (index, bind) in row.enumerated() {
                bindValue(bind, at: Int32(index + 1), statement: statement)
            }
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func transaction(_ block: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            try block()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// 逐行读取，避免一次性把所有行物化成字典（大图库可省下大量内存）。
    func forEachRow(_ sql: String, _ binds: [Any?] = [],
                    _ body: ([String: SQLiteValue]) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, binds)
        defer { sqlite3_finalize(statement) }

        let columnCount = sqlite3_column_count(statement)
        var names: [String] = []
        names.reserveCapacity(Int(columnCount))
        for index in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(statement, index)))
        }

        var row: [String: SQLiteValue] = [:]
        row.reserveCapacity(Int(columnCount))
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)))
            }
            row.removeAll(keepingCapacity: true)
            for index in 0..<columnCount {
                row[names[Int(index)]] = value(statement: statement, column: index)
            }
            try body(row)
        }
    }

    private func prepare(_ sql: String, _ binds: [Any?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw SQLiteError.prepare(message)
        }

        for (index, bind) in binds.enumerated() {
            bindValue(bind, at: Int32(index + 1), statement: statement)
        }
        return statement
    }

    private func bindValue(_ bind: Any?, at position: Int32, statement: OpaquePointer) {
        switch bind {
        case nil:
            sqlite3_bind_null(statement, position)
        case let value as Bool:
            sqlite3_bind_int(statement, position, value ? 1 : 0)
        case let value as String:
            sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
        case let value as Int:
            sqlite3_bind_int64(statement, position, Int64(value))
        case let value as Int64:
            sqlite3_bind_int64(statement, position, value)
        case let value as Double:
            sqlite3_bind_double(statement, position, value)
        case let value as Data:
            _ = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
            }
        default:
            sqlite3_bind_text(statement, position, String(describing: bind!), -1, SQLITE_TRANSIENT)
        }
    }

    private func value(statement: OpaquePointer, column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            if let text = sqlite3_column_text(statement, column) {
                return .text(String(cString: text))
            }
            return .null
        case SQLITE_BLOB:
            let length = sqlite3_column_bytes(statement, column)
            if length > 0, let bytes = sqlite3_column_blob(statement, column) {
                return .blob(Data(bytes: bytes, count: Int(length)))
            }
            return .blob(Data())
        default:
            return .null
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
