import Foundation
import SQLite3

/// 基于系统原生 SQLite3 的轻量级并发安全持久化引擎（兼容 macOS & tvOS，可直接打包快照同步至 WebDAV）
public actor NanoDatabaseStore {
    public static let shared = NanoDatabaseStore()

    public let databaseFileURL: URL
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(customURL: URL? = nil) {
        if let customURL {
            self.databaseFileURL = customURL
        } else {
            let baseDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("NanoAppStore", isDirectory: true)
            try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            self.databaseFileURL = baseDir.appendingPathComponent("nano_library_v1.sqlite")
        }
        Task {
            await openAndMigrateIfNeeded()
        }
    }

    private func openAndMigrateIfNeeded() {
        guard db == nil else { return }
        if sqlite3_open(databaseFileURL.path, &db) == SQLITE_OK {
            let createTableSQL = """
            CREATE TABLE IF NOT EXISTS kv_entity_store (
                namespace TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                updated_at REAL NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (namespace, entity_id)
            );
            CREATE INDEX IF NOT EXISTS idx_kv_ns_updated ON kv_entity_store(namespace, updated_at DESC);
            """
            sqlite3_exec(db, createTableSQL, nil, nil, nil)
        }
    }

    public func upsert<T: Codable & Sendable>(namespace: String, id: String, value: T) throws {
        openAndMigrateIfNeeded()
        guard let db else { return }
        let data = try encoder.encode(value)
        let sql = "INSERT OR REPLACE INTO kv_entity_store (namespace, entity_id, updated_at, payload) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (namespace as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        data.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, 4, rawBuffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
    }

    public func fetchAll<T: Codable & Sendable>(namespace: String, as type: T.Type) -> [T] {
        openAndMigrateIfNeeded()
        guard let db else { return [] }
        let sql = "SELECT payload FROM kv_entity_store WHERE namespace = ? ORDER BY updated_at DESC;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (namespace as NSString).utf8String, -1, SQLITE_TRANSIENT)

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bytesLength = Int(sqlite3_column_bytes(stmt, 0))
            if bytesLength > 0, let rawPtr = sqlite3_column_blob(stmt, 0) {
                let data = Data(bytes: rawPtr, count: bytesLength)
                if let decoded = try? decoder.decode(T.self, from: data) {
                    results.append(decoded)
                }
            }
        }
        return results
    }

    public func delete(namespace: String, id: String) {
        openAndMigrateIfNeeded()
        guard let db else { return }
        let sql = "DELETE FROM kv_entity_store WHERE namespace = ? AND entity_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (namespace as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// 导出完整快照字节流（用于加密同步至 WebDAV）
    public func exportDatabaseSnapshot() throws -> Data {
        openAndMigrateIfNeeded()
        if let db {
            sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
        }
        return try Data(contentsOf: databaseFileURL)
    }

    /// 从 WebDAV 快照恢复本地数据库
    public func restoreDatabaseSnapshot(_ data: Data) throws {
        if let currentDB = db {
            sqlite3_close(currentDB)
            self.db = nil
        }
        try data.write(to: databaseFileURL, options: .atomic)
        openAndMigrateIfNeeded()
    }
}
