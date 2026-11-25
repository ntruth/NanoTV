import CryptoKit
import Foundation
import WebKit

/// JavCl（`javcl.com`）适配器。
///
/// - 列表：WordPress 服务端渲染，卡片是 `div.video-item`，标题在 `h4.video-title`，
///   封面是 `img.video-thumb` 的 `data-src`，分页 ` /page/N/ `。
/// - 分类：直接读 WP REST 的分类表（`/wp-json/wp/v2/categories`），比解析导航稳定。
/// - 搜索：`/search/<关键词>/page/N/`。
/// - 播放：详情页的播放按钮由前端脚本注入 iframe，直接 GET 拿不到地址；
///   用隐藏的 WKWebView 点一次播放按钮，取出 iframe 里的 slug。
///   真正视频地址是 `https://streamcl.click/m3u8/<md5(slug)>.m3u8`。
struct JavClCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://javcl.com"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        if let live = try? await Self.liveCategories(source: source, root: root), live.count >= 4 {
            return live
        }
        return source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await home(source: source, page: 1)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let address = page > 1 ? "\(root)/page/\(page)/" : root + "/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page) || items.count >= 24)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        let slug = target.id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !slug.isEmpty else { throw CatalogError.parse("分类地址无效") }
        var address = "\(root)/\(slug)/"
        if page > 1 { address += "page/\(page)/" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page) || items.count >= 24)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.pathEncoded(keyword) else {
            throw CatalogError.parse("搜索关键词无效")
        }
        var address = "\(root)/search/\(encoded)/"
        if page > 1 { address += "page/\(page)/" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page) || items.count >= 24)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/\(itemID)/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let title = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? itemID
        let cover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let models = Self.links(html, path: "/model/")
        let studios = Self.links(html, path: "/studio/")
        let tags = Self.links(html, path: "/tag/")

        var detail = WebCatalogSupport.singleEpisode(id: itemID,
                                                     title: title,
                                                     cover: cover,
                                                     pageURL: address,
                                                     blocks: WebCatalogSupport.tagBlocks(tags))
        if !models.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "女优",
                                                  value: models.joined(separator: "、")))
        }
        if !studios.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "片商",
                                                  value: studios.joined(separator: "、")))
        }
        if !tags.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "类型",
                                                  value: tags.prefix(6).joined(separator: "、")))
        }
        return detail
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        guard let pageURL = URL(string: episode.pageURL) else {
            throw CatalogError.parse("分集地址无效")
        }
        guard let streamURL = await JavClPlayerResolver.shared.resolve(pageURL: pageURL,
                                                                       cacheKey: episode.pageURL) else {
            throw CatalogError.parse("该条目没有可播放的视频")
        }
        return CatalogStream(url: streamURL,
                             headers: [
                                "User-Agent": source.userAgent,
                                "Referer": "https://streamcl.click/",
                                "Origin": "https://streamcl.click"
                             ],
                             isHLS: true)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        var probe = CatalogSource(name: "JavCl",
                                  kind: .javcl,
                                  baseURL: base,
                                  userAgent: defaultUserAgent,
                                  referer: base + "/",
                                  categories: [])
        let html = try await WebCatalogSupport.fetchHTML(base + "/", source: probe)
        guard html.contains("video-link") || html.contains("javcl") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        if let cats = try? await liveCategories(source: probe, root: base), !cats.isEmpty {
            probe.categories = cats
        }
        return CatalogSource(name: "JavCl",
                             kind: .javcl,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: probe.categories,
                             posterAspect: 3.0 / 4.0,
                             isEnabled: false)
    }

    // MARK: - 解析

    private static func pageSource(_ source: CatalogSource, root: String) -> CatalogSource {
        var copy = source
        copy.referer = root + "/"
        return copy
    }

    /// WP REST 分类表：按内容量排序，空分类直接丢掉。
    private static func liveCategories(source: CatalogSource, root: String) async throws -> [CatalogCategory] {
        let address = root + "/wp-json/wp/v2/categories?per_page=100&orderby=count&order=desc"
        let json = try await WebCatalogSupport.fetchHTML(address, source: pageSource(source, root: root))
        guard let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CatalogError.parse("分类解析失败")
        }
        return list.compactMap { entry in
            guard let slug = entry["slug"] as? String, !slug.isEmpty,
                  let name = entry["name"] as? String,
                  (entry["count"] as? Int ?? 0) > 0 else { return nil }
            let title = CatalogHTML.stripTags(name)
            guard !title.isEmpty else { return nil }
            return CatalogCategory(id: slug, title: title)
        }
    }

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"class="?video-item\b"#, in: html) {
            // 第一个链接是详情页；卡片尾部还有一个空的覆盖链接，会被 seen 去重。
            guard let rawHref = CatalogHTML.first(#"href=(?:"|')?([^"' >]+)"#, in: block),
                  let slug = slug(from: rawHref), seen.insert(slug).inserted else { continue }
            let title = CatalogHTML.first(#"class="?h6 video-title[^>]*>([\s\S]*?)</h4>"#, in: block)
                .map(CatalogHTML.stripTags)
                ?? CatalogHTML.first(#"<img[\s\S]*?alt="([^"]*)""#, in: block) ?? ""
            guard !title.isEmpty else { continue }
            let rawCover = CatalogHTML.first(#"data-src=(\S+\.(?:jpg|jpeg|png|webp))"#, in: block) ?? ""
            let cover = rawCover.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            result.append(CatalogItem(id: slug,
                                      title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: "",
                                      categoryID: nil))
        }
        return result
    }

    /// `path` 后面必须还有一段 slug，才不是顶部导航里的 `/model/` 这类空入口。
    private static func links(_ html: String, path: String) -> [String] {
        CatalogHTML.fullMatches(#"<a[^>]+href=[^ >]*\#(path)[^ >]+[^>]*>([\s\S]*?)</a>"#, in: html)
            .map(CatalogHTML.stripTags)
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { values, value in
                if !values.contains(value) { values.append(value) }
            }
    }

    private static func slug(from address: String) -> String? {
        guard let comps = URLComponents(string: address) else { return nil }
        var path = comps.path
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, !path.hasPrefix("wp-"), !path.hasPrefix("search") else { return nil }
        return path
    }

    private static func hasNextPage(_ html: String, page: Int) -> Bool {
        html.range(of: "/page/\(page + 1)/") != nil
            || html.range(of: "paged=\(page + 1)") != nil
    }
}

// MARK: - 播放页解析

/// JavCl 的播放按钮会由前端脚本注入一个跨域 iframe，普通 GET 拿不到地址。
/// 这里用一个隐藏的 WKWebView 点一次播放，读出 iframe 里的 slug；
/// 真正的 m3u8 是 `streamcl.click/m3u8/<md5(slug)>.m3u8`，只靠 slug 就能拼出来。
@MainActor
final class JavClPlayerResolver {
    static let shared = JavClPlayerResolver()

    private var cache: [String: URL] = [:]
    private var running: [String: Task<URL?, Never>] = [:]

    func resolve(pageURL: URL, cacheKey: String) async -> URL? {
        if let cached = cache[cacheKey] { return cached }
        if let task = running[cacheKey] { return await task.value }
        let task = Task<URL?, Never> { [weak self] in
            let slug = await JavClWebRunner.shared.playSlug(pageURL: pageURL)
            guard let slug, !slug.isEmpty else { return nil }
            let digest = Insecure.MD5.hash(data: Data(slug.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return URL(string: "https://streamcl.click/m3u8/\(digest).m3u8")
        }
        running[cacheKey] = task
        let result = await task.value
        running[cacheKey] = nil
        if let result { cache[cacheKey] = result }
        return result
    }
}

/// 加载详情页 → 点播放 → 轮询 iframe src。
@MainActor
private final class JavClWebRunner: NSObject, WKNavigationDelegate {
    static let shared = JavClWebRunner()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var finished = false

    func playSlug(pageURL: URL) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.finished = false
            self.continuation = continuation
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
                                 configuration: config)
            view.navigationDelegate = self
            webView = view
            view.load(URLRequest(url: pageURL))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self.finish(nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if let value = await evaluate(Self.clickScript), let slug = Self.slug(from: value) {
                    finish(slug)
                    return
                }
            }
            finish(nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(nil)
    }

    private func evaluate(_ script: String) async -> String? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    private func finish(_ slug: String?) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: slug)
        continuation = nil
        webView?.stopLoading()
        webView = nil
    }

    private static let clickScript = """
    (function(){
      try {
        var box = document.querySelector('#videoPlayer');
        var btn = box ? box.querySelector('.play-button') : document.querySelector('.play-button');
        if (btn) { btn.click(); }
        var frame = box ? box.querySelector('iframe') : document.querySelector('#videoPlayer iframe');
        return frame ? frame.src : '';
      } catch (e) { return ''; }
    })();
    """

    /// `https://streamcl.click/play/<slug>.html` → `<slug>`。
    private static func slug(from address: String) -> String? {
        guard !address.isEmpty, let comps = URLComponents(string: address) else { return nil }
        guard let last = comps.path.split(separator: "/").last else { return nil }
        let value = last.replacingOccurrences(of: ".html", with: "")
        return value.isEmpty ? nil : String(value)
    }
}
