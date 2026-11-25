import Foundation

/// Avple（`avple.tv` / `avple.app`）适配器。
///
/// Next.js 服务端渲染：列表卡片是 `/video/{id}` + `asserts.avple.tv` 封面；
/// 详情页的 `__NEXT_DATA__` 里带标题、封面、标签与 `play` 相对路径，
/// 播放地址要按 `play_source_type` 拼到对应的 cdnedge 节点上。
struct AvpleCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://avple.app"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "trend|daily", title: "每日热门"),
        CatalogCategory(id: "tag|121", title: "麻豆传媒"),
        CatalogCategory(id: "tag|122", title: "SWAG"),
        CatalogCategory(id: "tag|123", title: "果冻传媒"),
        CatalogCategory(id: "tag|124", title: "皇家华人"),
        CatalogCategory(id: "tag|125", title: "精东影业"),
        CatalogCategory(id: "tag|126", title: "天美传媒"),
        CatalogCategory(id: "tag|127", title: "星空无限"),
        CatalogCategory(id: "tag|131", title: "国产自拍"),
        CatalogCategory(id: "tag|135", title: "FC2PPV"),
        CatalogCategory(id: "tag|1", title: "巨乳"),
        CatalogCategory(id: "tag|33", title: "多P")
    ]

    /// `.tv` 域名被 Cloudflare 拦住，导入时换到可直连的镜像。
    private static let cloudflareHosts = ["avple.tv"]
    private static let assertCDNHosts = ["d862cp1", "q2cyl71", "u89ey1", "2dvqt1",
                                         "99fnq1", "x8x5b1", "isg2c1"]

    // MARK: - CatalogProvider

    /// 站点没有真正的分类层级：侧栏标签云（片商 / 衣着 / 身材 / 玩法）就是全部入口，
    /// 统一拍平成一级分类，不再单独做标签面板。
    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML(root + "/", source: source)
        else { return Self.defaultCategories }
        let live = Self.flattenCategories(html)
        return live.count > 2 ? live : Self.defaultCategories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/", source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: 1, hasMore: false)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        let parts = target.id.split(separator: "|", maxSplits: 1).map(String.init)
        let address: String
        if parts.count == 2, parts[0] == "trend" {
            address = "\(root)/trend/\(parts[1])/\(page)"
        } else if parts.count == 2, parts[0] == "tag" {
            address = "\(root)/tags/\(parts[1])/\(page)/date"
        } else {
            address = "\(root)/tags/\(target.id)/\(page)/date"
        }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: WebCatalogSupport.hasNextPage(html, page: page)
                               || items.count >= 24)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.queryEncoded(keyword)
        else { throw CatalogError.parse("搜索关键词无效") }
        var address = "\(root)/search?key=\(encoded)"
        if page > 1 { address += "&page=\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: WebCatalogSupport.hasNextPage(html, page: page)
                               || items.count >= 24)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/video/\(itemID)"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let instance = Self.instance(from: html)

        let title = (instance?["title"] as? String)
            ?? CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
                .map(CatalogHTML.stripTags) ?? ""
        let coverRaw = (instance?["img_normal"] as? String)
            ?? CatalogHTML.first(#"<video[^>]+poster="([^"]+)""#, in: html) ?? ""
        let tags = (instance?["tags"] as? [String]) ?? []
        let release = (instance?["release"] as? String) ?? ""

        return WebCatalogSupport.singleEpisode(
            id: itemID,
            title: title.isEmpty ? "视频 \(itemID)" : title,
            cover: CatalogHTML.fixURL(coverRaw, base: root),
            pageURL: address,
            remark: release,
            blocks: WebCatalogSupport.tagBlocks(tags)
        )
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        guard let url = URL(string: episode.pageURL) else {
            throw CatalogError.parse("分集地址无效")
        }
        let html = try await WebCatalogSupport.fetchHTML(url, source: source)
        let instance = Self.instance(from: html)
        let play = (instance?["play"] as? String)
            ?? CatalogHTML.first(#""play":"([^"]+)""#, in: html) ?? ""
        let type = (instance?["play_source_type"] as? Int)
            ?? Int(CatalogHTML.first(#""play_source_type":(\d+)"#, in: html) ?? "") ?? 14
        guard !play.isEmpty, let address = Self.playURL(play, type: type) else {
            throw CatalogError.parse("该条目没有可播放的视频")
        }
        return try WebCatalogSupport.stream(address, base: "",
                                            referer: episode.pageURL,
                                            userAgent: source.userAgent)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        var base = try WebCatalogSupport.base(from: address)
        if let host = URLComponents(string: base)?.host?.lowercased(),
           cloudflareHosts.contains(host) {
            base = defaultBaseURL
        }
        let probe = CatalogSource(name: "Avple",
                                  kind: .avple,
                                  baseURL: base,
                                  userAgent: defaultUserAgent,
                                  referer: base + "/",
                                  categories: defaultCategories)
        let html = try await WebCatalogSupport.fetchHTML(base + "/", source: probe)
        guard html.contains("avple") || html.contains("/video/") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        return CatalogSource(name: "Avple",
                             kind: .avple,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: {
                                 let live = flattenCategories(html)
                                 return live.count > 2 ? live : defaultCategories
                             }(),
                             posterAspect: 16.0 / 9.0,
                             isEnabled: false)
    }

    // MARK: - 解析：标签分组

    /// 把侧栏标签云拍平成一级分类：`每日热门` 打头，其余按片商 / 衣着 / 身材 / 玩法顺序。
    static func flattenCategories(_ html: String) -> [CatalogCategory] {
        var result: [CatalogCategory] = [CatalogCategory(id: "trend|daily", title: "每日热门")]
        var seen = Set(["trend|daily"])
        for group in parseTagGroups(html) {
            for child in group.children ?? [] where seen.insert(child.id).inserted {
                result.append(child)
            }
        }
        return result
    }

    /// 侧栏标签云按「片商 / 衣着 / 身材 / 玩法」分组，
    /// 每个分组下是 `/tags/{id}/1/date` 链接，点进去就是该标签的列表。
    static func parseTagGroups(_ html: String) -> [CatalogCategory] {
        let pattern = #"<div class="text-xs[^"]*text-center">([^<]+)</div>([\s\S]*?)(?=<div class="text-xs[^"]*text-center">|</aside>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let title = CatalogHTML.stripTags(ns.substring(with: match.range(at: 1)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 6 else { continue }
            let body = ns.substring(with: match.range(at: 2))
            var children: [CatalogCategory] = []
            var childSeen = Set<String>()
            for anchor in CatalogHTML.fullMatches(
                #"<a[^>]+href="/tags/(\d+)/1/date"[^>]*>([\s\S]*?)</a>"#, in: body) {
                guard let id = CatalogHTML.first(#"/tags/(\d+)/1/date"#, in: anchor) else { continue }
                let name = CatalogHTML.stripTags(anchor)
                    .replacingOccurrences(of: "#", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !name.contains("更多"),
                      childSeen.insert(id).inserted else { continue }
                children.append(CatalogCategory(id: "tag|\(id)", title: name))
            }
            guard !children.isEmpty, seen.insert(title).inserted else { continue }
            result.append(CatalogCategory(id: "group:tags:\(title)", title: title,
                                          children: children, isGroup: true))
        }
        return result
    }

    // MARK: - 解析：列表

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        let pattern = #"<a href="/video/(\d+)"[^>]*>[\s\S]{0,900}?<img[^>]+alt="([^"]*)"[^>]*?src="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators])
        else { return [] }
        let ns = html as NSString
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 4 else { continue }
            let id = ns.substring(with: match.range(at: 1))
            guard seen.insert(id).inserted else { continue }
            let title = ns.substring(with: match.range(at: 2))
            guard !title.isEmpty else { continue }
            // 列表只给 177px 的预览图，换成正式封面更清晰。
            let cover = ns.substring(with: match.range(at: 3))
                .replacingOccurrences(of: "/preview/1.webp", with: "/0/1.webp")
            let tailStart = match.range.location + match.range.length
            let tailLength = min(600, ns.length - tailStart)
            let tail = tailLength > 0
                ? ns.substring(with: NSRange(location: tailStart, length: tailLength)) : ""
            let duration = CatalogHTML.first(#"bottom-2 right-2[^"]*">\s*([\d:]+)\s*<"#,
                                             in: tail) ?? ""
            result.append(CatalogItem(id: id, title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: duration, categoryID: nil))
        }
        return result
    }

    // MARK: - 解析：详情与播放

    /// `__NEXT_DATA__` 里的视频对象（含 play / tags / title），结构变化时按递归找。
    static func instance(from html: String) -> [String: Any]? {
        guard let raw = CatalogHTML.first(#"<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)</script>"#,
                                          in: html),
              let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findInstance(root)
    }

    private static func findInstance(_ value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if dict["play"] != nil, dict["title"] != nil { return dict }
            for child in dict.values {
                if let found = findInstance(child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findInstance(child) { return found }
            }
        }
        return nil
    }

    /// 按站点的类型表把 `play` 相对路径拼到对应 CDN。
    static func playURL(_ play: String, type: Int) -> String? {
        if play.hasPrefix("http") { return play }
        switch type {
        case 1, 1001:
            return "https://hqua8q61at.cdnedge.live/file/avple-images/\(play)"
        case 2, 3, 4, 7, 8:
            return "https://d862cp.cdnedge.live/file/avple-images/\(play)"
        default:
            guard let host = assertCDNHosts.first else { return nil }
            return "https://\(host).cdnedge.live/file/avple-asserts/\(play)"
        }
    }
}
