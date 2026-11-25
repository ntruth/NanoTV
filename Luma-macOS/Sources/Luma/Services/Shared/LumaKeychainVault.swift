import Foundation
import Security

/// 全应用唯一的凭据保险库：网盘、影院、智能助手、未来的电视源都写进**一个**钥匙串条目。
///
/// 授权策略：
/// - 保险库条目只在首次写入时设置 ACL（信任当前 App 签名），之后同一签名重新编译不再弹框；
/// - 条目读取在每个进程内只发生一次，结果常驻内存；
/// - 旧版分散条目（cloud / cinema / ai / oauth / webdav）只读取一次，读取结果记录在保险库元数据里，
///   之后无论成功、失败还是用户拒绝都不再访问钥匙串，避免每次启动重复弹授权；
/// - 所有 Security.framework 调用都收口在 `KeychainAccess`。
///
/// 数据只存在内存与钥匙串，不落图库数据库、不写 UserDefaults、不打日志。
enum LumaKeychainVault {
    private static let service = "com.baymax.luma.credentials"
    private static let account = "vault"

    private static let legacyCloudService = "com.baymax.photosclone.cloudvault"
    private static let legacyCinemaService = "com.baymax.luma.cinema"

    /// 保险库内部元数据键，统一以 `__` 开头，业务键不会与之冲突。
    private static let legacyVaultsMarkerKey = "__meta.legacyVaultsMigrated.v2"
    /// 旧条目「已读过」标记。升级到 v2 是为了让历史上因钥匙串搜索列表损坏而记下的失败尝试失效，重试一次。
    private static let legacyAttemptPrefix = "__legacy2."
    /// 用户明确放弃迁移（重新保存 / 删除凭据）的标记，跨版本稳定。
    private static let legacyBlockedPrefix = "__blocked."

    private static let lock = NSLock()
    private static var cache: [String: Data]?
    private static var didAttemptLegacyMigration = false
    /// 保险库读不出来（用户拒绝授权）时不再写回，避免用空表覆盖掉原有凭据。
    private static var loadFailed = false
    /// 首次读取返回「不存在」。真正写入前会再确认一次，防止钥匙串搜索列表异常时
    /// 把「读不到」误判成「没有」，用单条数据覆盖掉原有凭据。
    private static var loadedFromMissing = false

    // MARK: - 读写

    static func data(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storageLocked()[key]
    }

