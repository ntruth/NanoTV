import Foundation

/// JavGG（`javgg.com`）适配器。
///
/// - 列表：KVS 站，卡片是 `<li class="thumbs__item">`，标题在链接的 `title`，
///   封面在 `data-original`，时长在 `thumbs__item-duration`。
/// - 翻页：服务端认 `?from=N`（每页 24 条），分类 / 搜索同样带这个参数。
/// - 分类：`/categories/<slug>/`；女优 `/models/…`、片商 `/channels/…` 只做详情页信息。
/// - 播放：详情页直接给出 mp4（`_720p.mp4` 带 `v-acctoken`），跟着 302 跳到 CDN，
///   不需要浏览器脚本，也不需要解密。
struct JavGGCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://javgg.com"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    /// 没有网络时用于渲染侧边栏骨架。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "categories/big-tits", title: "巨乳"),
        CatalogCategory(id: "categories/creampie", title: "中出"),
        CatalogCategory(id: "categories/amateur", title: "素人"),
        CatalogCategory(id: "categories/milf", title: "人妻"),
        CatalogCategory(id: "categories/anal", title: "肛交"),
        CatalogCategory(id: "categories/bondage", title: "束缚"),
        CatalogCategory(id: "categories/blowjob", title: "口交")
    ]

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        if let live = try? await Self.liveCategories(source: source, root: root), live.count >= 4 {
            return live
        }
        return source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await home(source: source, page: 1)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let address = page > 1
            ? "\(root)/latest-updates/?from=\(page)"
            : "\(root)/latest-updates/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page))
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        let id = target.id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty else { throw CatalogError.parse("分类地址无效") }
        var address = "\(root)/\(id)/"
        if page > 1 { address += "?from=\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page))
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.pathEncoded(keyword) else {
            throw CatalogError.parse("搜索关键词无效")
        }
        var address = "\(root)/search/\(encoded)/"
        if page > 1 { address += "?from=\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page))
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/\(itemID)/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let title = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? itemID
        let cover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let models = Self.taggedTitles(html, path: "models")
        let channels = Self.taggedTitles(html, path: "channels")
        let tags = Self.taggedTitles(html, path: "tags").map {
            $0.hasPrefix("#") ? String($0.dropFirst()) : $0
        }

        var detail = WebCatalogSupport.singleEpisode(id: itemID,
                                                     title: title,
                                                     cover: cover,
                                                     pageURL: address,
                                                     blocks: WebCatalogSupport.tagBlocks(tags))
        if !models.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "女优",
                                                  value: models.joined(separator: "、")))
        }
        if !channels.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "片商",
                                                  value: channels.joined(separator: "、")))
        }
        if !tags.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "类型",
                                                  value: tags.prefix(6).joined(separator: "、")))
        }
        return detail
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        guard !episode.pageURL.isEmpty else { throw CatalogError.parse("分集地址无效") }
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(episode.pageURL,
                                                         source: Self.pageSource(source, root: root))
        // 详情页里有多种 mp4：720p 正片（带 token）、hover 预览。优先正片。
        // 结尾必须是 `.mp4` / `.mp4/` / `.mp4?token`，避免把预览图 `xxx.mp4.jpg` 当成视频。
        let urls = CatalogHTML.fullMatches(
            #"https?://[^"'\s<>]+\.mp4(?:\?[^"'\s<>]*|/(?:\?[^"'\s<>]*)?)?"#, in: html)
            .map(Self.decodeEntities)
        let tokened = urls.filter { $0.contains("v-acctoken") }
        guard let raw = tokened.first(where: { $0.contains("_720p.mp4") })
                ?? tokened.first(where: { !$0.contains("_preview") })
                ?? urls.first(where: { !$0.contains("_preview") })
                ?? urls.first else {
            throw CatalogError.parse("该条目没有可播放的视频")
        }
        guard let url = URL(string: raw) else {
            throw CatalogError.parse("视频地址解析失败")
        }
        return CatalogStream(url: url,
                             headers: ["User-Agent": source.userAgent,
                                       "Referer": root + "/"],
                             isHLS: false)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        var probe = CatalogSource(name: "JavGG",
                                  kind: .javgg,
                                  baseURL: base,
                                  userAgent: defaultUserAgent,
                                  referer: base + "/",
                                  categories: defaultCategories)
        let html = try await WebCatalogSupport.fetchHTML(base + "/latest-updates/", source: probe)
        guard html.contains("thumbs__item") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        if let cats = try? await liveCategories(source: probe, root: base), !cats.isEmpty {
            probe.categories = cats
        }
        return CatalogSource(name: "JavGG",
                             kind: .javgg,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: probe.categories,
                             posterAspect: 16.0 / 9.0,
                             isEnabled: false)
    }

    // MARK: - 解析

    private static func pageSource(_ source: CatalogSource, root: String) -> CatalogSource {
        var copy = source
        copy.referer = root + "/"
        return copy
    }

    private static func liveCategories(source: CatalogSource, root: String) async throws -> [CatalogCategory] {
        let html = try await WebCatalogSupport.fetchHTML(root + "/categories/",
                                                         source: pageSource(source, root: root))
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for anchor in CatalogHTML.fullMatches(#"<a[^>]+href="https?://[^"]*/categories/[^"]+"[^>]*>[\s\S]*?</a>"#,
                                              in: html) {
            guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: anchor),
                  let comps = URLComponents(string: href) else { continue }
            let title = CatalogHTML.stripTags(anchor)
            guard !title.isEmpty else { continue }
            let path = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard path.hasPrefix("categories/"), seen.insert(path).inserted else { continue }
            result.append(CatalogCategory(id: path, title: translate(title)))
        }
        return result
    }

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<li class="?thumbs__item\b"#, in: html) {
            guard let href = CatalogHTML.first(#"href="(https?://[^"]+/video/[^"]+)""#, in: block),
                  let slug = slug(from: href),
                  seen.insert(slug).inserted else { continue }
            let title = CatalogHTML.first(#"title="([^"]*)""#, in: block)
                ?? CatalogHTML.first(#"alt="([^"]*)""#, in: block) ?? ""
            guard !title.isEmpty else { continue }
            let rawCover = CatalogHTML.first(#"data-original="([^"]+)""#, in: block)
                ?? CatalogHTML.first(#"data-webp="([^"]+)""#, in: block) ?? ""
            let duration = CatalogHTML.first(#"thumbs__item-duration">([^<]+)<"#, in: block) ?? ""
            result.append(CatalogItem(id: slug,
                                      title: decodeEntities(title),
                                      coverURL: CatalogHTML.fixURL(decodeEntities(rawCover), base: base),
                                      remark: duration,
                                      categoryID: nil))
        }
        return result
    }

    /// `https://javgg.com/video/1024/slug/` → `video/1024/slug`。
    private static func slug(from address: String) -> String? {
        guard let comps = URLComponents(string: address) else { return nil }
        var path = comps.percentEncodedPath
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("video/") else { return nil }
        return path
    }

    /// 详情页里 `models` / `channels` / `tags` 三组标签，优先取链接的 `title`。
    private static func taggedTitles(_ html: String, path: String) -> [String] {
        CatalogHTML.fullMatches(#"<a[^>]+href="https?://[^"]*/\#(path)/[^"]+"[^>]*>[\s\S]*?</a>"#, in: html)
            .compactMap { anchor in
                let value = CatalogHTML.first(#"title="([^"]+)""#, in: anchor)
                    ?? CatalogHTML.stripTags(anchor)
                let text = decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            .reduce(into: [String]()) { values, value in
                if !values.contains(value) { values.append(value) }
            }
    }

    private static func hasNextPage(_ html: String, page: Int) -> Bool {
        html.contains("from:\(page + 1)") || html.contains("from=\(page + 1)")
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") || text.contains("\\&") else { return text }
        var value = text
            .replacingOccurrences(of: "\\&#34;", with: "\"")
            .replacingOccurrences(of: "\\&#39;", with: "'")
            .replacingOccurrences(of: "\\&quot;", with: "\"")
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // 剩下 `&#123;` 这类数字实体统一还原。
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let ns = value as NSString
            let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() where match.numberOfRanges > 1 {
                let digits = ns.substring(with: match.range(at: 1))
                guard let code = UInt32(digits), let scalar = Unicode.Scalar(code) else { continue }
                value = (value as NSString).replacingCharacters(in: match.range,
                                                                 with: String(Character(scalar)))
            }
        }
        return value
    }

    /// 站点分类是英文，侧边栏用中文更顺手；没映射的保留原文。
    private static func translate(_ title: String) -> String {
        let map: [String: String] = [
            "big-tits": "巨乳", "creampie": "中出", "amateur": "素人", "milf": "人妻",
            "anal": "肛交", "bondage": "束缚", "blowjob": "口交", "bukkake": "颜射",
            "cheating": "出轨", "cuckold": "绿帽", "mature": "熟女", "gangbang": "轮奸",
            "cougar": "熟女", "gilf": "高龄熟女"
        ]
        let key = title.lowercased().replacingOccurrences(of: " ", with: "-")
        return map[key] ?? title
    }
}
