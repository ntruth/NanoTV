import AppKit
import WebKit

/// FoFo 站点在 Cloudflare 后面：直接发 URLSession 请求会拿到「Just a moment…」验证页。
///
/// 这里用一个隐藏的 WKWebView 完成一次人机验证，取出 `cf_clearance` 与 WebView 的
/// User-Agent，再交给 URLSession 复用。Cloudflare 的 clearance 绑定 IP + UA，
/// 所以后续页面请求必须使用同一个 UA；封面（图床）与 m3u8（CDN）不受影响。
struct FoFoSession: Sendable {
    var cookies: String
    var userAgent: String
    var expiresAt: Date
}

@MainActor
final class FoFoCloudflareGate {
    static let shared = FoFoCloudflareGate()

    private var cache: [String: FoFoSession] = [:]
    private var running: [String: Task<FoFoSession, Error>] = [:]

    func session(for root: String) async throws -> FoFoSession {
        let host = (URL(string: root)?.host ?? root).lowercased()
        if let cached = cache[host], cached.expiresAt > Date().addingTimeInterval(30) {
            return cached
        }
        if let task = running[host] { return try await task.value }

        let task = Task { try await Self.solve(root: root) }
        running[host] = task
        defer { running[host] = nil }
        let session = try await task.value
        cache[host] = session
        return session
    }

    func invalidate(host: String) {
        cache[host.lowercased()] = nil
    }

    /// 加载首页 → 等验证通过 → 读取 Cookie 与 UA。
    private static func solve(root: String) async throws -> FoFoSession {
        guard let url = URL(string: root) else {
            throw CatalogError.invalidConfig("站点地址无效")
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
                             configuration: config)
        // 放到屏幕外：既让 WebKit 正常跑定时器，又不打断用户当前窗口。
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 1280, height: 900),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = view
        window.orderBack(nil)
        defer {
            view.stopLoading()
            window.orderOut(nil)
        }

        view.load(URLRequest(url: url))
        var passed = false
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let title = await eval(view, "document.title") ?? ""
            let cards = Int(await eval(view, "String(document.querySelectorAll('a.thumbnail').length)") ?? "0") ?? 0
            let low = title.lowercased()
            let challenging = low.contains("just a moment")
                || title.contains("请稍候")
                || title.contains("安全验证")
            if !challenging, cards > 3 {
                passed = true
                break
            }
        }
        guard passed else {
            throw CatalogError.unavailable("站点的人机验证没有通过，请稍后在浏览器打开站点重试。")
        }

        let userAgent = await eval(view, "navigator.userAgent") ?? ""
        let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        guard !header.isEmpty else {
            throw CatalogError.unavailable("站点验证通过但没有拿到 Cookie。")
        }
        let expiry = max(Date().addingTimeInterval(5 * 60),
                         cookies.compactMap(\.expiresDate).min()
                            ?? Date().addingTimeInterval(20 * 60))
        return FoFoSession(cookies: header,
                           userAgent: userAgent,
                           expiresAt: expiry)
    }

    private static func eval(_ view: WKWebView, _ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }
}
