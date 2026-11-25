import Foundation

/// 91porna 网页源适配器。
///
/// 站点把内容分成四块：黑料吃瓜（图文 + 视频）、91视频、AI短剧、91短视频。
/// 每块的列表、详情与播放接口都不一样，分类 id 用 `<类型>|<站点路径>` 编码，
/// 这样同一个 provider 就能按类型路由。
struct NinetyOnePornaCatalogProvider: CatalogProvider {

    // MARK: - 默认值

    static let defaultBaseURL = "https://91porna.com"
    static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    /// 站点图片是 AES-128-CBC 加密的二进制，密钥与 91吃瓜一致。
    static let imageKey = "f5d965df75336270"
    static let imageIV = "97b60394abc2fbe1"

    /// 仅在没有网络时用于渲染侧边栏骨架；结构与站点顶部导航一一对应。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "group:porna:91视频", title: "91视频", children: [
            CatalogCategory(id: "comic|/comic/index/video?category=now_month_hot",
                            title: "热门排行榜"),
            CatalogCategory(id: "comic|/comic/index/video?category=original", title: "国产原创"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=吃瓜+黑料+爆料", title: "吃瓜爆料"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=熟女", title: "熟女做爱"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=萝莉", title: "可爱萝莉"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=动漫", title: "成人动漫"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=黑人", title: "大屌黑人"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=巨乳", title: "童颜巨乳"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=换妻", title: "少妇换妻"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=内射", title: "内射中出"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=按摩", title: "会所按摩"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=探花", title: "91探花"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=家庭乱伦", title: "家庭乱伦"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=三级片", title: "三级片")
        ], isGroup: true),
        CatalogCategory(id: "group:porna:91AI短剧", title: "91AI短剧", children: [
            CatalogCategory(id: "ai|/ai/chengren-duanju", title: "成人短剧"),
            CatalogCategory(id: "ai|/ai/chengren-manju", title: "成人漫剧"),
            CatalogCategory(id: "ai|/ai/ai-mogai", title: "AI魔改")
        ], isGroup: true),
        CatalogCategory(id: "group:porna:91短视频", title: "91短视频", children: [
            CatalogCategory(id: "melon|/melonshort/amateur", title: "素人自拍"),
            CatalogCategory(id: "melon|/melonshort/hunjian", title: "高燃混剪"),
            CatalogCategory(id: "melon|/melonshort/fancha", title: "反差系列"),
            CatalogCategory(id: "melon|/melonshort/wanghong", title: "网红达人"),
            CatalogCategory(id: "melon|/melonshort/mingxing", title: "明星大瓜"),
            CatalogCategory(id: "melon|/melonshort/zipai", title: "原创自拍")
        ], isGroup: true),
        CatalogCategory(id: "group:porna:黑料吃瓜", title: "黑料吃瓜", children: [
            CatalogCategory(id: "hc|/黑料吃瓜/今日吃瓜/最新", title: "今日吃瓜"),
            CatalogCategory(id: "hc|/黑料吃瓜/学生校园/推荐", title: "学生校园"),
            CatalogCategory(id: "hc|/黑料吃瓜/明星黑料/推荐", title: "明星黑料"),
            CatalogCategory(id: "hc|/黑料吃瓜/网红黑料/推荐", title: "网红黑料"),
            CatalogCategory(id: "hc|/黑料吃瓜/每日大赛/推荐", title: "每日大赛"),
            CatalogCategory(id: "hc|/黑料吃瓜/名人合集/推荐", title: "名人合集")
        ], isGroup: true),
        CatalogCategory(id: "group:porna:日本AV", title: "日本AV", children: [
            CatalogCategory(id: "comic|/comic/av/relvideo?model=1&type=theme&order=week",
                            title: "多P群交"),
            CatalogCategory(id: "comic|/comic/av/relvideo?model=12&type=theme&order=week",
                            title: "无码解放"),
            CatalogCategory(id: "comic|/comic/av/relvideo?model=5&type=theme&order=week",
                            title: "中文字幕"),
            CatalogCategory(id: "comic|/comic/av/relvideo?model=6&type=theme&order=week",
                            title: "制服诱惑"),
            CatalogCategory(id: "comic|/comic/av/relvideo?model=107&type=tag&order=week",
                            title: "黑人专区"),
            CatalogCategory(id: "comic|/comic/av/relvideo?model=7&type=theme&order=week",
                            title: "SM调教")
        ], isGroup: true),
        CatalogCategory(id: "group:porna:91动漫", title: "91动漫", children: [
            CatalogCategory(id: "comic|/comic/index/search?keyword=成人动漫", title: "成人动漫"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=日本动漫", title: "日本动漫"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=国产动漫", title: "国产动漫"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=3d动漫", title: "3d动漫"),
            CatalogCategory(id: "comic|/comic/index/search?keyword=同人动漫", title: "同人动漫"),
            CatalogCategory(id: "mslist|/moviesets/category/chengrendongman", title: "动漫合集")
        ], isGroup: true),
        CatalogCategory(id: "group:porna:精选合集", title: "精选合集", children: [
            CatalogCategory(id: "set|/moviesets", title: "最新合集"),
            CatalogCategory(id: "set|/moviesets/rank", title: "排行榜合集"),
            CatalogCategory(id: "set|/moviesets/category", title: "分类合集"),
            CatalogCategory(id: "set|/moviesets/people", title: "人物合集"),
            CatalogCategory(id: "set|/moviesets/brand", title: "品牌合集")
        ], isGroup: true)
    ]

    /// 首页用「今日吃瓜」的最新推荐。
    private static let homeRoute = "hc|/黑料吃瓜/今日吃瓜/推荐"

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        // 顶部导航就是站点真正的分类树：先取首页解析，失败才退回本地骨架。
        if let url = try? URL(string: rootURL(source) + "/"),
           let html = try? await fetchHTML(url, source: source) {
            let live = Self.parseNavGroups(html)
            if !live.isEmpty { return live }
        }
        return source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await listPage(source: source, routeID: Self.homeRoute, page: 1)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        guard page > 1 else { return try await home(source: source) }
        return try await listPage(source: source, routeID: Self.homeRoute, page: page)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        // 站点的主题列表接受 `order=day/week`，这里把排序真正落到地址上。
        let route = Self.applying(sort: sort, to: target.id)
        return try await listPage(source: source, routeID: route, page: page)
    }

    /// 主题列表（`relvideo`）支持按时段排序；其它路由保持站点默认顺序。
    var supportedSorts: [CatalogSort] { [.latest, .hot] }

    static func applying(sort: CatalogSort, to routeID: String) -> String {
        let prefix = "comic|"
        guard routeID.hasPrefix(prefix), routeID.contains("relvideo") else { return routeID }
        let order: String
        switch sort {
        case .hot: order = "week"
        case .latest: order = "day"
        default: return routeID
        }
        var path = String(routeID.dropFirst(prefix.count))
        if let range = path.range(of: #"order=[^&]*"#, options: .regularExpression) {
            path.replaceSubrange(range, with: "order=\(order)")
        } else {
            path += (path.contains("?") ? "&" : "?") + "order=\(order)"
        }
        return prefix + path
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try rootURL(source)
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { throw CatalogError.parse("搜索关键词无效") }
        var address = "\(root)/comic/index/search?keyword=\(encoded)"
        if page > 1 { address += "&page=\(page)" }
        guard let url = URL(string: address) else {
            throw CatalogError.parse("搜索地址无效")
        }
        let html = try await fetchHTML(url, source: source)
        let items = Self.parseMixedCards(html, base: root)
        let hasMore = Self.hasNextPage(html, page: page)
            || Self.expectsURLPage(html, page: page)
            || items.count >= 20
        return CatalogPage(items: items, page: page, hasMore: hasMore)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try rootURL(source)
        let (kind, raw) = Self.splitIdentifier(itemID)

        switch kind {
        case "hc":
            let address = "\(root)/heiliao-chigua/\(raw)"
            guard let url = URL(string: address) else {
                throw CatalogError.parse("详情地址无效")
            }
            let html = try await fetchHTML(url, source: source)
            let title = Self.firstText([#"<h1[^>]*>([\s\S]*?)</h1>"#], in: html)
                .map(CatalogHTML.stripTags) ?? "黑料吃瓜 \(raw)"
            let cover = Self.articleCover(html, base: root)
            let blocks = Self.parseRichContent(html, base: root)
            let item = CatalogItem(id: itemID, title: title,
                                   coverURL: cover, remark: "", categoryID: nil)
            return CatalogDetail(item: item,
                                 episodes: [CatalogEpisode(index: 1, pageURL: address)],
                                 blocks: blocks)

        case "comic":
            let address = "\(root)\(raw)"
            guard let url = URL(string: address) else {
                throw CatalogError.parse("详情地址无效")
            }
            let html = try await fetchHTML(url, source: source)
            let title = Self.firstText([#"<h1[^>]*>([\s\S]*?)</h1>"#], in: html)
                .map(CatalogHTML.stripTags) ?? "91视频 \(raw)"
            // og:image 的签名常常已经过期，拿不到就回退到列表里的封面。
            let cover = Self.freshMetaCover(html)
            let synopsis = Self.metaContent(html, name: "description")
            // avdetail / detail 都通过同一个 embed 播放页出视频。
            let embed = Self.metaContent(html, property: "og:video")
            let episodePage = embed.isEmpty ? address : embed
            let item = CatalogItem(id: itemID, title: title, coverURL: cover,
                                   remark: "", categoryID: nil)
            return CatalogDetail(item: item,
                                 episodes: [CatalogEpisode(index: 1, pageURL: episodePage)],
                                 blocks: Self.paragraphBlocks(synopsis))

        case "ai":
            let address = "\(root)/ai/\(raw)"
            guard let url = URL(string: address) else {
                throw CatalogError.parse("详情地址无效")
            }
            let html = try await fetchHTML(url, source: source)
            let title = Self.firstText([#"<h1[^>]*>([\s\S]*?)</h1>"#], in: html)
                .map(CatalogHTML.stripTags) ?? "AI短剧 \(raw)"
            let cover = Self.pageCover(html, base: root)
            let synopsis = Self.firstText([#"id="ai-synopsis"[^>]*>([\s\S]*?)</p>"#], in: html)
                .map(CatalogHTML.stripTags) ?? Self.metaContent(html, name: "description")
            var seen = Set<Int>()
            let episodes: [CatalogEpisode] = CatalogHTML.fullMatches(
                #"<a href="(/ai/[^"]+/episode-(\d+))"[^>]*>[\s\S]*?</a>"#, in: html)
                .compactMap { anchor in
                    guard let path = CatalogHTML.first(#"href="([^"]+)""#, in: anchor),
                          let numberText = CatalogHTML.first(#"episode-(\d+)""#, in: anchor),
                          let number = Int(numberText),
                          seen.insert(number).inserted else { return nil }
                    let fixed = CatalogHTML.fixURL(path, base: root)
                    return CatalogEpisode(index: number, pageURL: fixed, coverURL: cover)
                }
                .sorted { $0.index < $1.index }
            let item = CatalogItem(id: itemID, title: title, coverURL: cover,
                                   remark: "", categoryID: nil)
            return CatalogDetail(item: item, episodes: episodes,
                                 blocks: Self.paragraphBlocks(synopsis))

        case "melon":
            let address = "\(root)/melonshort/video/\(raw)"
            guard let url = URL(string: address) else {
                throw CatalogError.parse("详情地址无效")
            }
            let html = try await fetchHTML(url, source: source)
            let title = Self.firstText([#"<h1[^>]*>([\s\S]*?)</h1>"#], in: html)
                .map(CatalogHTML.stripTags) ?? "短视频 \(raw)"
            let cover = Self.pageCover(html, base: root)
            let synopsis = Self.metaContent(html, name: "description")
            let item = CatalogItem(id: itemID, title: title, coverURL: cover,
                                   remark: "", categoryID: nil)
            return CatalogDetail(item: item,
                                 episodes: [CatalogEpisode(index: 1, pageURL: address)],
                                 blocks: Self.paragraphBlocks(synopsis))

        case "set":
            let address = "\(root)\(raw)"
            guard let url = URL(string: address) else {
                throw CatalogError.parse("详情地址无效")
            }
            let html = try await fetchHTML(url, source: source)
            let title = Self.firstText([#"<h1[^>]*>([\s\S]*?)</h1>"#], in: html)
                .map(CatalogHTML.stripTags)
                ?? Self.metaContent(html, property: "og:title")
            let cover = Self.pageCover(html, base: root)
            let synopsis = Self.metaContent(html, name: "description")
            let total = Self.collectionTotal(in: title)
            var episodes = Self.parseSetVideos(html, base: root)
            var seen = Set(episodes.map(\.pageURL))
            // 合集本身是分页的：先按「共 N 部」估算需要的页数，够了就停，避免盲翻 8 页。
            let perPage = max(episodes.count, 1)
            var page = 2
            while page <= 40 {
                if let total, episodes.count >= total { break }
                if let total {
                    let needed = Int(ceil(Double(total) / Double(perPage)))
                    if page > needed { break }
                }
                guard let nextURL = URL(string: "\(address)/\(page)"),
                      let nextHTML = try? await fetchHTML(nextURL, source: source) else { break }
                let more = Self.parseSetVideos(nextHTML, base: root)
                guard !more.isEmpty else { break }
                let fresh = more.filter { seen.insert($0.pageURL).inserted }
                guard !fresh.isEmpty else { break }
                episodes.append(contentsOf: fresh)
                // 本页没取满说明已经到底了。
                if more.count < perPage { break }
                page += 1
            }
            // 跨页去重后重新编号，保证「第 N 部」连续。
            episodes = episodes.enumerated().map { offset, episode in
                var value = episode
                value.index = offset + 1
                return value
            }
            // og:image 常常是站点通用图，合集封面改用第一段视频的封面。
            let itemCover = cover.contains("og_cover") || cover.isEmpty
                ? (episodes.first?.coverURL ?? cover)
                : cover
            let totalCount = total ?? episodes.count
            var facts: [CatalogDetailFact] = [
                CatalogDetailFact(label: "视频数量", value: "\(totalCount) 部")
            ]
            if episodes.count < totalCount {
                facts.append(CatalogDetailFact(label: "已加载",
                                               value: "\(episodes.count) 部"))
            }
            let item = CatalogItem(id: itemID, title: title.isEmpty ? "合集" : title,
                                   coverURL: itemCover, remark: "", categoryID: nil)
            return CatalogDetail(item: item, episodes: episodes,
                                 blocks: Self.paragraphBlocks(synopsis),
                                 facts: facts,
                                 isCollection: true,
                                 collectionTotal: totalCount)

        default:
            throw CatalogError.parse("未知的条目类型")
        }
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        let root = try rootURL(source)
        let page = episode.pageURL

        if page.contains("/heiliao-chigua/") {
            return try await postPlayback(source: source, root: root, pageURL: page)
        }
        if page.contains("/comic/index/embed") {
            return try await comicEmbedPlayback(source: source, root: root, pageURL: page)
        }
        if page.contains("/comic/index/detail") || page.contains("/comic/index/avdetail") {
            // 详情页兜底：优先跳到 embed 播放页，拿不到再用 video_key 直接请求。
            if let url = URL(string: page),
               let html = try? await fetchHTML(url, source: source) {
                let embed = Self.metaContent(html, property: "og:video")
                if !embed.isEmpty {
                    return try await comicEmbedPlayback(source: source, root: root,
                                                        pageURL: embed)
                }
            }
            guard let key = Self.queryValue(page, name: "video_key") else {
                throw CatalogError.parse("视频编号缺失")
            }
            return try await videoPlayback(source: source, root: root,
                                           videoID: key, referer: page)
        }
        if page.contains("/melonshort/video/") {
            let videoID = page.split(separator: "/").last.map(String.init) ?? ""
            guard !videoID.isEmpty else { throw CatalogError.parse("视频编号缺失") }
            return try await videoPlayback(source: source, root: root,
                                           videoID: videoID, referer: page)
        }
        if page.contains("/ai/"), page.contains("/episode-") {
            return try await aiEpisodePlayback(source: source, pageURL: page)
        }
        throw CatalogError.parse("无法识别的播放地址")
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        guard let url = URL(string: CatalogHTML.fixURL(urlString, base: source.baseURL)) else {
            throw CatalogError.parse("封面地址无效")
        }
        let data = try await CatalogHTTP.fetchData(url: url, headers: [
            "User-Agent": source.userAgent,
            "Referer": source.referer,
            "Accept": "image/jpeg,image/png,image/*;q=0.8"
        ])
        guard !data.isEmpty else { throw CatalogError.parse("封面为空") }
        return CatalogCrypto.decodeImage(data: data,
                                        key: Self.imageKey,
                                        iv: Self.imageIV) ?? data
    }

    // MARK: - 列表

    private func listPage(source: CatalogSource, routeID: String,
                          page: Int) async throws -> CatalogPage {
        let root = try rootURL(source)
        let (kind, path) = Self.splitIdentifier(routeID)
        guard !path.isEmpty else { throw CatalogError.parse("分类地址无效") }

        let address: String
        switch kind {
        case "hc":
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            address = "\(root)\(encoded)" + (page > 1 ? "?page=\(page)" : "")
        case "comic", "ai":
            // 关键词里可能有中文（如「吃瓜」），拼进 URL 前统一编码一次。
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
            address = "\(root)\(encoded)" + (path.contains("?") ? "&" : "?") + "page=\(page)"
        case "melon", "set", "mslist":
            address = "\(root)\(path)" + (page > 1 ? "/\(page)" : "")
        default:
            throw CatalogError.parse("未知的分类类型")
        }
        guard let url = URL(string: address) else {
            throw CatalogError.parse("分类地址无效")
        }
        let html = try await fetchHTML(url, source: source)

        let items: [CatalogItem]
        switch kind {
        case "hc": items = Self.parsePostCards(html, base: root)
        case "comic": items = Self.parseComicCards(html, base: root)
        case "ai": items = Self.parseDramaCards(html, base: root)
        case "set": items = Self.parseSetCards(html, base: root)
        case "mslist": items = Self.parseMoviesetVideoCards(html, base: root)
        default: items = Self.parseMelonCards(html, base: root)
        }

        let hasMore: Bool
        if kind == "ai" {
            // AI 列表不给页码链接，用「本页是否满 20 条」兜底。
            hasMore = items.count >= 20
        } else if kind == "set" || kind == "mslist" {
            hasMore = html.range(of: "\(path)/\(page + 1)") != nil || items.count >= 20
        } else {
            hasMore = Self.hasNextPage(html, page: page)
                || Self.expectsURLPage(html, page: page)
                || items.count >= 20
        }
        return CatalogPage(items: items, page: page, hasMore: hasMore)
    }

    // MARK: - 解析：顶部导航

    /// 站点导航结构：
    /// `<li class="flex video-nav-dropdown"><a class="app-nav-item" …>标题</a>
    /// <div class="video-sub-menu"><a class="video-sub-item" …>子项</a>…</div></li>`。
    static func parseNavGroups(_ html: String) -> [CatalogCategory] {
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<li class="flex video-nav-dropdown""#, in: html) {
            guard let rawTitle = CatalogHTML.first(
                #"<a class="app-nav-item[^"]*"[\s\S]*?>([\s\S]*?)</a>"#, in: block),
                !rawTitle.isEmpty else { continue }
            let title = CatalogHTML.stripTags(rawTitle)
            guard !title.isEmpty else { continue }

            let menu = CatalogHTML.first(#"<div class="video-sub-menu">([\s\S]*?)</div>"#,
                                         in: block) ?? ""
            var children: [CatalogCategory] = []
            var childSeen = Set<String>()
            for anchor in CatalogHTML.fullMatches(
                #"<a class="video-sub-item"[^>]*>[\s\S]*?</a>"#, in: menu) {
                guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: anchor),
                      let route = routeID(from: href) else { continue }
                let name = CatalogHTML.stripTags(anchor)
                guard !name.isEmpty, childSeen.insert(route).inserted else { continue }
                children.append(CatalogCategory(id: route, title: name))
            }
            guard children.count >= 2, seen.insert(title).inserted else { continue }
            result.append(CatalogCategory(id: "group:porna:\(title)", title: title,
                                          children: children, isGroup: true))
        }
        return result
    }

    /// 把站点导航地址折叠成 `类型|路径`。
    /// 小说、外链、品牌页没有可播放的列表，直接跳过。
    static func routeID(from href: String) -> String? {
        guard !href.lowercased().hasPrefix("http") else { return nil }
        let decoded = href.removingPercentEncoding ?? href
        guard decoded.hasPrefix("/") else { return nil }
        if decoded.hasPrefix("/comic/index/links") { return nil }
        if decoded.hasPrefix("/comic/") { return "comic|\(decoded)" }
        if decoded == "/ai" || decoded.hasPrefix("/ai/") { return "ai|\(decoded)" }
        if decoded.hasPrefix("/melonshort") { return "melon|\(decoded)" }
        if decoded.hasPrefix("/moviesets") {
            // 带具体合集 slug 的地址本身就是视频列表；其余是「合集索引」。
            let parts = decoded.split(separator: "/").filter { !$0.isEmpty }
            if parts.count >= 3 { return "mslist|\(decoded)" }
            return "set|\(decoded)"
        }
        if decoded.contains("黑料吃瓜") { return "hc|\(decoded)" }
        return nil
    }

    // MARK: - 解析：列表卡片

    /// 黑料吃瓜：`<a href="/heiliao-chigua/{id}"><article>…</article></a>`。
    static func parsePostCards(_ html: String, base: String) -> [CatalogItem] {
        let blocks = CatalogHTML.fullMatches(
            #"<a href="/heiliao-chigua/\d+"[\s\S]*?</a>"#, in: html)
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in blocks {
            guard let slug = CatalogHTML.first(#"href="/heiliao-chigua/(\d+)""#, in: block),
                  seen.insert(slug).inserted else { continue }
            let title = CatalogHTML.first(#"post-item-title"[^>]*>([\s\S]*?)</h2>"#, in: block)
                .map(CatalogHTML.stripTags) ?? ""
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"data-src="([^"]+)""#, in: block) ?? ""
            let date = CatalogHTML.first(#"<span>(\d{4}-\d{2}-\d{2})</span>"#, in: block) ?? ""
            result.append(CatalogItem(id: "hc|\(slug)", title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: date, categoryID: nil))
        }
        return result
    }

    /// 91视频：`<div class="video-item">`。列表与搜索结果的分页结构略有差异，
    /// 所以按卡片开头切片，而不是依赖外层 `<li>` 的具体写法。
    static func parseComicCards(_ html: String, base: String) -> [CatalogItem] {
        let blocks = CatalogHTML.blocks(#"<div class="video-item""#, in: html)
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in blocks {
            guard let path = CatalogHTML.first(
                #"href="(/comic/index/(?:detail|avdetail)\?video_key=[^"]+)""#, in: block),
                seen.insert(path).inserted else { continue }
            let alt = CatalogHTML.first(#"alt="([^"]*)""#, in: block) ?? ""
            let title = alt.isEmpty
                ? (CatalogHTML.first(#"(?:line-clamp-2|line-clamp-1)[^"]*"[^>]*>([\s\S]*?)</(?:div|h2)>"#,
                                     in: block)
                    .map(CatalogHTML.stripTags) ?? "")
                : alt
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"data-src="([^"]+)""#, in: block) ?? ""
            let duration = CatalogHTML.first(#"rounded-large text-white">\s*([^<]*)</div>"#,
                                             in: block) ?? ""
            result.append(CatalogItem(id: "comic|\(path)", title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: duration.trimmingCharacters(in: .whitespacesAndNewlines),
                                      categoryID: nil))
        }
        return result
    }

    /// AI短剧：`<a class="drama-card">`，封面 + 更新集数 + 评分。
    static func parseDramaCards(_ html: String, base: String) -> [CatalogItem] {
        let blocks = CatalogHTML.fullMatches(
            #"<a class="drama-card"[\s\S]*?</a>"#, in: html)
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in blocks {
            guard let slug = CatalogHTML.first(#"href="/ai/(\d+-[^"]+)""#, in: block),
                  seen.insert(slug).inserted else { continue }
            var title = CatalogHTML.first(#"title="([^"]*)""#, in: block) ?? ""
            if title.isEmpty {
                title = CatalogHTML.first(#"<h3[^>]*>([\s\S]*?)</h3>"#, in: block)
                    .map(CatalogHTML.stripTags) ?? ""
            }
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"data-src="([^"]+)""#, in: block) ?? ""
            let eps = CatalogHTML.first(#"drama-card__eps">([\s\S]*?)<br>"#, in: block)
                .map(CatalogHTML.stripTags)
                ?? CatalogHTML.first(#"drama-card__eps">([\s\S]*?)</span>"#, in: block)
                .map(CatalogHTML.stripTags) ?? ""
            let score = CatalogHTML.first(#"drama-score">([^<]*)</span>"#, in: block) ?? ""
            let remark = [eps, score].filter { !$0.isEmpty }.joined(separator: " · ")
            result.append(CatalogItem(id: "ai|\(slug)", title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: remark, categoryID: nil))
        }
        return result
    }

    /// 91短视频：`<article class="video-card">`。
    static func parseMelonCards(_ html: String, base: String) -> [CatalogItem] {
        let blocks = CatalogHTML.fullMatches(
            #"<article class="video-card"[\s\S]*?</article>"#, in: html)
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in blocks {
            guard let id = CatalogHTML.first(#"href="/melonshort/video/(\d+)""#, in: block),
                  seen.insert(id).inserted else { continue }
            var title = CatalogHTML.first(#"title="([^"]*)""#, in: block) ?? ""
            if title.isEmpty {
                title = CatalogHTML.first(#"<h3[^>]*class="title"[^>]*>([\s\S]*?)</h3>"#, in: block)
                    .map(CatalogHTML.stripTags) ?? ""
            }
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"data-src="([^"]+)""#, in: block) ?? ""
            let duration = CatalogHTML.first(#"badge-duration"[^>]*>([\s\S]*?)</span>"#, in: block)
                .map(CatalogHTML.stripTags) ?? ""
            result.append(CatalogItem(id: "melon|\(id)", title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: duration, categoryID: nil))
        }
        return result
    }

    /// 精选合集：`<a class="ms-card" href="/moviesets/category/xxx">`，点进去是一组视频。
    static func parseSetCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<a class="ms-card"#, in: html) {
            guard let path = CatalogHTML.first(#"href="(/moviesets/[^"]+)""#, in: block),
                  seen.insert(path).inserted else { continue }
            let title = CatalogHTML.first(#"card-name[^>]*>([\s\S]*?)</h3>"#, in: block)
                .map(CatalogHTML.stripTags)
                ?? CatalogHTML.first(#"alt="([^"]*)""#, in: block) ?? ""
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"data-src="([^"]+)""#, in: block) ?? ""
            let count = (CatalogHTML.first(#"视频数量：\s*([^<]+)"#, in: block) ?? "")
                .trimmingCharacters(in: .whitespaces)
            result.append(CatalogItem(id: "set|\(path)", title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: count.isEmpty ? "合集" : "\(count) 部",
                                      categoryID: nil))
        }
        return result
    }

    /// 具体合集页：卡片是 `video-item--moviesets`，链接直接指向视频详情。
    static func parseMoviesetVideoCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<div class="video-item video-item--moviesets""#,
                                        in: html) {
            guard let path = CatalogHTML.first(
                #"href="(/comic/index/(?:detail|avdetail)\?video_key=[^"]+)""#, in: block),
                seen.insert(path).inserted else { continue }
            let title = CatalogHTML.first(#"alt="([^"]*)""#, in: block) ?? ""
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"data-src="([^"]+)""#, in: block) ?? ""
            let duration = CatalogHTML.first(#">\s*(\d+:\d+(?::\d+)?)\s*<"#, in: block) ?? ""
            result.append(CatalogItem(id: "comic|\(path)", title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: duration, categoryID: nil))
        }
        return result
    }

    /// 合集详情页里的视频卡片：合集内的视频彼此独立，标题与时长都保留下来。
    static func parseSetVideos(_ html: String, base: String,
                               startIndex: Int = 1) -> [CatalogEpisode] {
        var result: [CatalogEpisode] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<div class="video-item video-item--moviesets""#,
                                        in: html) {
            guard let path = CatalogHTML.first(
                #"href="(/comic/index/(?:detail|avdetail)\?video_key=[^"]+)""#, in: block),
                seen.insert(path).inserted else { continue }
            let name = CatalogHTML.first(#"alt="([^"]*)""#, in: block) ?? ""
            let duration = CatalogHTML.first(#">\s*((?:\d+分)?\d+:\d+(?::\d+)?)\s*<"#,
                                             in: block) ?? ""
            result.append(CatalogEpisode(index: startIndex + result.count,
                                         pageURL: CatalogHTML.fixURL(path, base: base),
                                         coverURL: CatalogHTML.fixURL(
                                            CatalogHTML.first(#"data-src="([^"]+)""#, in: block) ?? "",
                                            base: base),
                                         name: name.isEmpty ? nil : name,
                                         duration: duration.isEmpty ? nil : duration))
        }
        return result
    }

    /// h1 里常带「（共 185 部）」。
    static func collectionTotal(in title: String) -> Int? {
        CatalogHTML.first(#"共\s*(\d+)\s*部"#, in: title).flatMap(Int.init)
    }

    /// 搜索页可能混排多种卡片，四种一起取并按 id 去重。
    static func parseMixedCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for item in parseComicCards(html, base: base)
            + parsePostCards(html, base: base)
            + parseDramaCards(html, base: base)
            + parseMelonCards(html, base: base) where seen.insert(item.id).inserted {
            result.append(item)
        }
        return result
    }

    // MARK: - 解析：正文

    /// 黑料吃瓜正文：`<article class="ql-editor">` 里图文交替，图片是 `data-src`。
    static func parseRichContent(_ html: String, base: String) -> [CatalogContentBlock] {
        guard let start = html.range(of: "<article")?.lowerBound else { return [] }
        var scope = String(html[start...])
        if let end = scope.range(of: "</article>")?.lowerBound {
            scope = String(scope[..<end])
        }
        for pattern in [#"<script[\s\S]*?</script>"#,
                        #"<style[\s\S]*?</style>"#,
                        #"<blockquote[\s\S]*?</blockquote>"#,
                        #"<table[\s\S]*?</table>"#,
                        #"<div class="ql-video[\s\S]*?</div>"#] {
            scope = scope.replacingOccurrences(of: pattern, with: "",
                                               options: .regularExpression)
        }

        var result: [CatalogContentBlock] = []
        var seenText = Set<String>()
        var seenImages = Set<String>()

        func appendImages(in raw: String) {
            for tag in CatalogHTML.fullMatches(#"<img[^>]*>"#, in: raw) {
                let rawURL = CatalogHTML.first(#"data-src="([^"]+)""#, in: tag)
                    ?? CatalogHTML.first(#"src="([^"]+)""#, in: tag)
                    ?? ""
                let url = CatalogHTML.fixURL(rawURL, base: base)
                guard url.hasPrefix("http"), looksLikeImage(url),
                      seenImages.insert(url).inserted else { continue }
                result.append(CatalogContentBlock(kind: .image, text: url))
            }
        }

        let tokenPattern = #"<(h2|h3|p|figure)(?:\s[^>]*)?>[\s\S]*?</\1>|<img[^>]*>"#
        for raw in CatalogHTML.fullMatches(tokenPattern, in: scope) {
            if raw.hasPrefix("<img") {
                appendImages(in: raw)
                continue
            }
            if raw.hasPrefix("<h2") || raw.hasPrefix("<h3") {
                let text = CatalogHTML.stripTags(raw)
                guard text.count >= 2, seenText.insert(text).inserted else { continue }
                result.append(CatalogContentBlock(kind: .heading, text: text))
                continue
            }
            let textHTML = raw.replacingOccurrences(of: #"<img[^>]*>"#, with: "",
                                                    options: .regularExpression)
            let text = CatalogHTML.stripTags(textHTML)
            if text.count >= 8, seenText.insert(text).inserted {
                result.append(CatalogContentBlock(kind: .paragraph, text: text))
            }
            appendImages(in: raw)
        }
        return result
    }

    private static func paragraphBlocks(_ text: String) -> [CatalogContentBlock] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [CatalogContentBlock(kind: .paragraph, text: trimmed)]
    }

    // MARK: - 播放

    /// 黑料吃瓜：先取详情页里的 post id，再请求 `/api/posts/{id}/playback`。
    private func postPlayback(source: CatalogSource, root: String,
                              pageURL: String) async throws -> CatalogStream {
        guard let page = URL(string: pageURL) else {
            throw CatalogError.parse("播放页地址无效")
        }
        let html = try await fetchHTML(page, source: source)

        let postID: String
        if let value = CatalogHTML.first(#"data-playback-post="(\d+)""#, in: html) {
            postID = value
        } else if let key = Self.queryValue(pageURL, name: "video_key") {
            return try await videoPlayback(source: source, root: root,
                                           videoID: key, referer: pageURL)
        } else {
            throw CatalogError.parse("没有找到播放地址")
        }

        let api = "\(root)/api/posts/\(postID)/playback"
        let json = try await postJSON(api, source: source, referer: pageURL)
        guard let data = json["data"] as? [String: Any],
              let videos = data["videos"] as? [[String: Any]],
              let raw = videos.first?["url"] as? String else {
            throw CatalogError.parse("播放接口没有返回视频")
        }
        return try makeStream(raw, pageURL: pageURL, cdn: data["cdn"],
                              userAgent: source.userAgent)
    }

    /// 91视频播放页：`<video data-playback-id="…">` → `/api/videos/{id}/playback`。
    private func comicEmbedPlayback(source: CatalogSource, root: String,
                                    pageURL: String) async throws -> CatalogStream {
        guard let page = URL(string: pageURL) else {
            throw CatalogError.parse("播放页地址无效")
        }
        let html = try await fetchHTML(page, source: source)
        let videoID = CatalogHTML.first(#"data-playback-id="([^"]+)""#, in: html)
            ?? Self.queryValue(pageURL, name: "id")
            ?? ""
        guard !videoID.isEmpty else {
            throw CatalogError.parse("播放页里没有视频编号")
        }
        return try await videoPlayback(source: source, root: root,
                                       videoID: videoID, referer: pageURL)
    }

    /// 91视频 / 91短视频：`/api/videos/{id}/playback` 返回 `streams.main`。
    private func videoPlayback(source: CatalogSource, root: String,
                               videoID: String, referer: String) async throws -> CatalogStream {
        let api = "\(root)/api/videos/\(videoID)/playback"
        let json = try await postJSON(api, source: source, referer: referer)
        guard let data = json["data"] as? [String: Any],
              let streams = data["streams"] as? [String: Any],
              let raw = (streams["main"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
                ?? (streams["preview"] as? String) else {
            throw CatalogError.parse("播放接口没有返回视频")
        }
        return try makeStream(raw, pageURL: referer, cdn: data["cdn"],
                              userAgent: source.userAgent)
    }

    /// AI短剧：单集页里的 `ai-play-boot` JSON 自带 m3u8 与分集列表。
    private func aiEpisodePlayback(source: CatalogSource, pageURL: String) async throws -> CatalogStream {
        guard let page = URL(string: pageURL) else {
            throw CatalogError.parse("播放页地址无效")
        }
        let html = try await fetchHTML(page, source: source)
        guard let jsonText = CatalogHTML.first(
            #"<script id="ai-play-boot" type="application/json">([\s\S]*?)</script>"#,
            in: html),
            let data = jsonText.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let playlist = root["playlist"] as? [[String: Any]] else {
            throw CatalogError.parse("没有找到 AI 短剧播放列表")
        }
        let current = (root["current"] as? Int) ?? 1
        let entry = playlist.first(where: { ($0["ep"] as? Int) == current }) ?? playlist.first
        guard let raw = entry?["play"] as? String, !raw.isEmpty else {
            throw CatalogError.parse("该集没有播放地址")
        }
        return try makeStream(raw, pageURL: pageURL, cdn: nil,
                              userAgent: source.userAgent)
    }

    private func makeStream(_ raw: String, pageURL: String, cdn: Any?,
                            userAgent: String) throws -> CatalogStream {
        guard let streamURL = URL(string: CatalogHTML.fixURL(raw, base: "")) else {
            throw CatalogError.parse("视频地址解析失败")
        }
        var headers: [String: String] = [
            "User-Agent": userAgent,
            "Referer": pageURL
        ]
        if let cdn = cdn as? [String: Any],
           let key = cdn["authKey"] as? String, !key.isEmpty,
           let value = cdn["authValue"] as? String, !value.isEmpty,
           let app = cdn["app"] as? String, !app.isEmpty {
            headers[key] = value
            headers["x-cdn-app"] = app
        }
        return CatalogStream(url: streamURL, headers: headers, isHLS: true)
    }

    private func postJSON(_ address: String, source: CatalogSource,
                          referer: String) async throws -> [String: Any] {
        guard let url = URL(string: address) else {
            throw CatalogError.parse("接口地址无效")
        }
        let data = try await CatalogHTTP.postJSON(url: url, headers: [
            "User-Agent": source.userAgent,
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
            "Referer": referer
        ], body: Data("{}".utf8))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.parse("播放接口返回格式异常")
        }
        return json
    }

    // MARK: - 导入

    /// 从站点地址创建源：补协议、去掉路径，用内置的四块内容作为分类骨架。
    static func importSource(from address: String) async throws -> CatalogSource {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CatalogError.invalidConfig("地址为空") }
        var raw = trimmed
        if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
        guard var comps = URLComponents(string: raw), let host = comps.host, !host.isEmpty
        else {
            throw CatalogError.invalidConfig("地址无法识别")
        }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        guard let base = comps.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        else { throw CatalogError.invalidConfig("地址无法识别") }

        var categories = defaultCategories
        let probe = CatalogSource(name: "91porna", kind: .ninetyOnePorna,
                                  baseURL: base, userAgent: defaultUserAgent,
                                  referer: base + "/", categories: categories)
        if let url = URL(string: base + "/"),
           let html = try? await CatalogHTTP.fetchPage(url: url, source: probe) {
            let live = parseNavGroups(html)
            if !live.isEmpty { categories = live }
        }

        return CatalogSource(name: "91porna",
                             kind: .ninetyOnePorna,
                             baseURL: base,
                             configURL: trimmed,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: categories,
                             posterAspect: 16.0 / 9.0,
                             isEnabled: false)
    }

    // MARK: - 工具

    private func rootURL(_ source: CatalogSource) throws -> String {
        var text = source.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, URL(string: text)?.host != nil else {
            throw CatalogError.invalidConfig("站点地址为空")
        }
        return text
    }

    private func fetchHTML(_ url: URL, source: CatalogSource) async throws -> String {
        try await CatalogHTTP.fetchPage(url: url, source: source)
    }

    static func splitIdentifier(_ id: String) -> (kind: String, path: String) {
        guard let separator = id.firstIndex(of: "|") else { return ("", id) }
        return (String(id[..<separator]), String(id[id.index(after: separator)...]))
    }

    private static func firstText(_ patterns: [String], in text: String) -> String? {
        for pattern in patterns {
            if let value = CatalogHTML.first(pattern, in: text) { return value }
        }
        return nil
    }

    private static func metaContent(_ html: String, property: String) -> String {
        CatalogHTML.first(#"<meta[^>]+property="\#(property)"[^>]+content="([^"]+)""#, in: html)
            ?? CatalogHTML.first(#"<meta[^>]+content="([^"]+)"[^>]+property="\#(property)""#, in: html)
            ?? ""
    }

    private static func metaContent(_ html: String, name: String) -> String {
        CatalogHTML.first(#"<meta[^>]+name="\#(name)"[^>]+content="([^"]+)""#, in: html)
            ?? CatalogHTML.first(#"<meta[^>]+content="([^"]+)"[^>]+name="\#(name)""#, in: html)
            ?? ""
    }

    private static func looksLikeImage(_ url: String) -> Bool {
        let path = url.split(separator: "?").first.map(String.init)?.lowercased() ?? url
        return [".jpg", ".jpeg", ".png", ".webp", ".gif"].contains { path.hasSuffix($0) }
    }

    /// 页码链接（`?page=N` 或 `/N`）是否出现。
    static func hasNextPage(_ html: String, page: Int) -> Bool {
        html.range(of: "page=\(page + 1)") != nil
    }

    /// 短视频分类用路径分页：`/melonshort/amateur/3`。
    static func expectsURLPage(_ html: String, page: Int) -> Bool {
        let next = page + 1
        return CatalogHTML.first(#"href="/melonshort/[^"/]+/\#(next)""#, in: html) != nil
    }

    private static func queryValue(_ urlString: String, name: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    // MARK: - 封面取新

    /// 站点图片的 `auth` / `auth_key` 第一段是过期时间戳；过期后请求会返回空响应。
    private static func isFreshToken(_ url: String) -> Bool {
        guard !url.isEmpty, let comps = URLComponents(string: url),
              let token = comps.queryItems?.first(where: {
                  $0.name == "auth" || $0.name == "auth_key"
              })?.value,
              let stamp = Double(token.split(separator: "-").first ?? "") else { return false }
        return stamp > Date().timeIntervalSince1970 + 10
    }

    private static func firstDataImage(_ html: String, base: String) -> String {
        guard let raw = CatalogHTML.first(#"data-src="(https?://[^"]+)""#, in: html)
        else { return "" }
        return CatalogHTML.fixURL(raw, base: base)
    }

    /// 详情页封面：优先页内的新图，其次才是 og:image。
    private static func pageCover(_ html: String, base: String) -> String {
        let first = firstDataImage(html, base: base)
        if isFreshToken(first) { return first }
        let og = metaContent(html, property: "og:image")
        if isFreshToken(og) { return og }
        return first
    }

    /// 黑料吃瓜：正文第一张图最贴近内容。
    private static func articleCover(_ html: String, base: String) -> String {
        var scope = html
        if let start = html.range(of: "<article")?.lowerBound {
            scope = String(html[start...])
        }
        let first = firstDataImage(scope, base: base)
        if isFreshToken(first) { return first }
        return pageCover(html, base: base)
    }

    /// 91视频的 og:image 经常已过期，过期时交给列表封面兜底。
    private static func freshMetaCover(_ html: String) -> String {
        let og = metaContent(html, property: "og:image")
        return isFreshToken(og) ? og : ""
    }
}
