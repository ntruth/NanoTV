import Foundation
import Security

/// 全应用唯一直接调用 Security.framework 的入口。
///
/// 收口约定：业务代码不再自己拼 `SecItem*` 查询。钥匙串相关的系统授权框只可能由
/// 这里的 `read`（首次读取旧条目）和 `write`（更新不在当前 App ACL 里的旧条目）触发，
/// 并且调用方都通过 `LumaKeychainVault` 的一次性迁移逻辑保证「每台机器只问一次」。
enum KeychainAccess {
    struct Item {
        let service: String
        let account: String
    }

    enum ReadResult {
        case data(Data)
        case missing
        /// 条目存在但当前 App 无权读取（用户点了拒绝，或屏幕锁定）。
        case denied(OSStatus)
    }

    /// 读取条目密文；条目在 ACL 之外时系统会弹出一次授权框。
    static func read(_ item: Item) -> ReadResult {
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).map(ReadResult.data) ?? .missing
        case errSecItemNotFound:
            return .missing
        default:
            return .denied(status)
        }
    }

    /// 写入条目：优先更新，不存在时新增。
    /// 新增时把 ACL 固定为当前 App，同一签名重新编译后不再逐项要求授权。
    @discardableResult
    static func write(_ data: Data, to item: Item, trustCurrentApp: Bool = true) -> OSStatus {
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery(item) as CFDictionary, update as CFDictionary)
        if updateStatus != errSecItemNotFound {
            return updateStatus
        }

        var attributes = baseQuery(item)
        attributes[kSecValueData as String] = data
        if trustCurrentApp, let access = currentAppAccess() {
            attributes[kSecAttrAccess as String] = access
        }
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    /// 屏幕锁定等原因造成的临时不可交互：不算用户拒绝，稍后可以再试一次。
    static func isTemporarilyUnavailable(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed
    }

    private static func baseQuery(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: item.service,
         kSecAttrAccount as String: item.account]
    }

    private static func currentAppAccess() -> SecAccess? {
        var trusted: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess,
              let trusted else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Luma 统一凭据" as CFString,
                              [trusted] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
