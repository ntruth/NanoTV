import Foundation

/// 网页影视源共用的小工具：取页、取封面、解析 meta、拼播放地址。
/// 这些站点都是服务端渲染的 HTML，不需要登录，图片也不需要解密。
enum WebCatalogSupport {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    /// 从用户输入的地址得到不带路径的站点根地址。
    static func base(from address: String) throws -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CatalogError.invalidConfig("地址为空") }
        var raw = trimmed
        if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
        guard var comps = URLComponents(string: raw), let host = comps.host, !host.isEmpty else {
            throw CatalogError.invalidConfig("地址无法识别")
        }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        guard var base = comps.url?.absoluteString else {
            throw CatalogError.invalidConfig("地址无法识别")
        }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    static func root(_ source: CatalogSource) throws -> String {
        var text = source.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, URL(string: text)?.host != nil else {
            throw CatalogError.invalidConfig("站点地址为空")
        }
        return text
    }

    static func fetchHTML(_ url: URL, source: CatalogSource) async throws -> String {
        try await CatalogHTTP.fetchPage(url: url, source: source)
    }

    static func fetchHTML(_ address: String, source: CatalogSource) async throws -> String {
        guard let url = URL(string: address) else {
            throw CatalogError.parse("页面地址无效")
        }
        return try await fetchHTML(url, source: source)
    }

    static func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        guard let url = URL(string: CatalogHTML.fixURL(urlString, base: source.baseURL)) else {
            throw CatalogError.parse("封面地址无效")
        }
        let data = try await CatalogHTTP.fetchData(url: url, headers: [
            "User-Agent": source.userAgent,
            "Referer": source.referer,
            "Accept": "image/avif,image/webp,image/*,*/*;q=0.8"
        ])
        guard !data.isEmpty else { throw CatalogError.parse("封面为空") }
        return data
    }

    /// `<meta property/name="key" content="…">`，两种属性顺序都认。
    static func meta(_ html: String, _ key: String) -> String {
        CatalogHTML.first(#"<meta[^>]+(?:property|name)="\#(key)"[^>]+content="([^"]+)""#, in: html)
            ?? CatalogHTML.first(#"<meta[^>]+content="([^"]+)"[^>]+(?:property|name)="\#(key)""#, in: html)
            ?? ""
    }

    static func stream(_ raw: String, base: String, referer: String,
                       userAgent: String) throws -> CatalogStream {
        let fixed = CatalogHTML.fixURL(raw, base: base)
        guard let url = URL(string: fixed) else {
            throw CatalogError.parse("视频地址解析失败")
        }
        return CatalogStream(url: url,
                             headers: ["User-Agent": userAgent, "Referer": referer],
                             isHLS: true)
    }

    /// 这类站点没有正文章节，把标签整理成一段文字，详情页就不会空着。
    static func tagBlocks(_ tags: [String]) -> [CatalogContentBlock] {
        var seen = Set<String>()
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !cleaned.isEmpty else { return [] }
        return [CatalogContentBlock(kind: .paragraph,
                                    text: "标签：" + cleaned.joined(separator: " · "))]
    }

    static func singleEpisode(id: String, title: String, cover: String,
                              pageURL: String, remark: String = "",
                              blocks: [CatalogContentBlock] = []) -> CatalogDetail {
        let item = CatalogItem(id: id, title: title, coverURL: cover,
                               remark: remark, categoryID: nil)
        return CatalogDetail(item: item,
                             episodes: [CatalogEpisode(index: 1, pageURL: pageURL)],
                             blocks: blocks)
    }

    /// 列表页是否还有下一页（`?page=N` 或 `/N` 两种写法）。
    static func hasNextPage(_ html: String, page: Int) -> Bool {
        html.range(of: "page=\(page + 1)") != nil
            || html.range(of: "/\(page + 1).html") != nil
            || html.range(of: "/\(page + 1)/") != nil
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 搜索词作为查询参数：`&` `=` `+` 这些必须转义，否则会把地址拆坏。
    static func queryEncoded(_ keyword: String) -> String? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=+#")
        return keyword.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// 搜索词作为路径分段：斜杠也要转义。
    static func pathEncoded(_ keyword: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return keyword.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