    static func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ key: String) -> Bool {
        data(for: key) != nil
    }

    /// 写入并返回是否真正落盘。调用方（如旧明文迁移）必须用返回值决定能否删除旧数据。
    @discardableResult
    static func set(_ data: Data?, for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var map = storageLocked()
        if let data {
            map[key] = data
        } else {
            guard map.removeValue(forKey: key) != nil else { return true }
        }
        return persistLocked(map)
    }

    @discardableResult
    static func remove(_ key: String) -> Bool {
        set(nil, for: key)
    }

    // MARK: - 旧条目一次性迁移

    enum LegacyReadResult {
        case data(Data)
        case missing
        case denied(OSStatus)
    }

    /// 读取旧版钥匙串条目并迁入统一保险库。
    ///
    /// - 每个 `vaultKey` 只会真正访问一次钥匙串：首次结果（含「没有」与「用户拒绝」）
    ///   都会记录在保险库元数据里，之后直接返回 `.missing`，不再弹授权框；
    /// - 屏幕锁定等临时不可交互不记录，等用户解锁后再试一次；
    /// - 依次尝试 `services`，第一个有数据的条目生效。
    static func migrateLegacy(vaultKey: String, services: [String], account: String) -> LegacyReadResult {
        lock.lock()
        defer { lock.unlock() }
        var map = storageLocked()
        let attemptKey = legacyAttemptKey(vaultKey)
        if map[attemptKey] != nil || map[legacyBlockedPrefix + vaultKey] != nil { return .missing }

        for service in services {
            switch KeychainAccess.read(KeychainAccess.Item(service: service, account: account)) {
            case .data(let data):
                map[vaultKey] = data
                map[attemptKey] = Data()
                persistLocked(map)
                return .data(data)
            case .missing:
                continue
            case .denied(let status):
                if KeychainAccess.isTemporarilyUnavailable(status) { return .denied(status) }
                map[attemptKey] = Data()
                persistLocked(map)
                return .denied(status)
            }
        }

        map[attemptKey] = Data()
        persistLocked(map)
        return .missing
    }

    /// 明确放弃某个键的旧条目迁移（例如用户重新保存 / 删除过该凭据）：
    /// 避免删除后又把旧条目里的值当成新值读回来。
    static func suppressLegacy(vaultKey: String) {
        lock.lock()
        defer { lock.unlock() }
        var map = storageLocked()
        let key = legacyBlockedPrefix + vaultKey
        guard map[key] == nil else { return }
        map[key] = Data()
        persistLocked(map)
    }

    private static func legacyAttemptKey(_ vaultKey: String) -> String {
        legacyAttemptPrefix + vaultKey
    }

    // MARK: - 内部

    /// 调用方必须持有锁。
    private static func storageLocked() -> [String: Data] {
        if let cache { return cache }

        var map: [String: Data]
        switch KeychainAccess.read(KeychainAccess.Item(service: service, account: account)) {
        case .data(let data):
            if let decoded = try? JSONDecoder().decode([String: Data].self, from: data) {
                map = decoded
            } else {
                Diagnostics.record("统一凭据解码失败，将要求重新授权")
                map = [:]
            }
        case .missing:
            loadedFromMissing = true
            map = [:]
        case .denied:
            // 用户拒绝了保险库本身：本次运行不再尝试读写，也不要用空表覆盖原数据。
            loadFailed = true
            cache = [:]
            return [:]
        }

        if !didAttemptLegacyMigration {
            didAttemptLegacyMigration = true
            if migrateLegacyVaults(into: &map) {
                persistLocked(map)
            }
        }
        if cache == nil { cache = map }
        return cache ?? map
    }

    /// 调用方必须持有锁。返回是否成功写入钥匙串。
    @discardableResult
    private static func persistLocked(_ incoming: [String: Data]) -> Bool {
        guard !loadFailed else {
            Diagnostics.record("统一凭据不可读，已跳过写入")
            return false
        }
        var map = incoming
        if loadedFromMissing {
            loadedFromMissing = false
            // 首次读取说「没有」，写之前再确认一次：如果其实存在（例如搜索列表刚被修复），
            // 先合并已有数据，避免这一次写入把其它凭据覆盖掉。
            if case .data(let existing) = KeychainAccess.read(KeychainAccess.Item(service: service, account: account)),
               let decoded = try? JSONDecoder().decode([String: Data].self, from: existing) {
                var merged = decoded
                for (key, value) in map { merged[key] = value }
                if merged.count != map.count {
                    Diagnostics.record("统一凭据首次读取为空但实际存在，已合并写入")
                }
                map = merged
            }
        }
        cache = map
        guard let data = try? JSONEncoder().encode(map) else { return false }
        let item = KeychainAccess.Item(service: service, account: account)
        let status = KeychainAccess.write(data, to: item)
        guard status == errSecSuccess else {
            // -25299 = errSecDuplicateItem：条目存在但更新查不到，通常是钥匙串搜索列表
            // 缺少 login.keychain-db（build.sh 旧版会把多个路径拼成一项）。
            Diagnostics.record("统一凭据写入钥匙串失败 status=\(status)")
            return false
        }
        return true
    }

    /// 旧版两个保险库只读取一次；读到后合并进新保险库，并在保险库元数据里留下标记。
    /// 旧条目保留不删（删除本身还会再弹一次授权），只是之后永不再读。
    private static func migrateLegacyVaults(into map: inout [String: Data]) -> Bool {
        guard map[legacyVaultsMarkerKey] == nil else { return false }

        if case .data(let data) = KeychainAccess.read(KeychainAccess.Item(service: legacyCloudService, account: account)),
           let legacy = try? JSONDecoder().decode([String: Data].self, from: data) {
            for (key, value) in legacy where map["cloud.\(key)"] == nil {
                map["cloud.\(key)"] = value
            }
        }

        if case .data(let data) = KeychainAccess.read(KeychainAccess.Item(service: legacyCinemaService, account: account)),
           let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            for (key, value) in legacy where map["cinema.\(key)"] == nil {
                map["cinema.\(key)"] = Data(value.utf8)
            }
        }

        // 保险库本身「读不到」时可能是钥匙串搜索列表异常，不能把旧条目判定为已处理；
        // 这种情况下不落标记，下次启动重试，等钥匙串恢复正常后仍能迁入。
        if !loadedFromMissing {
            map[legacyVaultsMarkerKey] = Data()
        }
        return true
    }
}
