import Foundation
import LumaContentCore

/// 黄果短剧适配器。
///
/// 站点 `huangguoai.io` 的列表、分类、搜索都是服务端渲染的页面：
/// 一级分类在主导航（`data-nav-*`），二级分类在频道页的 tab（`hg-channel-tabs`），
/// 所以这里全部从页面结构解析，站点改版时不依赖写死的分类表。
/// 详情与播放地址走 JSON 接口。
struct HuangguoCatalogProvider: CatalogProvider {

    // MARK: - 默认值

    static let defaultBaseURL = "https://huangguoai.io"
    static let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let defaultArtworkKey = "f5d965df75336270"
    static let defaultArtworkIV = "97b60394abc2fbe1"

    /// 仅在没有网络时用于渲染侧边栏骨架。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "original", title: "黄果原创"),
        CatalogCategory(id: "ai-duanju", title: "短剧"),
        CatalogCategory(id: "ai-manju", title: "漫剧"),
        CatalogCategory(id: "ranks/hot", title: "排行榜", isRank: true)
    ]

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        if let live = try? await fetchLiveCategories(source: source), !live.isEmpty {
            return live
        }
        return source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    /// 一级分类来自首页主导航；每个频道页的 tab 再补成二级分类。
    private func fetchLiveCategories(source: CatalogSource) async throws -> [CatalogCategory] {
        try await withResolvedBase(source) { base, src in
            let homeHTML = try await fetchHTML(url: base, source: src)
            var level1 = Self.parseNavCategories(homeHTML)
            guard !level1.isEmpty else { return [] }

            for index in level1.indices where !level1[index].isRank {
                guard let url = URL(string: "\(base.absoluteString)/\(level1[index].id)/")
                else { continue }
                guard let html = try? await fetchHTML(url: url, source: src) else { continue }
                let tabs = Self.parseChannelTabs(html)
                // 只有一个 tab 时它就是「全部」，没有分层意义。
                if tabs.count > 1 { level1[index].children = tabs }
            }
            return level1
        }
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await withResolvedBase(source) { base, src in
            let html = try await fetchHTML(url: base, source: src)
            let items = Self.parseDramaCards(html, source: src)
            return CatalogPage(items: items, page: 1, hasMore: false)
        }
    }

    /// 首页的「热门标签」区块，作为跨分类的第三级筛选。
    func tags(source: CatalogSource) async throws -> [CatalogCategory] {
        try await withResolvedBase(source) { base, src in
            let html = try await fetchHTML(url: base, source: src)
            return Self.parseHotTags(html)
        }
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        try await withResolvedBase(source) { base, src in
            var address = "\(base.absoluteString)/\(category.id)/"
            if page > 1 { address += "\(page)/" }
            guard let url = URL(string: address) else {
                throw CatalogError.parse("分类地址无效")
            }
            let html = try await fetchHTML(url: url, source: src)
            let items = category.isRank
                ? Self.parseRankItems(html, source: src)
                : Self.parseDramaCards(html, source: src)
            return CatalogPage(items: items, page: page,
                               hasMore: Self.hasNextPage(html, path: category.id, page: page))
        }
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        try await withResolvedBase(source) { base, src in
            guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            else { throw CatalogError.parse("搜索关键词无效") }
            var address = "\(base.absoluteString)/search/video/\(encoded)/"
            if page > 1 { address += "\(page)/" }
            guard let url = URL(string: address) else {
                throw CatalogError.parse("搜索地址无效")
            }
            let html = try await fetchHTML(url: url, source: src)
            let items = Self.parseDramaCards(html, source: src)
            var hasMore = Self.hasNextPage(html, path: "search/video/\(encoded)", page: page)
            // 搜索页可能不渲染页码链接，用「本页是否满」兜底。
            if !hasMore { hasMore = items.count >= 24 }
            return CatalogPage(items: items, page: page, hasMore: hasMore)
        }
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        try await withResolvedBase(source) { base, src in
            guard let url = URL(string: "\(base.absoluteString)/api/videos/\(itemID)")
            else { throw CatalogError.parse("详情地址无效") }
            let data = try await CatalogHTTP.fetchData(url: url, headers: jsonHeaders(src))
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = root["data"] as? [String: Any] else {
                throw CatalogError.parse("详情数据格式异常")
            }
            let item = parseItem(d, source: src)
            let parsed = parseEpisodes(from: d, id: itemID, source: src)
            let episodes = parsed.isEmpty
                ? [CatalogEpisode(index: 1, pageURL: "\(base.absoluteString)/video/\(itemID)/")]
                : parsed
            return CatalogDetail(item: item, episodes: episodes,
                                 blocks: Self.parseSynopsis(d),
                                 facts: Self.parseFacts(d))
        }
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        // 从 pageURL 提取 video id
        let id: String
        if let match = try? NSRegularExpression(pattern: #"/video/(\d+)"#)
            .firstMatch(in: episode.pageURL, range: NSRange(episode.pageURL.startIndex..., in: episode.pageURL)),
           let range = Range(match.range(at: 1), in: episode.pageURL) {
            id = String(episode.pageURL[range])
        } else {
            throw CatalogError.parse("分集地址无法提取视频 ID")
        }

        let epNum = String(episode.index)
        return try await withResolvedBase(source) { base, src in
            // 站点播放接口是普通 POST，直接返回 streams.main
            guard let url = URL(string: "\(base.absoluteString)/api/videos/\(id)/episodes/\(epNum)/playback")
            else { throw CatalogError.parse("播放地址无效") }
            let bodyData = try await CatalogHTTP.postJSON(url: url, headers: [
                "User-Agent": src.userAgent,
                "Accept": "application/json, text/plain, */*",
                "Content-Type": "application/json",
                "Referer": "\(base.absoluteString)/video/\(id)/"
            ], body: Data("{}".utf8))

            guard let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let d = json["data"] as? [String: Any],
                  let streams = d["streams"] as? [String: Any] else {
                throw CatalogError.parse("播放地址格式异常")
            }
            let rawURL = (streams["main"] as? String)
                ?? (streams["preview"] as? String)
                ?? (streams["hevc"] as? String)
                ?? ""
            let clean = rawURL
                .replacingOccurrences(of: "\\u0026", with: "&")
                .replacingOccurrences(of: "\\/", with: "/")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.lowercased().hasPrefix("http"),
                  let playURL = URL(string: clean) else {
                throw CatalogError.parse("未获取到可用播放地址")
            }

            // CDN 可能需要额外鉴权头
            var extraHeaders: [String: String] = [:]
            if let cdn = d["cdn"] as? [String: Any],
               let authKey = cdn["authKey"] as? String,
               let authValue = cdn["authValue"] as? String,
               !authKey.isEmpty {
                extraHeaders[authKey] = authValue
            }

            var headers: [String: String] = [
                "User-Agent": src.userAgent,
                "Referer": src.referer
            ]
            for (k, v) in extraHeaders { headers[k] = v }

            return CatalogStream(url: playURL, headers: headers, isHLS: true)
        }
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await withResolvedBase(source) { _, src in
            guard let url = URL(string: urlString) else {
                throw CatalogError.parse("封面地址无效")
            }
            let data = try await CatalogHTTP.fetchData(url: url, headers: [
                "User-Agent": src.userAgent,
                "Referer": src.referer,
                "Accept": "image/*,*/*;q=0.8"
            ])
            guard let image = CatalogCrypto.decodeImage(
                data: data,
                key: src.artworkKey ?? Self.defaultArtworkKey,
                iv: src.artworkIV ?? Self.defaultArtworkIV
            ) else { throw CatalogError.decryption }
            return image
        }
    }

    // MARK: - 页面请求

    private func fetchHTML(url: URL, source: CatalogSource) async throws -> String {
        let data = try await CatalogHTTP.fetchData(url: url, headers: [
            "User-Agent": source.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Referer": source.referer
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonHeaders(_ source: CatalogSource) -> [String: String] {
        [
            "User-Agent": source.userAgent,
            "Accept": "application/json, text/plain, */*",
            "Referer": source.referer
        ]
    }

    // MARK: - 详情 JSON 解析

    private func parseItem(_ dict: [String: Any], source: CatalogSource) -> CatalogItem {
        let id = String(describing: dict["id"] ?? "")
        let title = (dict["title"] as? String) ?? ""
        let cover = (dict["cover"] as? String) ?? ""

        var parts: [String] = []
        if let finished = dict["is_finished"] as? Bool, finished {
            let total = (dict["total_episodes"] as? Int)
                ?? (dict["episode_count"] as? Int) ?? 0
            parts.append(total > 0 ? "全\(total)集" : "已完结")
        } else if let count = dict["episode_count"] as? Int, count > 0 {
            parts.append("更新至\(count)集")
        }
        if let score = dict["score"] as? Double, score > 0 {
            parts.append(String(format: "%.1f分", score))
        }
        let remark = parts.joined(separator: " · ")

        return CatalogItem(id: id, title: title,
                           coverURL: cover,
                           remark: remark, categoryID: nil)
    }

    private func parseEpisodes(from dict: [String: Any], id: String,
                                source: CatalogSource) -> [CatalogEpisode] {
        if let eps = dict["episodes"] as? [[String: Any]], !eps.isEmpty {
            return eps.compactMap { ep in
                guard let num = ep["ep_num"] as? Int else { return nil }
                // 站点若给了单集封面就用，没有则由详情页回退到条目封面。
                let cover = (ep["cover"] as? String)
                    ?? (ep["cover_url"] as? String)
                    ?? (ep["coverUrl"] as? String)
                    ?? (ep["poster"] as? String)
                    ?? ""
                return CatalogEpisode(index: num,
                                      pageURL: "\(source.baseURL)/video/\(id)/ep-\(num)/",
                                      coverURL: cover)
            }.sorted { $0.index < $1.index }
        }
        let count = (dict["episode_count"] as? Int)
            ?? (dict["total_episodes"] as? Int)
            ?? (dict["total_count"] as? Int)
            ?? 1
        return (1...max(1, count)).map { i in
            CatalogEpisode(index: i, pageURL: "\(source.baseURL)/video/\(id)/ep-\(i)/")
        }
    }

    // MARK: - 详情补充信息

    /// 结构化信息：上线日期、更新状态、单集片长、出品、播放次数、题材类型、评分。
    static func parseFacts(_ dict: [String: Any]) -> [CatalogDetailFact] {
        var facts: [CatalogDetailFact] = []

        if let created = dict["created_at"] as? String, created.count >= 10 {
            facts.append(CatalogDetailFact(label: "上线日期", value: String(created.prefix(10))))
        }

        let finished = (dict["is_finished"] as? Bool) ?? false
        let total = intValue(dict["total_episodes"]) ?? 0
        let count = intValue(dict["episode_count"]) ?? 0
        if finished {
            facts.append(CatalogDetailFact(label: "更新状态",
                                           value: total > 0 ? "已完结 · 全 \(total) 集" : "已完结"))
        } else if count > 0 {
            facts.append(CatalogDetailFact(label: "更新状态", value: "更新至 \(count) 集"))
        }

        if let duration = intValue(dict["duration"]), duration > 0 {
            facts.append(CatalogDetailFact(label: "单集片长", value: durationText(duration)))
        }

        if let author = dict["author"] as? [String: Any],
           let name = author["name"] as? String, !name.isEmpty {
            facts.append(CatalogDetailFact(label: "出品", value: name))
        }

        if let counts = dict["counts"] as? [String: Any] {
            if let hot = intValue(counts["hot"]), hot > 0 {
                facts.append(CatalogDetailFact(label: "播放次数", value: compactCount(hot)))
            }
            if let collect = intValue(counts["collect"]), collect > 0 {
                facts.append(CatalogDetailFact(label: "收藏", value: compactCount(collect)))
            }
        }

        var genre: [String] = []
        if let breadcrumb = dict["breadcrumb"] as? [[String: Any]],
           let first = breadcrumb.first?["name"] as? String, !first.isEmpty {
            genre.append(first)
        }
        if let tags = dict["tags"] as? [String], !tags.isEmpty {
            genre.append(tags.prefix(4).joined(separator: " · "))
        }
        if !genre.isEmpty {
            facts.append(CatalogDetailFact(label: "题材类型", value: genre.joined(separator: " · ")))
        }

        if let score = dict["score"] as? Double, score > 0 {
            facts.append(CatalogDetailFact(label: "综合评分", value: String(format: "%.1f 分", score)))
        }

        if let actors = dict["actors"] as? [String], !actors.isEmpty {
            facts.append(CatalogDetailFact(label: "演员",
                                           value: actors.prefix(4).joined(separator: " · ")))
        }
        return facts
    }

    /// 剧情简介：按换行拆成段落，交给详情页正文区排版。
    static func parseSynopsis(_ dict: [String: Any]) -> [CatalogContentBlock] {
        guard let raw = dict["description"] as? String else { return [] }
        let text = CatalogHTML.stripTags(raw)
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { CatalogContentBlock(kind: .paragraph, text: $0) }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func compactCount(_ value: Int) -> String {
        guard value >= 10_000 else { return value.formatted() }
        let wan = Double(value) / 10_000
        return wan >= 100 ? String(format: "%.0f 万", wan) : String(format: "%.1f 万", wan)
    }

    private static func durationText(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - 辅助

    /// 先用缓存的可用地址直接请求；只有真的连不上时才清缓存、重新找地址并重试一次。
    /// 这样正常使用时永远走缓存，换地址只发生在地址失效的那一刻。
    private func withResolvedBase<T>(_ source: CatalogSource,
                                     _ body: (URL, CatalogSource) async throws -> T) async throws -> T {
        let original = try normalizedBase(source)
        // 镜像地址可能是 `https://xxx.cc/`，拼路径必须去掉结尾斜杠：
        // `//api/videos/…` 会被镜像直接当成 404。
        var base = Self.origin(await HuangguoAddressResolver.shared.base(for: original, source: source))
        do {
            return try await body(base, pointed(source, at: base))
        } catch {
            guard Self.isAddressFailure(error) else { throw error }
            await HuangguoAddressResolver.shared.invalidate(original)
            let fresh = Self.origin(
                await HuangguoAddressResolver.shared.refresh(original, source: source)
            )
            guard fresh != base else { throw error }
            base = fresh
            return try await body(base, pointed(source, at: base))
        }
    }

    /// 站点根地址统一成不带结尾斜杠的形式。
    private static func origin(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text) ?? url
    }

    /// 源的 baseURL / Referer 指向实际使用的地址，页面、接口与封面都落在同一台镜像上。
    private func pointed(_ source: CatalogSource, at base: URL) -> CatalogSource {
        var copy = source
        copy.baseURL = base.absoluteString
        copy.referer = base.absoluteString + "/"
        return copy
    }

    /// 只有「地址失效」类错误才值得换域名重试：连不上、超时、5xx、WAF、证书被劫持。
    private static func isAddressFailure(_ error: Error) -> Bool {
        if let error = error as? CatalogError {
            switch error {
            case .unavailable, .tls:
                return true
            case .http(let status):
                return status == 0 || status >= 500 || status == 403
            default:
                return false
            }
        }
        if let error = error as? SourceError {
            switch error.kind {
            case .unavailable, .blocked, .tlsUntrusted:
                return true
            case .http:
                return (error.statusCode ?? 0) >= 500
            default:
                return false
            }
        }
        return error is URLError
    }

    /// 老版本脚本里写死的域名已停用，先做一次静态迁移。
    private func normalizedBase(_ source: CatalogSource) throws -> URL {
        var text = source.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        let migrations = ["huangguoai.com": "huangguoai.io"]
        if let host = URL(string: text)?.host, let target = migrations[host] {
            text = text.replacingOccurrences(of: host, with: target)
        }
        guard !text.isEmpty, let url = URL(string: text) else {
            throw CatalogError.invalidConfig("站点地址为空")
        }
        return url
    }
}

// MARK: - 页面解析

extension HuangguoCatalogProvider {

    /// 主导航：`<a data-nav-key="…" data-nav-name="…" data-nav-route="…">`。
    static func parseNavCategories(_ html: String) -> [CatalogCategory] {
        guard let regex = try? NSRegularExpression(pattern: #"<a\b[^>]*data-nav-key="[^"]+"[^>]*>"#) else {
            return []
        }
        let ns = html as NSString
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            let key = CatalogHTML.first(#"data-nav-key="([^"]+)""#, in: tag) ?? ""
            let name = CatalogHTML.first(#"data-nav-name="([^"]+)""#, in: tag) ?? ""
            let route = CatalogHTML.first(#"data-nav-route="([^"]+)""#, in: tag)
            let href = CatalogHTML.first(#"href="([^"]+)""#, in: tag) ?? ""
            guard !name.isEmpty else { continue }

            let category: CatalogCategory?
            if key == "rank" {
                let type = href.split(separator: "/").last.map(String.init) ?? "hot"
                category = CatalogCategory(id: "ranks/\(type)", title: name, isRank: true)
            } else if key == "video_original" {
                category = CatalogCategory(id: "original", title: name)
            } else if key.hasPrefix("video_category_"), let route, !route.isEmpty {
                category = CatalogCategory(id: route, title: name)
            } else {
                category = nil
            }

            guard let category, seen.insert(category.id).inserted else { continue }
            result.append(category)
        }
        return result
    }

    /// 频道页 tab：`<a class="hg-channel-tabs__item" href="/original/manju/">原创漫剧</a>`。
    static func parseChannelTabs(_ html: String) -> [CatalogCategory] {
        let pattern = #"<a\b[^>]*hg-channel-tabs__item[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: tag) else { continue }
            // 站点同时输出 PC / H5 两套文案，优先取 PC 的那一份。
            let title = CatalogHTML.first(#"hg-channel-tabs__label--pc[^>]*>([\s\S]*?)</span>"#, in: tag)
                .map(CatalogHTML.stripTags)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? CatalogHTML.stripTags(ns.substring(with: match.range(at: 1)))
            let id = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !title.isEmpty, !id.isEmpty, !id.contains("#"), seen.insert(id).inserted else { continue }
            result.append(CatalogCategory(id: id, title: title))
        }
        return result
    }

    /// 热门标签：`<a class="hg-tagrow__item" href="/tag/dushi/">都市</a>`。
    static func parseHotTags(_ html: String) -> [CatalogCategory] {
        let pattern = #"<a\b[^>]*hg-tagrow__item[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: tag) else { continue }
            let title = CatalogHTML.stripTags(ns.substring(with: match.range(at: 1)))
            let id = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !title.isEmpty, id.hasPrefix("tag/"), seen.insert(id).inserted else { continue }
            result.append(CatalogCategory(id: id, title: title))
        }
        return result
    }

    /// 卡片列表：只取当前可见的 `hg-card-grid is-active` 面板，避免把推荐位混进来。
    static func parseDramaCards(_ html: String, source: CatalogSource) -> [CatalogItem] {
        let slice = activeGridSlice(html)
        let blocks = splitBlocks(slice, marker: #"<div class="hg-drama-card""#)
        var seen = Set<String>()
        return blocks.compactMap { block in
            guard let id = CatalogHTML.first(#"href="/video/(\d+)/""#, in: block),
                  seen.insert(id).inserted else { return nil }
            var title = CatalogHTML.first(
                #"hg-drama-card__title[^>]*>\s*<a[^>]*>([\s\S]*?)</a>"#, in: block).map(CatalogHTML.stripTags)
            if title?.isEmpty != false {
                title = CatalogHTML.first(#"<img[^>]*alt="([^"]+)""#, in: block)
            }
            let cover = CatalogHTML.first(#"data-src="([^"]+)""#, in: block) ?? ""
            let episode = CatalogHTML.first(
                #"hg-drama-card__episode[^>]*>([\s\S]*?)</span>"#, in: block)
                .map(CatalogHTML.stripTags) ?? ""
            let score = CatalogHTML.first(
                #"hg-drama-card__score[^>]*>([\s\S]*?)</span>"#, in: block)
                .map(CatalogHTML.stripTags) ?? ""
            let remark = [episode, score].filter { !$0.isEmpty }.joined(separator: " · ")
            return CatalogItem(id: id, title: title ?? id, coverURL: cover,
                               remark: remark, categoryID: nil)
        }
    }

    /// 排行榜：`hg-rank-item`。
    static func parseRankItems(_ html: String, source: CatalogSource) -> [CatalogItem] {
        let blocks = splitBlocks(html, marker: #"<div class="hg-rank-item""#)
        var seen = Set<String>()
        return blocks.compactMap { block in
            guard let id = CatalogHTML.first(#"href="/video/(\d+)/""#, in: block),
                  seen.insert(id).inserted else { return nil }
            var title = CatalogHTML.first(
                #"hg-rank-item__title[^>]*>\s*<a[^>]*>([\s\S]*?)</a>"#, in: block).map(CatalogHTML.stripTags)
            if title?.isEmpty != false {
                title = CatalogHTML.first(#"<img[^>]*alt="([^"]+)""#, in: block)
            }
            let cover = CatalogHTML.first(#"data-src="([^"]+)""#, in: block) ?? ""
            let episode = CatalogHTML.first(
                #"hg-rank-item__ep[^>]*>([\s\S]*?)</span>"#, in: block)
                .map(CatalogHTML.stripTags) ?? ""
            let score = CatalogHTML.first(#"(\d+(?:\.\d+)?分)"#, in: block) ?? ""
            let remark = [episode, score].filter { !$0.isEmpty }.joined(separator: " · ")
            return CatalogItem(id: id, title: title ?? id, coverURL: cover,
                               remark: remark, categoryID: nil)
        }
    }

    /// 页码链接：`/original/manju/2/`。
    static func hasNextPage(_ html: String, path: String, page: Int) -> Bool {
        let target = "href=\"/\(path)/\(page + 1)/\""
        guard html.contains(target) else { return false }
        return true
    }

    /// 截出当前激活的卡片面板；没有面板标记时退回整页。
    private static func activeGridSlice(_ html: String) -> String {
        guard let marker = html.range(of: "hg-card-grid is-active") else { return html }
        let start = html[..<marker.lowerBound].range(of: "<div", options: .backwards)?.lowerBound
            ?? marker.lowerBound
        let rest = html[marker.upperBound...]
        if let next = rest.range(of: "hg-card-grid") {
            let cut = rest[..<next.lowerBound].range(of: "<div", options: .backwards)?.lowerBound
                ?? next.lowerBound
            return String(html[start..<cut])
        }
        return String(html[start...])
    }

    private static func splitBlocks(_ text: String, marker: String) -> [String] {
        let parts = text.components(separatedBy: marker)
        guard parts.count > 1 else { return [] }
        return Array(parts.dropFirst())
    }
}

// MARK: - 导入

extension HuangguoCatalogProvider {
    /// 导入 FongMi 兼容配置（或其指向的脚本），产出一个可保存的源。
    /// 只做静态解析，不新增任何内置站点；配置地址与参数都来自用户输入。
    static func importSource(from address: String) async throws -> CatalogSource {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw CatalogError.invalidConfig("请填写 http(s) 地址")
        }

        let firstText = try await CatalogHTTP.fetchText(url: url)
        var name = ""
        var scriptURL = url

        if firstText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            guard let data = firstText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sites = object["sites"] as? [[String: Any]],
                  let site = sites.first else {
                throw CatalogError.invalidConfig("配置里没有 sites")
            }
            name = site["name"] as? String ?? ""
            if let type = site["type"] as? NSNumber, type.intValue != 3 {
                throw CatalogError.unsupportedProvider
            }
            guard let api = site["api"] as? String, let apiURL = URL(string: api) else {
                throw CatalogError.invalidConfig("配置缺少 api")
            }
            scriptURL = apiURL
        } else if !firstText.contains("const SITE") {
            throw CatalogError.invalidConfig("该地址既不是配置 JSON，也不是 FongMi 脚本")
        }

        let script = scriptURL == url ? firstText : try await CatalogHTTP.fetchText(url: scriptURL)
        guard let site = CatalogHTML.first(#"const SITE\s*=\s*['"]([^'"]+)['"]"#, in: script),
              !site.isEmpty else {
            throw CatalogError.invalidConfig("脚本里没有 SITE")
        }
        let key = CatalogHTML.first(#"const IMG_KEY\s*=\s*['"]([^'"]+)['"]"#, in: script)
            ?? defaultArtworkKey
        let iv = CatalogHTML.first(#"const IMG_IV\s*=\s*['"]([^'"]+)['"]"#, in: script)
            ?? defaultArtworkIV
        let userAgent = CatalogHTML.first(#"const UA\s*=\s*['"]([^'"]+)['"]"#, in: script)
            ?? defaultUserAgent

        var base = site
        while base.hasSuffix("/") { base.removeLast() }

        // 已知源站域名迁移
        let siteMigrations: [String: String] = [
            "huangguoai.com": "huangguoai.io"
        ]
        if let host = URL(string: base)?.host,
           let migration = siteMigrations[host] {
            base = base.replacingOccurrences(of: host, with: migration)
        }

        // 分类以站点实时导航为准；拉不到时用内置骨架。
        var categories = defaultCategories
        if let home = URL(string: base),
           let html = try? await CatalogHTTP.fetchText(url: home) {
            let live = parseNavCategories(html)
            if !live.isEmpty { categories = live }
        }

        return CatalogSource(
            name: name.isEmpty ? (URL(string: base)?.host ?? "网络资源") : name,
            baseURL: base,
            configURL: trimmed,
            userAgent: userAgent,
            referer: base + "/",
            artworkKey: key,
            artworkIV: iv,
            categories: categories,
            isEnabled: false
        )
    }
}
