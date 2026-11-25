import Foundation
import CryptoKit

/// 爱壹帆（iyf.tv）适配器。
///
/// 站点是 Angular 应用，数据有两层来源：
/// - 首页 / 频道页的服务端渲染里带 `var injectJson = {...}`，有海报与频道条目；
/// - 列表分页、搜索、详情、分集与播放都走 `m10.iyf.tv` / `rankv21.iyf.tv` 的 JSON 接口。
///
/// 接口要求 `vv` / `pub` 签名：
/// `vv = md5(publicKey + "&" + 小写查询串 + "&" + privateKey)`，`pub = publicKey`。
/// 签名材料从页面 `injectJson.config[0].pConfig` 读取，读不到时使用内置的一份兜底。
struct IYFCatalogProvider: CatalogProvider {
    static let userAgent = WebCatalogSupport.userAgent

    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "0,1,3", title: "电影", children: genreChildren("0,1,3", movieGenres)),
        CatalogCategory(id: "0,1,4", title: "电视剧", children: dramaChildren),
        CatalogCategory(id: "0,1,5", title: "综艺", children: genreChildren("0,1,5", varietyGenres)),
        CatalogCategory(id: "0,1,6", title: "动漫", children: genreChildren("0,1,6", animeGenres)),
        CatalogCategory(id: "0,1,7", title: "纪录片", children: genreChildren("0,1,7", documentaryGenres)),
        CatalogCategory(id: "0,1,8", title: "短剧", children: genreChildren("0,1,8", shortGenres))
    ]

    /// 站点导航里的二级：cid 直接用「一级 cid + 站点类型 id」。
    private static let movieGenres: [(title: String, id: String)] = [
        ("喜剧", "19"), ("爱情", "20"), ("动作", "21"), ("犯罪", "22"), ("科幻", "23"),
        ("奇幻", "24"), ("冒险", "25"), ("灾难", "26"), ("恐怖", "123"), ("惊悚", "27"),
        ("剧情", "28"), ("战争", "29"), ("歌舞", "30"), ("经典", "31"), ("悬疑", "32"),
        ("动画", "113"), ("同性", "124"), ("网络电影", "125")
    ]

    private static let dramaRegions = ["大陆", "香港", "台湾", "日本", "韩国", "欧美", "英国", "泰国", "其它"]

    private static let dramaGenres: [(title: String, id: String)] = [
        ("偶像", "129"), ("言情", "127"), ("爱情", "146"), ("古装", "126"), ("历史", "141"),
        ("玄幻", "142"), ("谍战", "136"), ("都市", "132"), ("历险", "143"), ("科幻", "144"),
        ("军旅", "135"), ("喜剧", "133"), ("武侠", "128"), ("江湖", "145"), ("罪案", "138"),
        ("青春", "131"), ("家庭", "130"), ("战争", "134"), ("悬疑", "137"), ("穿越", "139"),
        ("宫廷", "140"), ("神话", "147"), ("商战", "148"), ("警匪", "149"), ("动作", "150"),
        ("惊悚", "151"), ("剧情", "152"), ("同性", "153"), ("奇幻", "154")
    ]

    private static let varietyGenres: [(title: String, id: String)] = [
        ("真人秀", "39"), ("选秀", "38"), ("网综", "94"), ("脱口秀", "43"), ("搞笑", "40"),
        ("竞技", "91"), ("情感", "33"), ("访谈", "34"), ("演唱会", "44"), ("晚会", "92"),
        ("其它", "45")
    ]

    private static let animeGenres: [(title: String, id: String)] = [
        ("热血", "46"), ("格斗", "47"), ("机战", "48"), ("少女", "49"), ("竞技", "51"),
        ("科幻", "52"), ("魔幻", "53"), ("爆笑", "54"), ("推理", "55"), ("冒险", "121"),
        ("恋爱", "120"), ("校园", "119"), ("治愈", "118"), ("泡面", "117"), ("穿越", "116"),
        ("灵异", "56"), ("耽美", "122"), ("剧场版", "57"), ("其它", "58")
    ]

    private static let documentaryGenres: [(title: String, id: String)] = [
        ("文化", "50"), ("探索", "59"), ("军事", "60"), ("解密", "61"), ("科技", "62"),
        ("历史", "63"), ("人物", "64"), ("自然", "66"), ("其它", "67")
    ]

    private static let shortGenres: [(title: String, id: String)] = [
        ("偶像", "68"), ("爱情", "69"), ("言情", "72"), ("古装", "70"), ("历史", "141"),
        ("玄幻", "73"), ("谍战", "74"), ("都市", "158"), ("历险", "159"), ("科幻", "160"),
        ("军旅", "161"), ("喜剧", "162"), ("武侠", "163"), ("江湖", "164"), ("罪案", "165"),
        ("青春", "166"), ("家庭", "167"), ("战争", "168"), ("悬疑", "169"), ("穿越", "170"),
        ("宫廷", "171"), ("神话", "172"), ("商战", "175"), ("警匪", "176"), ("动作", "177"),
        ("惊悚", "178"), ("剧情", "179"), ("同性", "180"), ("奇幻", "181")
    ]

    private static var dramaChildren: [CatalogCategory] {
        let regions = dramaRegions.map { region -> CatalogCategory in
            let encoded = region.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? region
            return CatalogCategory(id: "0,1,4?region=\(encoded)", title: region)
        }
        return regions + genreChildren("0,1,4", dramaGenres)
    }

    private static func genreChildren(_ top: String,
                                      _ genres: [(title: String, id: String)]) -> [CatalogCategory] {
        genres.map { CatalogCategory(id: "\(top),\($0.id)", title: $0.title) }
    }

    /// 频道页路径：服务端渲染的海报比列表接口里的动图更清晰。
    private static let landingPaths: [String: String] = [
        "0,1,3": "movie",
        "0,1,4": "drama",
        "0,1,5": "variety",
        "0,1,6": "anime",
        "0,1,7": "documentary",
        "0,1,8": "short"
    ]

    var supportedSorts: [CatalogSort] { [.latest] }

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        var items: [CatalogItem] = []
        var hasMore = false
        var failure: Error?
        if let ssr = try? await Self.ssrItems(path: "/", source: source) {
            items = ssr
        } else {
            failure = CatalogError.parse("首页没有解析到内容")
        }
        if let api = try? await Self.apiList(cid: "0", page: 1, source: source) {
            items = Self.merge(ssr: items, api: api.items)
            hasMore = api.hasMore
        } else {
            failure = CatalogError.unavailable("列表接口暂时不可用")
        }
        guard !items.isEmpty else { throw failure ?? CatalogError.unavailable("暂时没有内容") }
        return CatalogPage(items: items, page: 1, hasMore: hasMore)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        guard page > 1 else { return try await home(source: source) }
        let api = try await Self.apiList(cid: "0", page: page, source: source)
        return CatalogPage(items: api.items, page: page, hasMore: api.hasMore)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let query = Self.parseCategoryQuery(category.id)
        var items: [CatalogItem] = []
        if page <= 1, query.region == nil, let path = Self.landingPaths[query.cid],
           let ssr = try? await Self.ssrItems(path: "/" + path, source: source) {
            items = ssr
        }
        do {
            let listed = try await Self.searchList(source: source,
                                                   cid: query.cid,
                                                   region: query.region,
                                                   page: page)
            items = Self.merge(ssr: items, api: listed.items)
            return CatalogPage(items: items, page: page, hasMore: listed.hasMore)
        } catch {
            guard !items.isEmpty else { throw error }
            return CatalogPage(items: items, page: page, hasMore: false)
        }
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        guard let encoded = WebCatalogSupport.queryEncoded(trimmed) else {
            throw CatalogError.invalidConfig("搜索词无效")
        }
        // 站点真实搜索：`/api/list/Search` 用 `tags` 传关键词，返回结构与分类列表一致。
        let query = "cinema=1&page=\(max(1, page))&size=24&orderby=0&desc=1"
            + "&isserial=-1&isIndex=-1&isfree=-1&isVertical=-1&v=1&tags=" + encoded
        let object = try await Self.apiGet(base: Self.apiHost(source) + "/api/list/Search",
                                           query: query,
                                           source: source)
        guard let first = Self.infoArray(object).first else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        let rawList = first["result"] as? [[String: Any]] ?? []
        let items = rawList.compactMap(Self.item(fromList:))
        let maxPage = Self.int(first["maxpage"]) ?? 0
        let total = Self.int(first["recordcount"]) ?? 0
        let hasMore = maxPage > 0 ? page < maxPage : (total > page * items.count)
        return CatalogPage(items: items, page: page, hasMore: hasMore)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        guard let key = WebCatalogSupport.queryEncoded(itemID) else {
            throw CatalogError.invalidConfig("条目地址无效")
        }
        let query = "ispath=false&cinema=1&id=\(key)&device=desktop&player=CkPlayer"
            + "&tech=HLS&country=HU&lang=cns&v=1"
        let object = try await Self.apiGet(base: Self.apiV3(source) + "/video/detail",
                                           query: query,
                                           source: source)
        guard let raw = Self.infoArray(object).first else {
            throw CatalogError.parse("没有找到条目资料")
        }

        let title = Self.text(raw["title"]) ?? ""
        guard !title.isEmpty else { throw CatalogError.parse("没有找到条目标题") }
        let cover = CatalogHTML.fixURL(Self.text(raw["imgPath"]) ?? "", base: source.baseURL)
        let channel = Self.text(raw["channel"]) ?? ""
        let genre = Self.text(raw["videoType"]) ?? ""
        let region = Self.text(raw["regional"]) ?? ""
        let language = Self.text(raw["language"]) ?? ""
        let score = Self.text(raw["score"]) ?? ""
        let directors = Self.text(raw["directors"] as Any?) ?? ""
        let stars = Self.text(raw["stars"] as Any?) ?? ""
        let synopsis = CatalogHTML.stripTags(Self.text(raw["contxt"]) ?? "")
        let cid = Self.text(raw["cid"]) ?? ""
        let isSerial = Self.bool(raw["isSerial"])
        let serialCount = Self.int(raw["serialCount"]) ?? 0

        var facts: [CatalogDetailFact] = []
        if !channel.isEmpty { facts.append(CatalogDetailFact(label: "频道", value: channel)) }
        if !genre.isEmpty { facts.append(CatalogDetailFact(label: "类型", value: genre)) }
        if !region.isEmpty { facts.append(CatalogDetailFact(label: "地区", value: region)) }
        if !language.isEmpty { facts.append(CatalogDetailFact(label: "语言", value: language)) }
        if !directors.isEmpty { facts.append(CatalogDetailFact(label: "导演", value: directors)) }
        if !stars.isEmpty { facts.append(CatalogDetailFact(label: "主演", value: stars)) }
        if !score.isEmpty { facts.append(CatalogDetailFact(label: "评分", value: score)) }
        if isSerial, serialCount > 0 {
            facts.append(CatalogDetailFact(label: "集数", value: "\(serialCount) 集"))
        }

        var episodes: [CatalogEpisode] = []
        if isSerial {
            let listQuery = "cinema=1&vid=\(key)&lsk=1&taxis=0&cid=\(cid)&v=1"
            if let listObject = try? await Self.apiGet(base: Self.apiV3(source) + "/video/languagesplaylist",
                                                       query: listQuery,
                                                       source: source),
               let playList = Self.infoArray(listObject).first?["playList"] as? [[String: Any]] {
                episodes = playList.enumerated().compactMap { index, entry in
                    guard let episodeKey = Self.text(entry["key"]) else { return nil }
                    let name = Self.text(entry["name"]) ?? "第 \(index + 1) 集"
                    return CatalogEpisode(index: index + 1,
                                          pageURL: "iyf://ep/\(episodeKey)",
                                          name: name)
                }
            }
        }
        if episodes.isEmpty {
            episodes = [CatalogEpisode(index: 1,
                                       pageURL: "iyf://movie/\(key)",
                                       name: "正片")]
        }

        let blocks = synopsis.isEmpty
            ? []
            : [CatalogContentBlock(kind: .paragraph, text: synopsis)]
        let item = CatalogItem(id: itemID,
                               title: title,
                               coverURL: cover,
                               remark: "",
                               categoryID: cid)
        return CatalogDetail(item: item, episodes: episodes, blocks: blocks, facts: facts)
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        let address = episode.pageURL
        let key: String
        let isEpisode: Bool
        if address.hasPrefix("iyf://ep/") {
            key = String(address.dropFirst("iyf://ep/".count))
            isEpisode = true
        } else if address.hasPrefix("iyf://movie/") {
            key = String(address.dropFirst("iyf://movie/".count))
            isEpisode = false
        } else {
            throw CatalogError.parse("播放地址无效")
        }
        guard let encoded = WebCatalogSupport.queryEncoded(key) else {
            throw CatalogError.parse("播放地址无效")
        }
        let query = "cinema=1&id=\(encoded)&a=\(isEpisode ? 0 : 1)&usersign=1"
            + "&region=GL.&device=1&isMasterSupport=1&v=1"
        let object = try await Self.apiGet(base: Self.apiV3(source) + "/video/play",
                                           query: query,
                                           source: source)
        guard let info = Self.infoArray(object).first,
              let paths = info["flvPathList"] as? [[String: Any]] else {
            throw CatalogError.unavailable("暂时没有可用的播放线路")
        }
        let hls = paths.first {
            Self.bool($0["isHls"]) && (Self.text($0["result"]) ?? "").contains(".m3u8")
        }
        // `flvPathList` 的第一条常是 20 秒广告（mp4）；没有正片 HLS 时不要把它当成播放地址。
        let fallback = paths.first {
            guard (Self.text($0["result"]) ?? "").lowercased().hasPrefix("http") else { return false }
            let duration = Self.int($0["duration"]) ?? 0
            return duration == 0 || duration > 30
        }
        guard let chosen = hls ?? fallback,
              let raw = Self.text(chosen["result"]),
              let url = URL(string: raw) else {
            throw CatalogError.unavailable("该片可能需要会员，或暂时没有可用线路")
        }
        return CatalogStream(url: url,
                             headers: ["User-Agent": source.userAgent,
                                       "Referer": source.referer],
                             isHLS: url.absoluteString.lowercased().contains(".m3u8"))
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 服务端渲染的频道条目

    private static func ssrItems(path: String, source: CatalogSource) async throws -> [CatalogItem] {
        let root = try WebCatalogSupport.root(source)
        guard let url = URL(string: root + path) else {
            throw CatalogError.parse("页面地址无效")
        }
        let data = try await CatalogHTTP.fetchData(url: url, headers: pageHeaders(source))
        let html = String(decoding: data, as: UTF8.self)
        guard let json = injectJSON(html) else {
            throw CatalogError.parse("页面数据解析失败")
        }
        if let signature = signature(from: json) {
            remember(signature, host: domain(source))
        }
        var seen = Set<String>()
        var items: [CatalogItem] = []
        for value in json.values {
            guard let list = value as? [[String: Any]] else { continue }
            for raw in list {
                guard let id = text(raw["listPath"]) ?? text(raw["key"]),
                      !id.isEmpty,
                      seen.insert(id).inserted,
                      let title = text(raw["title"]), !title.isEmpty,
                      !bool(raw["external"]) else { continue }
                let cover = text(raw["img"]) ?? text(raw["image"]) ?? ""
                items.append(CatalogItem(id: id,
                                         title: title,
                                         coverURL: CatalogHTML.fixURL(cover, base: source.baseURL),
                                         remark: text(raw["subTitle"]) ?? "",
                                         publishedAt: publishDate(text(raw["addTime"]))))
            }
        }
        return items
    }

    // MARK: - 列表接口

    private static func apiList(cid: String,
                                page: Int,
                                source: CatalogSource) async throws
        -> (items: [CatalogItem], hasMore: Bool) {
        let query = "cinema=1&page=\(max(1, page))&cid=\(cid)&size=24&isn=0&isfree=-1&v=1"
        let object = try await apiGet(base: apiHost(source) + "/api/list/index",
                                      query: query,
                                      source: source)
        let list = infoArray(object)
        let items = list.compactMap { item(fromList: $0) }
        return (items, items.count >= 24)
    }

    /// 二级分类的 id 形如 `0,1,3,19`（类型）或 `0,1,4?region=大陆`（地区）。
    private struct CategoryQuery {
        var cid: String
        var region: String?
    }

    private static func parseCategoryQuery(_ id: String) -> CategoryQuery {
        let parts = id.split(separator: "?", maxSplits: 1)
        var query = CategoryQuery(cid: String(parts[0]), region: nil)
        guard parts.count > 1 else { return query }
        for pair in parts[1].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0] == "region" else { continue }
            let raw = String(kv[1])
            query.region = raw.removingPercentEncoding ?? raw
        }
        return query
    }

    /// 站内筛选列表：`/api/list/Search` 支持一级 cid、二级 cid 与地区参数，并返回总页数。
    private static func searchList(source: CatalogSource,
                                   cid: String,
                                   region: String?,
                                   page: Int) async throws
        -> (items: [CatalogItem], hasMore: Bool) {
        var query = "cinema=1&page=\(max(1, page))&size=24&orderby=0&desc=1"
            + "&cid=\(cid)&isserial=-1&isIndex=-1&isfree=-1&isVertical=-1&v=1"
        if let region, let encoded = WebCatalogSupport.queryEncoded(region) {
            query += "&region=" + encoded
        }
        let object = try await apiGet(base: apiHost(source) + "/api/list/Search",
                                      query: query,
                                      source: source)
        guard let first = infoArray(object).first else {
            return ([], false)
        }
        let rawList = first["result"] as? [[String: Any]] ?? []
        let items = rawList.compactMap { item(fromList: $0) }
        let maxPage = int(first["maxpage"]) ?? 0
        let total = int(first["recordcount"]) ?? 0
        let hasMore = maxPage > 0 ? page < maxPage : (total > page * items.count)
        return (items, hasMore)
    }

    private static func item(fromList raw: [String: Any]) -> CatalogItem? {
        guard let id = text(raw["key"]), !id.isEmpty,
              let title = text(raw["title"]), !title.isEmpty else { return nil }
        var remark = ""
        if bool(raw["isSerial"]) {
            let last = text(raw["lastName"]) ?? ""
            let total = int(raw["serialCount"]) ?? 0
            if let number = Int(last), number > 0 {
                if total == number, total > 0 {
                    remark = "全\(total)集"
                } else {
                    remark = "更新至\(number)集"
                }
            } else {
                remark = last
            }
        } else {
            remark = text(raw["vipResource"]) ?? text(raw["score"]) ?? text(raw["rating"]) ?? ""
        }
        return CatalogItem(id: id,
                           title: title,
                           coverURL: CatalogHTML.fixURL(text(raw["image"]) ?? "", base: ""),
                           remark: remark,
                           publishedAt: publishDate(text(raw["addTime"])))
    }

    /// 站点 `addTime` 形如「2026年11月24日」：取出年月日落到当天中午，供日历落位。
    private static func publishDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let numbers = raw.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
        guard numbers.count >= 3 else { return nil }
        let year = numbers[0], month = numbers[1], day = numbers[2]
        guard (1900...2100).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar.current.date(from: components)
    }

    // MARK: - 签名与请求

    private struct Signature: Sendable {
        var publicKey: String
        var privateKey: String
    }

    /// 站点 `pConfig` 读不到时的兜底（与页面内联配置一致）。
    private static let fallbackSignature = Signature(
        publicKey: "CJSvDJGuD3KtE2utCLya9QzCZGmC3erDc4mEZXZCZevCp5cEcKrPcCwP3GmC3fYPMOqEcCqOpbVCJWtDpCpCs8rPJOrD64rDpbbOcCoCcPXCZ4tOM8vE3DVOJGvCp4rCJGuEJ8nPZOtDpSsOJTcDZPcC38pEJOmCp3",
        privateKey: "SvDJJSvDJGuD3KtE2utC"
    )

    private static let signatureLock = NSLock()
    private static var signatureCache: [String: Signature] = [:]

    private static func cachedSignature(_ host: String) -> Signature? {
        signatureLock.lock()
        defer { signatureLock.unlock() }
        return signatureCache[host]
    }

    private static func remember(_ signature: Signature, host: String) {
        signatureLock.lock()
        signatureCache[host] = signature
        signatureLock.unlock()
    }

    private static func forget(host: String) {
        signatureLock.lock()
        signatureCache[host] = nil
        signatureLock.unlock()
    }

    private static func signature(for source: CatalogSource,
                                  json: [String: Any]? = nil) async throws -> Signature {
        let host = domain(source)
        if let cached = cachedSignature(host) { return cached }
        if let json, let parsed = signature(from: json) {
            remember(parsed, host: host)
            return parsed
        }
        if let root = URL(string: try WebCatalogSupport.root(source) + "/"),
           let data = try? await CatalogHTTP.fetchData(url: root, headers: pageHeaders(source)),
           let parsed = signature(from: injectJSON(String(decoding: data, as: UTF8.self))) {
            remember(parsed, host: host)
            return parsed
        }
        remember(fallbackSignature, host: host)
        return fallbackSignature
    }

    private static func signature(from json: [String: Any]?) -> Signature? {
        guard let configs = json?["config"] as? [[String: Any]],
              let pConfig = configs.first?["pConfig"] as? [String: Any],
              let publicKey = text(pConfig["publicKey"]), !publicKey.isEmpty,
              let list = pConfig["privateKey"] as? [Any],
              let privateKey = list.compactMap({ text($0) }).first, !privateKey.isEmpty else {
            return nil
        }
        return Signature(publicKey: publicKey, privateKey: privateKey)
    }

    private static func signedURL(_ base: String,
                                  query: String,
                                  signature: Signature) throws -> URL {
        let digest = Insecure.MD5.hash(data: Data(
            (signature.publicKey + "&" + query.lowercased() + "&" + signature.privateKey).utf8
        ))
        let vv = digest.map { String(format: "%02x", $0) }.joined()
        let raw = base + "?" + query + "&vv=" + vv + "&pub=" + signature.publicKey
        guard let url = URL(string: raw) else {
            throw CatalogError.parse("接口地址无效")
        }
        return url
    }

    private static func apiGet(base: String,
                               query: String,
                               source: CatalogSource) async throws -> [String: Any] {
        let host = domain(source)
        var signature = try await signature(for: source)
        var object = try await sendGet(base: base, query: query, signature: signature, source: source)
        if isSignatureError(object) {
            forget(host: host)
            signature = try await Self.signature(for: source)
            object = try await sendGet(base: base, query: query, signature: signature, source: source)
        }
        return object
    }

    private static func sendGet(base: String,
                                query: String,
                                signature: Signature,
                                source: CatalogSource) async throws -> [String: Any] {
        let url = try signedURL(base, query: query, signature: signature)
        let data = try await CatalogHTTP.fetchData(url: url, headers: pageHeaders(source))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.parse("接口返回的不是 JSON")
        }
        return object
    }

    private static func isSignatureError(_ object: [String: Any]) -> Bool {
        guard let data = object["data"] as? [String: Any],
              int(data["code"]) == 1,
              let message = text(data["msg"]) else { return false }
        return message.contains("签名")
    }

    private static func infoArray(_ object: [String: Any]) -> [[String: Any]] {
        (object["data"] as? [String: Any])?["info"] as? [[String: Any]] ?? []
    }

    private static func pageHeaders(_ source: CatalogSource) -> [String: String] {
        ["User-Agent": source.userAgent,
         "Referer": source.referer,
         "Accept": "text/html,application/json,application/xhtml+xml,*/*;q=0.8",
         "Accept-Language": "zh-CN,zh;q=0.9"]
    }

    // MARK: - 站点内联数据

    private static func injectJSON(_ html: String) -> [String: Any]? {
        let ns = html as NSString
        let marker = ns.range(of: "var injectJson = ")
        guard marker.location != NSNotFound else { return nil }
        let begin = marker.location + marker.length
        guard let end = matchingBrace(ns, from: begin), end > begin else { return nil }
        let raw = ns.substring(with: NSRange(location: begin, length: end - begin + 1))
        return try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
    }

    private static func matchingBrace(_ ns: NSString, from start: Int) -> Int? {
        var depth = 0
        var index = start
        var inString = false
        var escaped = false
        while index < ns.length {
            let code = ns.character(at: index)
            if inString {
                if escaped {
                    escaped = false
                } else if code == 0x5C {
                    escaped = true
                } else if code == 0x22 {
                    inString = false
                }
            } else if code == 0x22 {
                inString = true
            } else if code == 0x7B {
                depth += 1
            } else if code == 0x7D {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: - 合并与小工具

    private static func merge(ssr: [CatalogItem], api: [CatalogItem]) -> [CatalogItem] {
        // 两边的条目 id 不一定一致（页面链接 vs 播放 key），再按标题补一次上架日期。
        var apiDates: [String: Date] = [:]
        for item in api {
            let key = NetworkCinemaEnrichment.normalized(item.title)
            if !key.isEmpty, let date = item.publishedAt { apiDates[key] = date }
        }
        var byID: [String: CatalogItem] = [:]
        var order: [String] = []
        for item in ssr where byID[item.id] == nil {
            var copy = item
            if copy.publishedAt == nil {
                copy.publishedAt = apiDates[NetworkCinemaEnrichment.normalized(copy.title)]
            }
            order.append(copy.id)
            byID[copy.id] = copy
        }
        for item in api {
            if var existing = byID[item.id] {
                // 页面内联数据没有上架日期时，用列表接口的同一条补上。
                if existing.publishedAt == nil { existing.publishedAt = item.publishedAt }
                if existing.remark.isEmpty { existing.remark = item.remark }
                byID[item.id] = existing
            } else {
                order.append(item.id)
                byID[item.id] = item
            }
        }
        return order.compactMap { byID[$0] }
    }

    private static func domain(_ source: CatalogSource) -> String {
        var host = (URL(string: source.baseURL)?.host ?? source.host).lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private static func apiHost(_ source: CatalogSource) -> String {
        "https://m10." + domain(source)
    }

    private static func apiV3(_ source: CatalogSource) -> String {
        apiHost(source) + "/v3"
    }

    private static func bool(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return value == "true" || value == "1"
        default: return false
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value)
        default: return nil
        }
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        case let value as [Any]:
            let parts = value.compactMap { text($0) }
            return parts.isEmpty ? nil : parts.joined(separator: "、")
        default:
            return nil
        }
    }
}

// MARK: - 导入

extension IYFCatalogProvider {
    static func importSource(from address: String) async throws -> CatalogSource {
        let root = try WebCatalogSupport.base(from: address)
        let host = URL(string: root)?.host ?? root
        let name: String
        if host.contains("kubb") {
            name = "Kubb"
        } else if host.contains("iyf") {
            name = "爱壹帆"
        } else {
            name = host
        }
        let source = CatalogSource(name: name,
                                   kind: .iyf,
                                   baseURL: root,
                                   configURL: address,
                                   userAgent: userAgent,
                                   referer: root + "/",
                                   categories: defaultCategories)
        let page = try await IYFCatalogProvider().home(source: source)
        guard !page.items.isEmpty else {
            throw CatalogError.invalidConfig("首页没有解析到影视内容")
        }
        return source
    }
}
