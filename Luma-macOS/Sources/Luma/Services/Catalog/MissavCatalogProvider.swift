import Foundation

/// MissAV（`missav.ws` / `missav.live`）适配器。
///
/// - 列表：卡片是 `<div class="thumbnail group">`，封面在 `fourhoi.com`，分页 `?page=N`。
/// - 详情：`<h1>` 标题 + `og:image` 封面 + 女优 / 类型链接。
/// - 播放：站点把 m3u8 放进一段用 Dean Edwards packer 压缩的脚本里，需要先还原再取地址。
struct MissavCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://missav.live"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    /// 顶部导航：四个下拉分组 + 独立的「中文字幕」入口。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "group:missav:jav", title: "观看日本 AV", children: [
            CatalogCategory(id: "dm539/new", title: "最近更新"),
            CatalogCategory(id: "dm635/release", title: "新作上市"),
            CatalogCategory(id: "dm817/uncensored-leak", title: "无码流出"),
            CatalogCategory(id: "dm301/today-hot", title: "今日热门"),
            CatalogCategory(id: "dm170/weekly-hot", title: "本週热门"),
            CatalogCategory(id: "dm273/monthly-hot", title: "本月热门")
        ], isGroup: true),
        CatalogCategory(id: "group:missav:amateur", title: "素人", children: [
            CatalogCategory(id: "dm36/siro", title: "SIRO"),
            CatalogCategory(id: "dm34/luxu", title: "LUXU"),
            CatalogCategory(id: "dm35/gana", title: "GANA"),
            CatalogCategory(id: "dm1004/maan", title: "PRESTIGE PREMIUM"),
            CatalogCategory(id: "dm38/scute", title: "S-CUTE"),
            CatalogCategory(id: "dm34/ara", title: "ARA")
        ], isGroup: true),
        CatalogCategory(id: "group:missav:uncensored", title: "无码影片", children: [
            CatalogCategory(id: "dm817/uncensored-leak", title: "无码流出"),
            CatalogCategory(id: "dm597/fc2", title: "FC2"),
            CatalogCategory(id: "dm2020563/heyzo", title: "HEYZO"),
            CatalogCategory(id: "dm42/tokyohot", title: "东京热"),
            CatalogCategory(id: "dm4551182/1pondo", title: "一本道"),
            CatalogCategory(id: "dm6840813/caribbeancom", title: "Caribbeancom"),
            CatalogCategory(id: "dm78420/caribbeancompr", title: "Caribbeancompr"),
            CatalogCategory(id: "dm6238706/10musume", title: "10musume"),
            CatalogCategory(id: "dm3240472/pacopacomama", title: "pacopacomama"),
            CatalogCategory(id: "dm150/gachinco", title: "Gachinco"),
            CatalogCategory(id: "dm42/xxxav", title: "XXX-AV"),
            CatalogCategory(id: "dm37/marriedslash", title: "人妻斩"),
            CatalogCategory(id: "dm33/naughty4610", title: "顽皮 4610"),
            CatalogCategory(id: "dm37/naughty0930", title: "顽皮 0930")
        ], isGroup: true),
        CatalogCategory(id: "group:missav:madou", title: "亚洲 AV", children: [
            CatalogCategory(id: "dm63/madou", title: "麻豆传媒"),
            CatalogCategory(id: "dm31/twav", title: "TWAV"),
            CatalogCategory(id: "dm15/furuke", title: "Furuke")
        ], isGroup: true),
        CatalogCategory(id: "dm278/chinese-subtitle", title: "中文字幕")
    ]

    /// 已知镜像：按顺序尝试，哪个能出内容就用哪个。
    /// MissAV 的主域名经常被 Cloudflare 或地区网络拦掉，单域名写死很容易整源不可用。
    /// 顺序按实测结果排：`missav.live` / `missav123.com` 能直接出列表（前者最快），
    /// `missav.ws` / `missav.ai` 目前返回 403 验证页，留作备用镜像。
    /// `missav.com` 只返回一个没有卡片的空页、`missav.vip` 直接 404，都已移除。
    private static let mirrorRoots = [
        "https://missav.live",
        "https://missav123.com",
        "https://missav.ws",
        "https://missav.ai"
    ]

    private static let mirrorLock = NSLock()
    /// 每个源当前可用的镜像：成功一次就记住，下次直接用它。
    private static var workingRoot: [UUID: String] = [:]
    /// 全部镜像都失败后的冷却时间，避免每次点击都重试五个域名。
    private static var failedUntil: [UUID: Date] = [:]

    private static func rememberedRoot(_ source: CatalogSource) -> String? {
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        return workingRoot[source.id]
    }

    private static func remember(_ root: String, for source: CatalogSource) {
        mirrorLock.lock()
        workingRoot[source.id] = root
        failedUntil[source.id] = nil
        mirrorLock.unlock()
    }

    private static func markAllFailed(_ source: CatalogSource) {
        mirrorLock.lock()
        workingRoot[source.id] = nil
        failedUntil[source.id] = Date().addingTimeInterval(30)
        mirrorLock.unlock()
    }

    /// 当前源应该尝试的镜像顺序：记忆中的可用镜像 → 用户填写的地址 → 默认镜像。
    private static func candidateRoots(_ source: CatalogSource) -> [String] {
        var list: [String] = []
        if let cached = rememberedRoot(source) { list.append(cached) }
        if let base = try? WebCatalogSupport.root(source) { list.append(base) }
        list.append(defaultBaseURL)
        list.append(contentsOf: mirrorRoots)
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private static func isChallenge(_ html: String) -> Bool {
        // 正常页面里也可能注入 Cloudflare 的脚本，只有「不像内容页」时才判定为拦截页。
        guard !html.contains("thumbnail group"), !html.contains("missav") else { return false }
        let lower = html.lowercased()
        return lower.contains("just a moment")
            || lower.contains("cf-chl")
            || lower.contains("challenge-platform")
            || lower.contains("attention required")
            || html.count < 1200
    }

    /// 逐个镜像取页：优先用记住的镜像；不行就并行探一遍，
    /// 谁先返回内容就用谁，其余请求立即取消，避免用户干等五个超时。
    private static func fetchHTML(path: String, source: CatalogSource) async throws -> (html: String, root: String) {
        mirrorLock.lock()
        let until = failedUntil[source.id]
        mirrorLock.unlock()
        if let until, until > Date() {
            throw CatalogError.parse("镜像暂时不可用，请稍后重试")
        }

        if let cached = rememberedRoot(source),
           let html = try? await fetchOne(path: path, root: cached, source: source),
           !isChallenge(html) {
            return (html, cached)
        }

        // 镜像竞速只能被「真正拿到内容的镜像」结束：任何一个镜像 403 / 超时 /
        // 返回验证页都不能打断其它镜像。旧写法用 throwing group，第一个报错的
        // 镜像（missav.ws / .ai 常直接 403）会把整个竞速拖垮，明明 missav.live
        // 可用也报「站点暂时不可用 / 需要验证」。这里让每个子任务自己吞掉错误，
        // 只有全部镜像都失败才向上抛。
        let result: (html: String, root: String)? = await withTaskGroup(of: Optional<(html: String, root: String)>.self) { group in
            for root in candidateRoots(source) {
                group.addTask {
                    guard let html = try? await fetchOne(path: path, root: root, source: source),
                          !isChallenge(html) else { return nil }
                    return (html, root)
                }
            }
            for await candidate in group {
                if let candidate {
                    group.cancelAll()
                    return candidate
                }
            }
            return nil
        }
        guard let result else {
            markAllFailed(source)
            throw CatalogError.parse("站点暂时不可用")
        }
        remember(result.root, for: source)
        return result
    }

    /// 单个镜像的请求：7 秒内没回来就让位给其他镜像。
    private static func fetchOne(path: String, root: String,
                                 source: CatalogSource) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await WebCatalogSupport.fetchHTML(root + path,
                                                      source: pageSource(source, root: root))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 7_000_000_000)
                throw CatalogError.parse("镜像请求超时")
            }
            guard let html = try await group.next() else {
                throw CatalogError.parse("镜像请求失败")
            }
            group.cancelAll()
            return html
        }
    }

    /// 站点页请求统一改写成镜像域名的 Referer，避免旧域名把 Cloudflare 校验带进来。
    private static func pageSource(_ source: CatalogSource, root: String) -> CatalogSource {
        var copy = source
        copy.referer = root + "/"
        return copy
    }

    /// 顶部导航的下拉就是二级分组：`/cn` 拿简体中文导航，失败再退回默认语言。
    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        for path in ["/cn", "/"] {
            guard let result = try? await Self.fetchHTML(path: path, source: source) else { continue }
            let live = Self.parseNavGroups(result.html)
            if live.count >= 2 { return live }
        }
        // 老源里存的是没有二级的扁平分类，直接换成带下拉分组的骨架。
        if source.categories.contains(where: { $0.isGroupCategory }) { return source.categories }
        return Self.defaultCategories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let result = try await Self.fetchHTML(path: "/", source: source)
        var items = Self.parseCards(result.html, base: result.root)
        if items.isEmpty {
            // 新首页的推荐位由浏览器端 SDK 填充，静态 HTML 里没有卡片；
            // 退回服务端渲染的「最近更新」，首页仍然能直接用。
            if let fallback = try? await Self.fetchHTML(path: "/dm539/new", source: source) {
                items = Self.parseCards(fallback.html, base: fallback.root)
            }
        }
        return CatalogPage(items: items, page: 1, hasMore: false)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        guard !target.id.isEmpty else { throw CatalogError.parse("分类地址无效") }
        var path = "/\(target.id)"
        if page > 1 { path += "?page=\(page)" }
        let result = try await Self.fetchHTML(path: path, source: source)
        let items = Self.parseCards(result.html, base: result.root)
        return CatalogPage(items: items, page: page,
                           hasMore: WebCatalogSupport.hasNextPage(result.html, page: page)
                               || items.count >= 12)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        guard let encoded = WebCatalogSupport.pathEncoded(keyword)
        else { throw CatalogError.parse("搜索关键词无效") }
        var path = "/search/\(encoded)"
        if page > 1 { path += "?page=\(page)" }
        let result = try await Self.fetchHTML(path: path, source: source)
        let items = Self.parseCards(result.html, base: result.root)
        return CatalogPage(items: items, page: page,
                           hasMore: WebCatalogSupport.hasNextPage(result.html, page: page)
                               || items.count >= 12)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let path = "/\(itemID)"
        let result = try await Self.fetchHTML(path: path, source: source)
        let html = result.html
        let root = result.root
        let address = root + path
        let title = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? ""
        let cover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)

        let actresses = CatalogHTML.fullMatches(
            #"<a[^>]+href="https://[^"]*/actresses/[^"]+"[^>]*>([\s\S]*?)</a>"#, in: html)
            .map(CatalogHTML.stripTags)
            .filter { !$0.isEmpty && !$0.contains("排行") }
        let genres = CatalogHTML.fullMatches(
            #"<a[^>]+href="https://[^"]*/genres/[^"]+"[^>]*>([\s\S]*?)</a>"#, in: html)
            .map(CatalogHTML.stripTags)
        let makers = CatalogHTML.fullMatches(
            #"<a[^>]+href="https://[^"]*/makers/[^"]+"[^>]*>([\s\S]*?)</a>"#, in: html)
            .map(CatalogHTML.stripTags)
        let tags = WebCatalogSupport.unique(actresses + genres + makers)

        var detail = WebCatalogSupport.singleEpisode(
            id: itemID,
            title: title.isEmpty ? itemID : title,
            cover: cover,
            pageURL: address,
            blocks: WebCatalogSupport.tagBlocks(tags)
        )
        // 女优 / 片商写进结构化信息：详情页里可以点进跨源档案。
        let actressNames = WebCatalogSupport.unique(actresses)
        if !actressNames.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "女优",
                                                  value: actressNames.joined(separator: "、")))
        }
        let makerNames = WebCatalogSupport.unique(makers)
        if !makerNames.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "片商",
                                                  value: makerNames.joined(separator: "、")))
        }
        return detail
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        guard URL(string: episode.pageURL) != nil else {
            throw CatalogError.parse("分集地址无效")
        }
        let path = Self.path(from: episode.pageURL)
        let result = try await Self.fetchHTML(path: path, source: source)
        let root = result.root
        var raw = Self.playerSource(result.html)
        if raw == nil,
           let uuid = CatalogHTML.first(#"surrit\.com/([0-9a-fA-F-]{36})"#, in: result.html) {
            raw = "https://surrit.com/\(uuid)/playlist.m3u8"
        }
        guard let raw else { throw CatalogError.parse("该条目没有可播放的视频") }
        var stream = try WebCatalogSupport.stream(raw, base: root,
                                                  referer: root + "/",
                                                  userAgent: source.userAgent)
        // CDN 会检查来源：Referer / Origin 缺一个都可能返回 403。
        stream.headers["Origin"] = root
        return stream
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        // 图片 CDN 也会校验来源，Referer 跟着镜像一起换。
        var probe = source
        if let root = Self.rememberedRoot(source) { probe.referer = root + "/" }
        return try await WebCatalogSupport.coverData(source: probe, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        let probe = CatalogSource(name: "MissAV",
                                  kind: .missav,
                                  baseURL: base,
                                  userAgent: defaultUserAgent,
                                  referer: base + "/",
                                  categories: defaultCategories)
        let result = try await fetchHTML(path: "/", source: probe)
        guard result.html.contains("missav") || result.html.contains("thumbnail group") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        return CatalogSource(name: "MissAV",
                             kind: .missav,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: defaultCategories,
                             posterAspect: 16.0 / 9.0,
                             isEnabled: false)
    }

    /// `https://missav.live/dm31/xxx` → `/dm31/xxx`：播放页地址可能来自旧域名，
    /// 统一换成当前可用镜像的同一路径再取。
    private static func path(from address: String) -> String {
        guard let path = URL(string: address)?.path, !path.isEmpty else { return "/" }
        return path.hasPrefix("/") ? path : "/" + path
    }

    // MARK: - 解析：导航分组

    /// 语言段只是路由（`/dm539/cn/new`、`/cn/actresses`），不属于分类 id。
    private static let languageSegments: Set<String> = [
        "cn", "tc", "en", "ja", "ko", "ms", "th", "de", "fr", "vi", "id", "fil", "pt"
    ]

    static func parseNavGroups(_ html: String) -> [CatalogCategory] {
        var result: [CatalogCategory] = []
        for name in ["jav", "amateur", "uncensored", "madou"] {
            guard let anchor = html.range(of: "showDropdown = '\(name)'") else { continue }
            let tail = String(html[anchor.upperBound...])
            guard let title = CatalogHTML.first(#"<span>([^<]+)</span>"#, in: String(tail.prefix(800))),
                  let bodyStart = tail.range(of: #"<div class="py-1">"#),
                  let bodyEnd = tail.range(of: "</div>", range: bodyStart.upperBound..<tail.endIndex)
            else { continue }
            let body = String(tail[bodyStart.upperBound..<bodyEnd.lowerBound])

            var children: [CatalogCategory] = []
            var seen = Set<String>()
            for item in CatalogHTML.fullMatches(#"<a\s+[^>]*>[\s\S]*?</a>"#, in: body) {
                guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: item),
                      let id = categoryID(from: href), id.hasPrefix("dm"),
                      seen.insert(id).inserted else { continue }
                let childTitle = CatalogHTML.stripTags(item)
                guard !childTitle.isEmpty else { continue }
                children.append(CatalogCategory(id: id, title: childTitle))
            }
            guard children.count >= 2 else { continue }
            result.append(CatalogCategory(id: "group:missav:\(name)", title: title,
                                          children: children, isGroup: true))
        }
        // 「中文字幕」是导航里的独立入口，不是下拉，但同样是视频列表。
        if let anchor = CatalogHTML.fullMatches(#"<a\s+[^>]*href="[^"]*chinese-subtitle"[^>]*>[\s\S]*?</a>"#,
                                                in: html).first,
           let href = CatalogHTML.first(#"href="([^"]+)""#, in: anchor),
           let id = categoryID(from: href) {
            let title = CatalogHTML.stripTags(anchor)
            if !title.isEmpty, !result.contains(where: { $0.id == id }) {
                result.append(CatalogCategory(id: id, title: title))
            }
        }
        return result
    }

    private static func categoryID(from href: String) -> String? {
        guard let comps = URLComponents(string: href) else { return nil }
        let segments = comps.path.split(separator: "/").map(String.init)
            .filter { !languageSegments.contains($0.lowercased()) }
        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: "/")
    }

    // MARK: - 解析：列表

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"class="thumbnail group""#, in: html) {
            // 模板块（Alpine 的 x-for）里 href 是 `:href="item…"`，真实卡片才是绝对地址。
            guard !block.contains(#":href="item."#),
                  let address = CatalogHTML.first(##"href="(https?://[^"]+/[^"#]+)"##, in: block),
                  let slug = slug(from: address),
                  seen.insert(slug).inserted else { continue }
            let title = CatalogHTML.first(#"<img[\s\S]*?alt="([^"]*)""#, in: block) ?? ""
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"<img[\s\S]*?data-src="([^"]+\.(?:jpg|jpeg|png|webp))""#,
                                          in: block) ?? ""
            let duration = CatalogHTML.first(#"<span[^>]*>\s*(\d+:\d+(?::\d+)?)\s*</span>"#,
                                             in: block) ?? ""
            result.append(CatalogItem(id: slug, title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: duration, categoryID: nil))
        }
        return result
    }

    /// `https://missav.live/dm31/fc2-ppv-1357849` → `dm31/fc2-ppv-1357849`。
    private static func slug(from address: String) -> String? {
        guard let comps = URLComponents(string: address) else { return nil }
        var path = comps.path
        while path.hasPrefix("/") { path.removeFirst() }
        return path.isEmpty ? nil : path
    }

    // MARK: - 解析：播放地址

    /// 还原页面里 Dean Edwards packer 压缩的播放脚本，取出 m3u8。
    static func playerSource(_ html: String) -> String? {
        let pattern = #"eval\(function\(p,a,c,k,e,d\)[\s\S]*?return p\}\('((?:\\.|[^'\\])*)',(\d+),(\d+),'([\s\S]*?)'\.split\('\|'\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators])
        else { return nil }
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges >= 5 else { return nil }

        let packed = ns.substring(with: match.range(at: 1))
            .replacingOccurrences(of: "\\'", with: "'")
        let base = Int(ns.substring(with: match.range(at: 2))) ?? 36
        let count = Int(ns.substring(with: match.range(at: 3))) ?? 0
        let words = ns.substring(with: match.range(at: 4)).components(separatedBy: "|")
        let decoded = unpack(packed, base: base, count: count, words: words)
        return CatalogHTML.first(#"(https://[^\s'"]+\.m3u8)"#, in: decoded)
    }

    /// packer 的字典按 base 进制给词编号，替换回原文后就是可读的 JS。
    private static func unpack(_ text: String, base: Int, count: Int, words: [String]) -> String {
        guard base > 1, count > 0 else { return text }
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        func token(_ value: Int) -> String {
            var number = value
            var output = ""
            repeat {
                output = String(digits[number % base]) + output
                number /= base
            } while number > 0
            return output
        }
        var map: [String: String] = [:]
        for index in 0..<min(count, words.count) {
            // 空串在 JS 里是 falsy，packer 会保留原词本身（例如 CDN 子域 `b`）。
            map[token(index)] = words[index].isEmpty ? token(index) : words[index]
        }
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9_]+") else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor,
                                                     length: match.range.location - cursor))
            }
            let word = ns.substring(with: match.range)
            result += map[word] ?? word
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }
}
