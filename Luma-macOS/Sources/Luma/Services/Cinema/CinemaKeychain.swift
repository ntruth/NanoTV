import Foundation

/// 影院相关的敏感信息：家长控制 PIN、在线字幕账号、刮削源密钥，统一走 `LumaKeychainVault`。
///
/// 旧版本的「cinema」保险库由统一保险库首次读取时静默迁移；
/// 这里所有字段统一加 `cinema.` 前缀，读取结果只来自保险库的一次性缓存。
/// 旧版存在 `UserDefaults` 的刮削源密钥由 `AppSettings` 在启动时一次性搬进这里。
enum CinemaKeychain {
    enum Account: String {
        case parentalPIN = "parental_pin"
        case subtitleUsername = "subtitle_username"
        case subtitlePassword = "subtitle_password"
        case subtitleAssrtToken = "subtitle_assrt_token"
        case subtitleAPIKey = "subtitle_api_key"
        case tmdbAPIKey = "scraper_tmdb_api_key"
        case doubanCookie = "scraper_douban_cookie"
        case tvdbKey = "scraper_tvdb_key"
        case tvdbPIN = "scraper_tvdb_pin"
    }

    private static func vaultKey(_ account: Account) -> String {
        "cinema.\(account.rawValue)"
    }

    static func value(for account: Account) -> String {
        LumaKeychainVault.string(for: vaultKey(account)) ?? ""
    }

    /// 只判断是否已设置；数据来自同一个保险库缓存，不会触发额外授权框。
    static func has(_ account: Account) -> Bool {
        !value(for: account).isEmpty
    }

    /// 写入并返回是否真正落盘；旧明文迁移要在返回 true 后才删除 `UserDefaults` 里的值。
    @discardableResult
    static func set(_ value: String, for account: Account) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return LumaKeychainVault.remove(vaultKey(account))
        }
        return LumaKeychainVault.set(Data(trimmed.utf8), for: vaultKey(account))
    }

    @discardableResult
    static func remove(_ account: Account) -> Bool {
        set("", for: account)
    }

    /// 校验 PIN；未设置过 PIN 时视为通过。
    static func verifyPIN(_ pin: String) -> Bool {
        let saved = value(for: .parentalPIN)
        guard !saved.isEmpty else { return true }
        return saved == pin.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
