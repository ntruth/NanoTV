import Foundation

/// 91吃瓜（`91cg1.com`）适配器。
///
/// 站点是服务端渲染的主题页：
/// - 分类来自左侧导航的 `/category/{slug}/` 链接；「午夜影院」这类下拉分组保留为二级分类。
/// - 列表页 / 搜索结果都是 `<article>` 卡片，封面写在 `loadBannerDirect('…')` 里。
/// - 详情页的视频是多个 `<div class="dplayer" data-config='{…}'>`，`video.url` 即 m3u8 直链。
/// 因此全站只解析 HTML，不依赖写死的分类与播放接口。
struct NinetyOneCatalogProvider: CatalogProvider {

    // MARK: - 默认值

    static let defaultBaseURL = "https://www.91cg1.com"
    static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// 站点用 AES-128-CBC 加密图片（原始二进制密文），密钥与 IV 取自页面脚本。
    static let imageKey = "f5d965df75336270"
    static let imageIV = "97b60394abc2fbe1"

    /// 仅在没有网络时用于渲染侧边栏骨架。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "category/zxcghl", title: "今日吃瓜"),
        CatalogCategory(id: "category/dydj", title: "AI短剧"),
        CatalogCategory(id: "category/stjx", title: "ST精选"),
        CatalogCategory(id: "category/mrds", title: "每日大赛"),
        CatalogCategory(id: "category/sstp", title: "实时监控"),
        CatalogCategory(id: "category/rsdg", title: "最高点击"),
        CatalogCategory(id: "category/lpsd", title: "深夜撸片"),
        CatalogCategory(id: "category/crdm", title: "成人动漫"),
        CatalogCategory(id: "category/zdtop", title: "91周榜"),
        CatalogCategory(id: "category/bcdg", title: "必吃大瓜"),
        CatalogCategory(id: "category/whhl", title: "网红黑料"),
        CatalogCategory(id: "category/mxhl", title: "明星黑料"),
        CatalogCategory(id: "category/fclv", title: "反差靓女"),
        CatalogCategory(id: "category/zptp", title: "自拍偷拍")
    ]

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try rootURL(source)
        let html = try await fetchHTML(root, source: source)
        let live = Self.parseNavCategories(html)
        if !live.isEmpty { return live }
        return source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await home(source: source, page: 1)
    }

    /// 首页同样是分页的（`/page/2/`），滚到底自动续页。
    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        let root = try rootURL(source)
        var address = "\(root.absoluteString)/"
        if page > 1 { address += "page/\(page)/" }
        guard let url = URL(string: address) else {
            throw CatalogError.parse("首页地址无效")
        }
        let html = try await fetchHTML(url, source: source)
        let items = Self.parseCards(html, base: root.absoluteString)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, path: ""))
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try rootURL(source)
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        guard !target.id.isEmpty else { throw CatalogError.parse("分类地址无效") }
        var address = "\(root.absoluteString)/\(target.id)/"
        if page > 1 { address += "\(page)/" }
        guard let url = URL(string: address) else {
            throw CatalogError.parse("分类地址无效")
        }
        let html = try await fetchHTML(url, source: source)
        let items = Self.parseCards(html, base: root.absoluteString)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, path: target.id))
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try rootURL(source)
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { throw CatalogError.parse("搜索关键词无效") }
        var address = "\(root.absoluteString)/search/\(encoded)/"
        if page > 1 { address += "\(page)/" }
        guard let url = URL(string: address) else {
            throw CatalogError.parse("搜索地址无效")
        }
        let html = try await fetchHTML(url, source: source)
        let items = Self.parseCards(html, base: root.absoluteString)
        var hasMore = Self.hasNextPage(html, path: "search/\(encoded)")
        if !hasMore { hasMore = items.count >= 24 }
        return CatalogPage(items: items, page: page, hasMore: hasMore)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try rootURL(source)
        guard let url = URL(string: "\(root.absoluteString)/archives/\(itemID)/") else {
            throw CatalogError.parse("详情地址无效")
        }
        let html = try await fetchHTML(url, source: source)
        let title = Self.parseTitle(html)
        let cover = CatalogHTML.first(#"<meta itemprop="image" content="([^"]+)""#, in: html) ?? ""
        let item = CatalogItem(id: itemID,
                               title: title.isEmpty ? "第 \(itemID) 篇" : title,
                               coverURL: CatalogHTML.fixURL(cover, base: root.absoluteString),
                               remark: Self.parseDateText(html),
                               categoryID: nil)
        let configs = Self.parsePlayerConfigs(html)
        let episodes = configs.enumerated().map { index, config in
            CatalogEpisode(index: index + 1,
                           pageURL: url.absoluteString,
                           coverURL: CatalogHTML.fixURL(config.pic ?? "",
                                                        base: root.absoluteString))
        }
        let content = Self.parseContent(html, base: root.absoluteString)
        return CatalogDetail(item: item, episodes: episodes, blocks: content)
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        guard let url = URL(string: episode.pageURL) else {
            throw CatalogError.parse("分集地址无效")
        }
        let html = try await fetchHTML(url, source: source)
        let configs = Self.parsePlayerConfigs(html)
        guard !configs.isEmpty else {
            throw CatalogError.parse("该条目没有可直接播放的视频")
        }
        let index = min(max(0, episode.index - 1), configs.count - 1)
        guard let raw = configs[index].url,
              let streamURL = URL(string: CatalogHTML.fixURL(raw, base: "")) else {
            throw CatalogError.parse("视频地址解析失败")
        }
        return CatalogStream(url: streamURL,
                             headers: ["User-Agent": source.userAgent,
                                       "Referer": url.absoluteString],
                             isHLS: true)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        guard let url = URL(string: CatalogHTML.fixURL(urlString, base: source.baseURL)) else {
            throw CatalogError.parse("封面地址无效")
        }
        let data = try await CatalogHTTP.fetchData(url: url, headers: [
            "User-Agent": source.userAgent,
            "Referer": source.referer,
            "Accept": "image/avif,image/webp,image/*,*/*;q=0.8"
        ])
        guard !data.isEmpty else { throw CatalogError.parse("封面为空") }
        // 站点图片是 AES 加过密的二进制；已解密或本身就是图片时原样返回。
        return CatalogCrypto.decodeImage(data: data,
                                        key: Self.imageKey,
                                        iv: Self.imageIV) ?? data
    }

    // MARK: - 导入

    /// 从站点地址创建源：补协议、去掉尾部斜杠，并拉一次首页解析导航。
    static func importSource(from address: String) async throws -> CatalogSource {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CatalogError.invalidConfig("地址为空") }
        var raw = trimmed
        if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
        guard var comps = URLComponents(string: raw), let host = comps.host, !host.isEmpty,
              let scheme = comps.scheme else {
            throw CatalogError.invalidConfig("地址无法识别")
        }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        guard let root = comps.url else { throw CatalogError.invalidConfig("地址无法识别") }
        var base = root.absoluteString
        while base.hasSuffix("/") { base.removeLast() }

        guard let homeURL = URL(string: base) else {
            throw CatalogError.invalidConfig("地址无法识别")
        }
        let data = try await CatalogHTTP.fetchData(url: homeURL,
                                                   headers: ["User-Agent": defaultUserAgent,
                                                             "Accept": "text/html"])
        let html = String(decoding: data, as: UTF8.self)
        let categories = parseNavCategories(html)
        guard html.contains("post-card") || html.contains("91cg") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(scheme)://\(host)")
        }

        return CatalogSource(
            name: "91吃瓜",
            kind: .ninetyOne,
            baseURL: base,
            configURL: trimmed,
            userAgent: defaultUserAgent,
            referer: base + "/",
            categories: categories.isEmpty ? defaultCategories : categories,
            posterAspect: 1.95,
            isEnabled: false
        )
    }

    // MARK: - 请求

    private func rootURL(_ source: CatalogSource) throws -> URL {
        var base = source.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base) else {
            throw CatalogError.invalidConfig("站点地址无效")
        }
        return url
    }

    private func fetchHTML(_ url: URL, source: CatalogSource) async throws -> String {
        try await CatalogHTTP.fetchPage(url: url, source: source)
    }

    // MARK: - 解析：导航

    /// 一级项来自 `li.category-level-0` 里的直接分类链接；
    /// 带下拉按钮的分组（如「午夜影院」）保留为二级分类。
    static func parseNavCategories(_ html: String) -> [CatalogCategory] {
        // 只切左侧菜单这一段：后面紧跟字号设置与顶部导航，混进来会解析出重复的假分组。
        var scope = html
        if let start = html.range(of: #"<ul id="menu-menu-1""#)?.lowerBound {
            let end = html.range(of: #"<div id="nav-toolbar">"#, range: start..<html.endIndex)?.lowerBound
                ?? html.endIndex
            scope = String(html[start..<end])
        }

        let marker = #"<li class="mobile-category-item category-level-0[^"]*"[^>]*>"#
        let blocks = CatalogHTML.blocks(marker, in: scope)
        var result: [CatalogCategory] = []
        var seen = Set<String>()

        for block in blocks {
            let links = parseCategoryLinks(block)
            guard let first = links.first else { continue }
            let buttonTitle = CatalogHTML.first(#"<button[^>]*>\s*([^<]+?)\s*</button>"#, in: block)
                .map(CatalogHTML.stripTags)

            if let buttonTitle, !buttonTitle.isEmpty, links.count > 1 {
                let slug = "group-" + first.id.replacingOccurrences(of: "/", with: "-")
                guard seen.insert(slug).inserted else { continue }
                result.append(CatalogCategory(id: slug, title: buttonTitle,
                                              children: links, isGroup: true))
            } else {
                guard seen.insert(first.id).inserted else { continue }
                result.append(first)
            }
        }
        return result
    }

    /// 抽取一段 HTML 里的 `/category/{slug}/` 链接（保持站点顺序、去重）。
    private static func parseCategoryLinks(_ text: String) -> [CatalogCategory] {
        let anchors = CatalogHTML.fullMatches(
            #"<a[^>]+href="/category/[^/"]+/"[^>]*>[\s\S]*?</a>"#, in: text)
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for anchor in anchors {
            guard let slug = CatalogHTML.first(#"href="/category/([^/"]+)/"#, in: anchor)
            else { continue }
            let title = CatalogHTML.stripTags(anchor)
            guard !title.isEmpty else { continue }
            let id = "category/\(slug)"
            guard seen.insert(id).inserted else { continue }
            result.append(CatalogCategory(id: id, title: title))
        }
        return result
    }

    // MARK: - 解析：列表

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        let articles = CatalogHTML.fullMatches(
            #"<article[^>]*itemtype="http://schema.org/BlogPosting"[^>]*>[\s\S]*?</article>"#,
            in: html)
        var result: [CatalogItem] = []
        var seen = Set<String>()

        for article in articles {
            // 第一页是相对地址，第二页起主站会给绝对地址，两种都要认。
            guard let id = CatalogHTML.first(#"content="(?:https?://[^"]+)?/archives/(\d+)/""#,
                                             in: article)
                    ?? CatalogHTML.first(#"href="(?:https?://[^"]+)?/archives/(\d+)/""#,
                                         in: article),
                  seen.insert(id).inserted else { continue }

            var titleHTML = CatalogHTML.first(
                #"<h2 class="post-card-title[^"]*"[^>]*>([\s\S]*?)</h2>"#, in: article) ?? ""
            // 标题里的「热搜 HOT」等角标不进入标题文本。
            titleHTML = titleHTML.replacingOccurrences(of: #"<div class="wrap">[\s\S]*?</div>"#,
                                                       with: "", options: .regularExpression)
            let title = CatalogHTML.stripTags(titleHTML)
            guard !title.isEmpty else { continue }

            var cover = CatalogHTML.first(#"loadBannerDirect\('([^']+)'"#, in: article)
                ?? CatalogHTML.first(#"data-src="([^"]+)""#, in: article)
                ?? CatalogHTML.first(#"<meta itemprop="image" content="([^"]+)""#, in: article)
                ?? ""
            cover = CatalogHTML.fixURL(cover, base: base)

            let date = CatalogHTML.first(#"datePublished" content="([^"]+)""#, in: article) ?? ""
            let tags = CatalogHTML.first(#"<div class="post-card-info">([\s\S]*?)</div>"#,
                                         in: article)
                .flatMap { info in
                    CatalogHTML.fullMatches(#"<span>([^<]*)</span>"#, in: info)
                        .map(CatalogHTML.stripTags)
                        .last
                } ?? ""
            let firstTag = tags.split(separator: ",").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
            let dateText = shortDate(date)
            let remark = [firstTag, dateText].filter { !$0.isEmpty }.joined(separator: " · ")

            result.append(CatalogItem(id: id, title: title, coverURL: cover,
                                      remark: remark, categoryID: nil))
        }
        return result
    }

    static func hasNextPage(_ html: String, path: String) -> Bool {
        CatalogHTML.first(#"<li class="next"><a href="([^"]+)""#, in: html) != nil
    }

    // MARK: - 解析：详情与播放

    static func parseTitle(_ html: String) -> String {
        let raw = CatalogHTML.first(#"<h1 class="post-title[^"]*"[^>]*>([\s\S]*?)</h1>"#, in: html) ?? ""
        return CatalogHTML.stripTags(raw)
    }

    static func parseDateText(_ html: String) -> String {
        let raw = CatalogHTML.first(#"<meta itemprop="datePublished" content="([^"]+)""#, in: html) ?? ""
        return shortDate(raw)
    }

    /// 正文：按站点原始顺序输出标题 / 段落 / 配图。
    /// 站点把长文写成 `<p>文字</p><p><img…></p><h2>小标题</h2>` 的序列，
    /// 先整体去掉广告块，再逐块收集，才能保持图文交错的阅读节奏。
    static func parseContent(_ html: String, base: String) -> [CatalogContentBlock] {
        var scope = html
        if let start = html.range(of: #"<div class="post-content""#)?.lowerBound {
            var end = html.endIndex
            // 版权声明之后是「相关推荐 / 关键词 / 推广二维码」，正文到此为止。
            for marker in [#"<p class="content-copyright""#, #"<div class="tags">"#,
                           "可能你会感兴趣的", "请截图保存下图", "<strong> 91吃瓜推荐"] {
                if let range = html.range(of: marker, range: start..<html.endIndex),
                   range.lowerBound < end {
                    end = range.lowerBound
                }
            }
            scope = String(html[start..<end])
        }

        // 去掉脚本、广告引用块、推广表格与播放器，只留正文本身。
        var cleaned = scope
        for pattern in [#"<script[\s\S]*?</script>"#,
                        #"<style[\s\S]*?</style>"#,
                        #"<blockquote[\s\S]*?</blockquote>"#,
                        #"<table[\s\S]*?</table>"#,
                        #"<div class="dplayer"[\s\S]*?</div>"#] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "",
                                                   options: .regularExpression)
        }

        let blockedWords = ["91吃瓜最新地址", "永久地址", "建议使用", "邮箱", "福利",
                            "QQ群", "版权", "转载请注明", "关键词", "点击查看详情"]
        var result: [CatalogContentBlock] = []
        var seenText = Set<String>()
        var seenImages = Set<String>()

        func appendParagraph(_ text: String) {
            guard text.count >= 8,
                  !blockedWords.contains(where: { text.contains($0) }),
                  seenText.insert(text).inserted else { return }
            result.append(CatalogContentBlock(kind: .paragraph, text: text))
        }

        func appendImages(in raw: String) {
            for tag in CatalogHTML.fullMatches(#"<img[^>]*>"#, in: raw) {
                // 懒加载属性优先；`src` 常是占位图。
                let rawURL = CatalogHTML.first(#"data-xkrkllgl="([^"]+)""#, in: tag)
                    ?? CatalogHTML.first(#"data-src="([^"]+)""#, in: tag)
                    ?? CatalogHTML.first(#"src="([^"]+)""#, in: tag)
                    ?? ""
                let url = CatalogHTML.fixURL(rawURL, base: base)
                guard url.hasPrefix("http"), isImageURL(url),
                      seenImages.insert(url).inserted else { continue }
                result.append(CatalogContentBlock(kind: .image, text: url))
            }
        }

        // 段落、小标题、figure 以及「没有被 p 包裹的裸 img」都按出现顺序入列，
        // 这样有些文章把图直接写在正文里的情况也不会丢图或错位。
        let tokenPattern = #"<(h2|h3|p|figure)(?:\s[^>]*)?>[\s\S]*?</\1>|<img[^>]*>"#
        for raw in CatalogHTML.fullMatches(tokenPattern, in: cleaned) {
            if raw.hasPrefix("<img") {
                appendImages(in: raw)
                continue
            }
            // 小标题：单独成块，排版时做大做重。
            if raw.hasPrefix("<h2") || raw.hasPrefix("<h3") {
                let text = CatalogHTML.stripTags(raw)
                guard text.count >= 2, seenText.insert(text).inserted else { continue }
                result.append(CatalogContentBlock(kind: .heading, text: text))
                continue
            }
            // p / figure：先把图片摘出来，剩下的才是正文文字。
            let textHTML = raw.replacingOccurrences(of: #"<img[^>]*>"#, with: "",
                                                    options: .regularExpression)
            appendParagraph(CatalogHTML.stripTags(textHTML))
            appendImages(in: raw)
        }
        return result
    }

    /// 站点偶尔输出 `https://pic.nsxxlj.cn//pic.nsxxlj.cn` 这样的坏地址，用扩展名过滤掉。
    private static func isImageURL(_ url: String) -> Bool {
        let path = url.split(separator: "?").first.map(String.init) ?? url
        let lower = path.lowercased()
        return [".jpg", ".jpeg", ".png", ".webp", ".gif"].contains { lower.hasSuffix($0) }
    }

    struct PlayerConfig {
        var title: String
        var url: String?
        /// 单集封面（dplayer 的 `video.pic`）。
        var pic: String?
    }
    /// 详情页里的播放器：一个 `<div class="dplayer">` 就是一集，`video.url` 是 m3u8。
    static func parsePlayerConfigs(_ html: String) -> [PlayerConfig] {
        let tags = CatalogHTML.fullMatches(
            #"<div class="dplayer"[\s\S]*?data-config='[^']*'[^>]*>"#, in: html)
        var result: [PlayerConfig] = []
        for tag in tags {
            var title = CatalogHTML.first(#"data-video_title="([^"]*)""#, in: tag) ?? ""
            if title.isEmpty {
                title = CatalogHTML.first(#"data-video_id="([^"]*)""#, in: tag) ?? ""
            }
            var url: String?
            var pic: String?
            if let config = CatalogHTML.first(#"data-config='([^']*)'"#, in: tag),
               let data = config.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let video = json["video"] as? [String: Any] {
                url = video["url"] as? String
                pic = video["pic"] as? String
            }
            guard url != nil else { continue }
            result.append(PlayerConfig(title: title, url: url, pic: pic))
        }
        return result
    }

    // MARK: - 工具

    /// ISO8601 → `MM-dd`；解析不了就原样返回空串。
    private static func shortDate(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: raw) else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
}
