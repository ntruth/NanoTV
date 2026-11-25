import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation
import Network
import NetFS
import LumaContentCore

enum CloudIdentity {
    static func id(mountID: UUID, path: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(mountID.uuidString)|\(path)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - 凭据（Keychain）

enum CloudCredentials {
    /// 仅用于迁移旧版本存放在钥匙串里的 NAS 密码 / 网盘 Cookie。
    private static let service = "com.baymax.photosclone.webdav"
    private static let legacyService = "com.lijialong.photosclone.webdav"

    /// 进程内缓存：滚动目录时每次点击都会新建客户端，但密码只读一次。
    private static let cacheLock = NSLock()
    private static var cache: [UUID: String] = [:]

    static func password(for mountID: UUID) -> String {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[mountID] { return cached }
        let value = storedPassword(for: mountID)
        cache[mountID] = value
        return value
    }

    /// 认证失败时丢掉缓存：下次真正需要连接时再读一次。
    static func invalidate(for mountID: UUID) {
        cacheLock.lock()
        cache[mountID] = nil
        cacheLock.unlock()
    }

    /// 切换图库时清空，避免把上一个图库的网盘密码留在内存里。
    static func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    static func setPassword(_ password: String, for mountID: UUID) {
        let account = "password.\(mountID.uuidString)"
        LumaKeychainVault.suppressLegacy(vaultKey: vaultKey(account))
        CloudSecretStore.set(Data(password.utf8), for: account)
        cacheLock.lock()
        cache[mountID] = password
        cacheLock.unlock()
    }

    static func delete(for mountID: UUID) {
        let account = "password.\(mountID.uuidString)"
        LumaKeychainVault.suppressLegacy(vaultKey: vaultKey(account))
        CloudSecretStore.remove(account)
        cacheLock.lock()
        cache[mountID] = nil
        cacheLock.unlock()
    }

    private static func storedPassword(for mountID: UUID) -> String {
        let account = "password.\(mountID.uuidString)"
        if let data = CloudSecretStore.data(for: account),
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        // 旧版本存在钥匙串里：只读取一次，结果由统一保险库记录，之后不再访问钥匙串。
        switch LumaKeychainVault.migrateLegacy(vaultKey: vaultKey(account),
                                               services: [service, legacyService],
                                               account: mountID.uuidString) {
        case .data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        case .denied(let status):
            Diagnostics.record("网盘密码旧条目读取被拒绝 status=\(status)")
            return ""
        case .missing:
            return ""
        }
    }

    private static func vaultKey(_ account: String) -> String {
        "cloud.\(account)"
    }
}

// MARK: - 缓存路径

enum CloudPaths {
    static func thumbnailURL(mountID: UUID, path: String) -> URL {
        cacheURL(mountID: mountID, path: path, prefix: "")
    }

    /// 云缩略图快速层（192px）：滚动时先出小图，再替换成 900px 目标图。
    static func quickThumbnailURL(mountID: UUID, path: String) -> URL {
        cacheURL(mountID: mountID, path: path, prefix: "q-")
    }

    private static func cacheURL(mountID: UUID, path: String, prefix: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return LibraryPaths.cloudThumbs
            .appendingPathComponent(mountID.uuidString, isDirectory: true)
            .appendingPathComponent(prefix + String(digest.prefix(40)) + ".jpg")
    }
}

enum CloudPlayback {
    /// AVFoundation 未公开该常量名，但支持注入请求头（百度网盘直链需要 UA）。
    static let headerFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"
}

// MARK: - AList 探测

/// AList / OpenList 的连通性探测与 WebDAV 地址推导。
enum AListProbe {
    static func webdavAddress(_ raw: String) -> String? {
        guard let base = WebDAVClient.normalizedBaseURL(raw) else { return nil }
        var text = base.absoluteString
        if !text.hasSuffix("/") { text += "/" }
        return text + "dav"
    }

    static func check(address: String) async -> (ok: Bool, message: String) {
        guard let base = WebDAVClient.normalizedBaseURL(address),
              let url = URL(string: base.absoluteString + "ping") else {
            return (false, "地址格式不正确，例如 http://127.0.0.1:5244")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "服务器响应异常")
            }
            switch http.statusCode {
            case 200:
                let body = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if body.lowercased().contains("pong") {
                    return (true, "AList 连接成功")
                }
                return (true, "已连接（/ping 未返回 pong，可能经过反向代理）")
            case 404:
                return (false, "该地址不是 AList（/ping 返回 404）")
            default:
                return (false, "AList 返回 HTTP \(http.statusCode)")
            }
        } catch {
            return (false, "连接失败：\(error.localizedDescription)")
        }
    }

    private static let session = HTTPSessionPool.shared.session(.probe)
}

/// 云缩略图失败短缓存：同一张图失败后 60 秒内不再重复请求远端。
///
/// 没有这层缓存时，一次滚动里失败的项目会在每次重新进入视野时再次发起
/// WebDAV Range 或整文件下载；在网络盘上很容易把队列彻底堵死。
actor CloudThumbnailFailureCache {
    static let shared = CloudThumbnailFailureCache()

    private var failed: [String: Date] = [:]
    private let ttl: TimeInterval = 60
    private let maxEntries = 4_000

    func isFailing(_ key: String) -> Bool {
        guard let date = failed[key] else { return false }
        if Date().timeIntervalSince(date) < ttl { return true }
        failed.removeValue(forKey: key)
        return false
    }

    func markFailure(_ key: String) {
        if failed.count >= maxEntries {
            let cutoff = Date().addingTimeInterval(-ttl)
            failed = failed.filter { $0.value >= cutoff }
            if failed.count >= maxEntries { failed.removeAll(keepingCapacity: true) }
        }
        failed[key] = Date()
    }

    func clear(_ key: String) {
        failed.removeValue(forKey: key)
    }
}

/// 文件头探测缓存（默认前 256KB）。
///
/// EXIF 扫描与缩略图生成都会各取一次同样的 Range 请求；缓存后同一张图只下一次。
/// TTL 很短、条目很少，只用于同一次浏览期间的去重。
actor CloudProbeCache {
    struct Probe {
        let data: Data
        let partial: Bool
    }

    static let shared = CloudProbeCache()

    private var entries: [String: (probe: Probe, date: Date)] = [:]
    private let ttl: TimeInterval = 180
    private let maxEntries = 16

    func probe(for key: String) -> Probe? {
        guard let entry = entries[key] else { return nil }
        if Date().timeIntervalSince(entry.date) < ttl { return entry.probe }
        entries.removeValue(forKey: key)
        return nil
    }

    func store(_ probe: Probe, for key: String) {
        if entries.count >= maxEntries {
            let cutoff = Date().addingTimeInterval(-ttl)
            entries = entries.filter { $0.value.date >= cutoff }
            if entries.count >= maxEntries { entries.removeAll(keepingCapacity: true) }
        }
        entries[key] = (probe, Date())
    }
}
