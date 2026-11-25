import Foundation

/// 智能助手 API Key：统一走 `LumaKeychainVault`，绝不进入图库数据库、UserDefaults 或日志。
///
/// 旧版本按 provider 分散在 `com.baymax.luma.ai` 的多个条目里：
/// 只有真正读取某个 provider 的 Key 时才尝试迁移一次，结果记录在保险库元数据里，
/// 之后（包括用户拒绝授权）都不再访问旧条目，因此最多只弹一次授权框。
enum AIKeychain {
    private static let legacyService = "com.baymax.luma.ai"

    private static func vaultKey(_ provider: AIProvider) -> String {
        "ai.\(provider.keychainAccount)"
    }

    static func key(for provider: AIProvider) -> String {
        if let value = LumaKeychainVault.string(for: vaultKey(provider)), !value.isEmpty {
            return value
        }
        let vaultKey = vaultKey(provider)
        if case .data(let data) = LumaKeychainVault.migrateLegacy(vaultKey: vaultKey,
                                                                 services: [legacyService],
                                                                 account: provider.keychainAccount),
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        return ""
    }

    /// 只判断是否已配置；数据来自统一保险库缓存，不会触发额外授权框。
    static func hasKey(for provider: AIProvider) -> Bool {
        !key(for: provider).isEmpty
    }

    static func setKey(_ key: String, for provider: AIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let vaultKey = vaultKey(provider)
        guard !trimmed.isEmpty else {
            deleteKey(for: provider)
            return
        }
        // 新值已写入统一保险库，旧条目不再读取，避免下次误迁移旧值。
        LumaKeychainVault.suppressLegacy(vaultKey: vaultKey)
        LumaKeychainVault.set(Data(trimmed.utf8), for: vaultKey)
    }

    static func deleteKey(for provider: AIProvider) {
        let vaultKey = vaultKey(provider)
        LumaKeychainVault.suppressLegacy(vaultKey: vaultKey)
        LumaKeychainVault.remove(vaultKey)
    }
}
