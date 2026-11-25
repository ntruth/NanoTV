import Foundation

/// 云端凭据（OAuth 令牌、网盘 Cookie、NAS 密码）统一走 `LumaKeychainVault`。
///
/// 旧版本这里维护过独立的「cloudvault」条目；现在所有键都加 `cloud.` 前缀，
/// 首次读取时由保险库静默迁移。读取结果由保险库统一缓存，不再逐项访问钥匙串。
enum CloudSecretStore {
    private static let prefix = "cloud."

    static func data(for key: String) -> Data? {
        LumaKeychainVault.data(for: prefix + key)
    }

    static func set(_ data: Data, for key: String) {
        LumaKeychainVault.set(data, for: prefix + key)
    }

    static func remove(_ key: String) {
        LumaKeychainVault.remove(prefix + key)
    }
}

