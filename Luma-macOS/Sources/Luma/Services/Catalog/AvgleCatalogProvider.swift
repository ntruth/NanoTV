import Foundation
import CryptoKit

/// Avgle（`www.avgle.pro`）适配器。
///
/// - 列表是 Bootstrap 卡片：`<div class="card">` + `/video/{id}`。
/// - 详情页前面挡了一层 CDN 工作量验证（PoW）：页面里给 seed 与难度，
///   算出满足前 N 位为零的 nonce 后 POST 到 `/__cdnlah/pow/verify`，才会放出详情页。
/// - 播放地址在详情页的 `<source src="…/index.m3u8">`。
struct AvgleCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://www.avgle.pro"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    /// 没有网络时用于渲染侧边栏骨架（与站点导航一致）。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "category/270", title: "日本无码"),
        CatalogCategory(id: "category/269", title: "日本有码"),
        CatalogCategory(id: "category/48", title: "中文字幕"),
        CatalogCategory(id: "category/254", title: "无码专区"),
        CatalogCategory(id: "category/92", title: "制服诱惑"),
        CatalogCategory(id: "category/93", title: "巨乳美乳"),
        CatalogCategory(id: "category/22", title: "亚洲情色"),
        CatalogCategory(id: "category/260", title: "欧美精品"),
        CatalogCategory(id: "category/452", title: "SWAG"),
        CatalogCategory(id: "category/130", title: "卡通动漫"),
        CatalogCategory(id: "category/401", title: "AV明星"),
        CatalogCategory(id: "category/86", title: "动漫精品")
    ]

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        if let html = try? await fetchUnlocked(root + "/", source: source) {
            let live = Self.parseNavCategories(html)
            if !live.isEmpty { return live }
        }
        return source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let html = try await fetchUnlocked(root + "/", source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: 1, hasMore: false)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        // 站点的 ?page=N 会被 CDN 拦成 492，只取每个分类的第一页。
        guard page <= 1 else { return CatalogPage(items: [], page: page, hasMore: false) }
        let path = target.id.hasPrefix("category/") ? target.id : "category/\(target.id)"
        // 分类页同样要过 CDN 工作量验证，否则会直接返回 492 验证页。
        let html = try await fetchUnlocked("\(root)/\(path)", source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: false)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        // 站内搜索与翻页都要通过 CDN 验证，普通请求会被拦成 492。
        throw CatalogError.parse("Avgle 的站内搜索需要浏览器验证，暂不支持")
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/video/\(itemID)"
        let html = try await fetchUnlocked(address, source: source)
        let title = CatalogHTML.first(#"<title[^>]*>([\s\S]*?)</title>"#, in: html)
            .map(CatalogHTML.stripTags) ?? ""
        let cover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        return WebCatalogSupport.singleEpisode(
            id: itemID,
            title: title.isEmpty ? "视频 \(itemID)" : title,
            cover: cover,
            pageURL: address
        )
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        let root = try WebCatalogSupport.root(source)
        let html = try await fetchUnlocked(episode.pageURL, source: source)
        guard let raw = CatalogHTML.first(#"<source[^>]+src="([^"]+\.m3u8[^"]*)""#, in: html)
                ?? CatalogHTML.first(#"<video[^>]+src="([^"]+\.m3u8[^"]*)""#, in: html)
        else { throw CatalogError.parse("该条目没有可播放的视频") }
        return try WebCatalogSupport.stream(raw, base: root,
                                            referer: root + "/",
                                            userAgent: source.userAgent)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        let probe = CatalogSource(name: "Avgle",
                                  kind: .avgle,
                                  baseURL: base,
                                  userAgent: defaultUserAgent,
                                  referer: base + "/",
                                  categories: defaultCategories)
        let html = try await WebCatalogSupport.fetchHTML(base + "/", source: probe)
        guard html.contains("/video/") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        let nav = parseNavCategories(html)
        return CatalogSource(name: "Avgle",
                             kind: .avgle,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: nav.isEmpty ? defaultCategories : nav,
                             posterAspect: 16.0 / 9.0,
                             isEnabled: false)
    }

    // MARK: - 解析：导航与列表

    static func parseNavCategories(_ html: String) -> [CatalogCategory] {
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        let pattern = #"<a[^>]+href="/category/(\d+)"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range(at: 1))
            let title = CatalogHTML.stripTags(ns.substring(with: match.range(at: 2)))
            guard !title.isEmpty, title.count <= 16, seen.insert(id).inserted else { continue }
            result.append(CatalogCategory(id: "category/\(id)", title: title))
        }
        return result
    }

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<div class="card""#, in: html) {
            guard let id = CatalogHTML.first(#"href="/video/([A-Za-z0-9]+)""#, in: block),
                  seen.insert(id).inserted else { continue }
            let title = CatalogHTML.first(#"<div class="two-lines">[\s\S]*?<a[^>]*>([\s\S]*?)</a>"#,
                                          in: block)
                .map(CatalogHTML.stripTags)
                ?? CatalogHTML.first(#"<img[^>]+alt="([^"]+)""#, in: block) ?? ""
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"<img[^>]+src="([^"]+)""#, in: block) ?? ""
            result.append(CatalogItem(id: id, title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: "", categoryID: nil))
        }
        return result
    }

    // MARK: - 工作量验证

    private struct PowConfig {
        var seed: String
        var difficulty: Int
        var verifyPath: String
        var redirect: String
        var cookieName: String
        var metadataField: String
        var metadataToken: String
    }

    private static func powConfig(_ html: String) -> PowConfig? {
        guard let raw = CatalogHTML.first(
            #"<script id="__cdnlah_pow_config" type="application/json">([\s\S]*?)</script>"#,
            in: html),
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seed = dict["seed"] as? String,
              let difficulty = dict["difficulty"] as? Int,
              let verify = dict["verify_path"] as? String
        else { return nil }
        return PowConfig(seed: seed,
                         difficulty: difficulty,
                         verifyPath: verify,
                         redirect: dict["redirect"] as? String ?? "/",
                         cookieName: dict["challenge_cookie"] as? String ?? "",
                         metadataField: dict["metadata_field"] as? String ?? "",
                         metadataToken: dict["metadata_token"] as? String ?? "")
    }

    /// 算出一个 SHA-256 以 `difficulty` 个 0 开头的 16 位十六进制 nonce。
    private static func solveNonce(seed: String, difficulty: Int) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let zeros = String(repeating: "0", count: max(1, difficulty))
            let limit = difficulty <= 4 ? 5_000_000 : 40_000_000
            for nonce in 0..<limit {
                let hex = String(format: "%016llx", UInt64(nonce))
                let digest = SHA256.hash(data: Data((seed + hex).utf8))
                let text = digest.map { String(format: "%02x", $0) }.joined()
                if text.hasPrefix(zeros) { return hex }
            }
            return nil
        }.value
    }

    /// 详情页可能被 CDN 拦截：先解工作量验证，通过后同一会话就能拿到详情页。
    private func fetchUnlocked(_ address: String, source: CatalogSource) async throws -> String {
        guard let url = URL(string: address) else {
            throw CatalogError.parse("页面地址无效")
        }
        // 验证页可能以 492 / 403 返回，正文里才有 seed，不能当失败直接抛出。
        let first = try await CatalogHTTP.fetchPage(url: url, source: source,
                                                    accepting: [200, 403, 492])
        guard let config = Self.powConfig(first) else { return first }

        guard let nonce = await Self.solveNonce(seed: config.seed,
                                                difficulty: config.difficulty) else {
            throw CatalogError.parse("站点安全验证计算超时")
        }
        let root = try WebCatalogSupport.root(source)
        guard let verifyURL = URL(string: root + config.verifyPath) else {
            throw CatalogError.parse("验证地址无效")
        }
        var fields: [(String, String)] = [
            ("seed", config.seed),
            ("nonce", nonce),
            ("redirect", config.redirect),
            ("challenge_cookie", config.cookieName)
        ]
        if !config.metadataField.isEmpty, !config.metadataToken.isEmpty {
            fields.append((config.metadataField, config.metadataToken))
        }
        let body = fields
            .map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }
            .joined(separator: "&")
        let data = try await CatalogHTTP.postJSON(url: verifyURL, headers: [
            "User-Agent": source.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": address
        ], body: Data(body.utf8))
        let html = String(decoding: data, as: UTF8.self)
        guard Self.powConfig(html) == nil else {
            throw CatalogError.parse("站点安全验证未通过")
        }
        return html
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
