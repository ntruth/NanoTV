import Foundation
import CryptoKit

// MARK: - 网络资源（影视源）
//
// 与 `CloudMount` 并列的一类「网络资源」：它没有文件树、没有 OAuth、没有全盘扫描，
// 只有分类、条目、分集与播放页。所有字段都以站点原始字符串为准，便于回溯与改版排查。

enum CatalogProviderKind: String, Codable, Hashable {
    case huangguo
    case ninetyOne
    case ninetyOnePorna
    case xszAV
    case missav
    case avple
    case shise
    case avgle
    case rouVideo
    case quanji
    case javcl
    case madou
    case javgg
    /// 苹果CMS（MacCMS V10）通用 JSON 接口：国内大量影视站共用同一套协议。
    case maccms
    /// FoFo 影院：自建 PHP 模板站，列表是 HTML，播放地址由 `/source/` 按 sid 换取。
    case fofo
    /// 爱看片片：Next.js 站点，数据在 RSC 负载里，播放走站内的 `/api/lines`。
    case ikanpp
    /// 爱壹帆：Angular 站点，页面内联数据 + 带签名的 JSON 接口。
    case iyf

    var title: String {
        switch self {
        case .huangguo: return "黄果短剧（FongMi 源）"
        case .ninetyOne: return "91吃瓜（网页源）"
        case .ninetyOnePorna: return "91porna（网页源）"
        case .xszAV: return "XSZAV（网页源）"
        case .missav: return "MissAV（网页源）"
        case .avple: return "Avple（网页源）"
        case .shise: return "视色（网页源）"
        case .avgle: return "Avgle（网页源）"
        case .rouVideo: return "肉视频（网页源）"
        case .quanji: return "91全集（网页源）"
        case .javcl: return "JavCl（网页源）"
        case .madou: return "麻豆社（国产原创）"
        case .javgg: return "JavGG（网页源）"
        case .maccms: return "苹果CMS 影视源"
        case .fofo: return "FoFo 影院"
        case .ikanpp: return "爱看片片"
        case .iyf: return "爱壹帆"
        }
    }

    /// 会聚合进「网络影院」的通用影视源：成人向站点不在此列。
    var supportsNetworkCinema: Bool {
        switch self {
        case .maccms, .fofo, .ikanpp, .iyf: return true
        default: return false
        }
    }

    /// 目录类来源分两个互不相通的域：网页资源站只进「网络资源」，
    /// 影视源只进「网络影院」。所有聚合、检索、收藏与统计都必须先按域筛。
    var domain: CatalogDomain {
        supportsNetworkCinema ? .networkCinema : .networkResource
    }

    /// 网页形式的源：卡片是 16:9 横图，默认按 4 列展示。
    /// 以后新增的网页源默认也走这套版式。
    var isWebSite: Bool {
        if case .huangguo = self { return false }
        // 苹果CMS 是海报型影视站：2:3 竖图，走海报列数。
        if case .maccms = self { return false }
        // FoFo / 爱看片片同样是海报型影视站。
        if case .fofo = self { return false }
        if case .ikanpp = self { return false }
        if case .iyf = self { return false }
        return true
    }
}

/// 站点的产品归属：两个域各自维护源清单、聚合结果与检索，互不混用。
enum CatalogDomain: String, CaseIterable, Hashable {
    /// 网络资源：网页资源站。
    case networkResource
    /// 网络影院：苹果CMS / FoFo / 爱看片片 / 爱壹帆等影视源。
    case networkCinema

    var title: String {
        switch self {
        case .networkResource: return "网络资源"
        case .networkCinema: return "网络影院"
        }
    }

    var symbolName: String {
        switch self {
        case .networkResource: return "play.rectangle.on.rectangle"
        case .networkCinema: return "film.stack"
        }
    }
}

/// 分类页的排序子视图。站点 JSON API 只接受 latest / hot / new / collect。
enum CatalogSort: String, CaseIterable, Identifiable, Codable, Hashable {
    case latest
    case hot
    case newest
    case collect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: return "最新更新"
        case .hot: return "当前热播"
        case .newest: return "最新上架"
        case .collect: return "最多收藏"
        }
    }

    /// 直接用于 JSON API 的 sort 参数。
    var pathSuffix: String {
        switch self {
        case .latest: return "latest"
        case .hot: return "hot"
        case .newest: return "new"
        case .collect: return "collect"
        }
    }
}

struct CatalogCategory: Identifiable, Codable, Hashable {
    /// 站点页面路径，去掉首尾斜杠。例如 `ai-duanju`、`original/manju`、`ranks/hot`。
    var id: String
    var title: String
    var isRank: Bool = false
    /// 二级分类（频道页里的 tab，如「全部原创 / 原创漫剧 / 原创短剧」）。
    var children: [CatalogCategory]? = nil
    /// 只有分组节点才为 true：这种节点自身没有页面，点它等于打开第一个子分类。
    /// 用可选值是为了让已保存的源（没有这个键）仍能正常解码。
    var isGroup: Bool? = nil

    /// 用来拼接站点地址的分段，例如 `original/manju`。
    var path: String { id }

    var isGroupCategory: Bool { isGroup == true }
}

struct CatalogSource: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: CatalogProviderKind = .huangguo
    /// 站点根地址，例如 https://huangguoai.com
    var baseURL: String
    /// 导入时使用的配置地址，仅作记录，便于重新拉取。
    var configURL: String?
    /// 苹果CMS 的 JSON 接口地址（例如 `https://example.com/api.php/provide/vod/`）。
    /// 其它源为 nil；站点根地址仍放在 `baseURL`，封面与 Referer 用它。
    var apiBase: String? = nil
    var userAgent: String
    var referer: String
    /// 封面解密参数，随源配置保存；导入时从脚本读取，可在编辑中覆盖。
    var artworkKey: String?
    var artworkIV: String?
    /// 站点证书不受系统信任时，用户可对这一条源显式放行（仅影响该源）。
    var allowsInsecureTLS: Bool? = nil
    /// 分类骨架：侧边栏直接渲染，不必等网络。
    var categories: [CatalogCategory]
    /// 卡片海报的宽高比；缺省 2:3。网页源的封面常是横图（约 2:1），避免竖着裁掉大半。
    var posterAspect: Double? = nil
    /// 默认关闭：资源内容由第三方站点提供，需要用户显式启用。
    var isEnabled: Bool = false
    var createdAt: Date = Date()

    var host: String {
        (URLComponents(string: baseURL)?.host ?? baseURL).lowercased()
    }

    /// 这条源属于「网络资源」还是「网络影院」：所有跨源聚合先按它分流。
    var domain: CatalogDomain { kind.domain }

    /// 卡片海报的宽高比：优先用源里保存的值；旧版已导入的网页源没有这个字段，
    /// 按来源给一个合理默认，避免竖着裁掉大半横图。
    var posterRatio: Double {
        if let posterAspect, posterAspect > 0 { return posterAspect }
        switch kind {
        case .ninetyOne: return 1.95
        case .ninetyOnePorna: return 16.0 / 9.0
        case .xszAV, .missav, .avple, .shise, .avgle, .rouVideo, .quanji: return 16.0 / 9.0
        default: return 2.0 / 3.0
        }
    }

    var trustsInsecureCertificate: Bool { allowsInsecureTLS == true }
}

/// 当前正在浏览的范围。
enum CatalogSection: Hashable {
    case home
    case category(String)
    case rank
    case search(String)
    case continueWatching
    case favorites
}

/// 本地「稍后看」：只记录条目快照，不写远端、不进图库索引。
struct CatalogFavorite: Codable, Identifiable, Hashable {
    var sourceID: UUID
    var itemID: String
    var title: String
    var coverURL: String
    var remark: String
    var addedAt: Date

    var id: String { "\(sourceID.uuidString)|\(itemID)" }
}

struct CatalogItem: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var coverURL: String
    /// 「更新至 7 集 · 8.1 分」原样保留，站点改版时不影响结构。
    var remark: String
    var categoryID: String?
    /// 站点给的上架 / 更新日期：日历按它落位；站点没给时留空。
    var publishedAt: Date? = nil

    var episodeBadge: String? {
        let trimmed = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CatalogPage {
    var items: [CatalogItem]
    var page: Int
    /// 以「本页非空」为准：站点返回的 pagecount 只是占位值。
    var hasMore: Bool
}

struct CatalogEpisode: Identifiable, Hashable {
    var index: Int
    /// 分集播放页地址，不是 m3u8。
    var pageURL: String
    /// 单集封面；站点没有时由详情页回退到条目封面。
    var coverURL: String = ""
    /// 合集里的视频标题；普通剧集为空，仍显示「第 N 集」。
    var name: String? = nil
    /// 合集的时长或其它副信息。
    var duration: String? = nil

    var id: Int { index }
    var title: String { name ?? "第 \(index) 集" }
}

/// 图文正文的一个块：保留站点原始顺序，标题 / 段落 / 配图交错排版。
struct CatalogContentBlock: Hashable {
    enum Kind: Hashable {
        case heading
        case paragraph
        case image
    }

    var kind: Kind
    var text: String
}

/// 详情页的结构化信息：上线日期、出品方、播放量……由各源按自身返回字段填充。
struct CatalogDetailFact: Identifiable, Hashable {
    var label: String
    var value: String

    var id: String { "\(label)|\(value)" }
}

struct CatalogDetail {
    var item: CatalogItem
    var episodes: [CatalogEpisode]
    /// 图文条目的正文（视频条目通常为空）。
    var blocks: [CatalogContentBlock] = []
    /// 结构化信息，详情页用网格展示；没有的源留空。
    var facts: [CatalogDetailFact] = []
    /// 合集（一组互不相关的视频）而不是连续剧集：详情页按视频卡片展示，不写「第 N 集」。
    var isCollection: Bool = false
    /// 合集在站点上的总数量；只加载了部分页时用来提示。
    var collectionTotal: Int? = nil

    /// 正文里的全部配图，供大图预览左右翻页。
    var articleImages: [String] {
        blocks.compactMap { $0.kind == .image ? $0.text : nil }
    }

    var hasArticle: Bool { !blocks.isEmpty }
}

struct CatalogStream {
    var url: URL
    var headers: [String: String]
    var isHLS: Bool = true
}

/// 本地续看记录：只存条目与集号，播放地址短时效，不落盘。
struct CatalogProgress: Codable, Hashable {
    var sourceID: UUID
    var itemID: String
    var episode: Int
    var seconds: Double
    var duration: Double
    var title: String
    var coverURL: String
    var updatedAt: Date

    var key: String { CatalogProgress.key(sourceID: sourceID, itemID: itemID) }

    static func key(sourceID: UUID, itemID: String) -> String {
        "\(sourceID.uuidString)|\(itemID)"
    }

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, seconds / duration))
    }
}

/// 一次播放请求：播放器需要条目、完整分集与起播集号。
struct CatalogPlaybackRequest: Identifiable {
    let id = UUID()
    var source: CatalogSource
    var item: CatalogItem
    var episodes: [CatalogEpisode]
    var startEpisode: Int
    var startSeconds: Double
    var initialStream: CatalogStream?

    var startIndex: Int {
        episodes.firstIndex(where: { $0.index == startEpisode }) ?? 0
    }
}

/// 查看器里一个虚拟分集：把网络资源的每一集映射成一条可翻页的视频。
struct CatalogPlaybackContext {
    var source: CatalogSource
    var item: CatalogItem
    var episode: CatalogEpisode
}

enum CatalogError: LocalizedError {
    case unsupportedProvider
    case invalidConfig(String)
    case http(Int)
    case parse(String)
    case decryption
    case tls(String)
    case unavailable(String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "该源类型还没有对应的解析器"
        case .invalidConfig(let message):
            return "源配置无法识别：\(message)"
        case .http(let status):
            return "站点返回 HTTP \(status)"
        case .parse(let message):
            return "页面结构解析失败：\(message)"
        case .decryption:
            return "封面解密失败，源可能需要更新"
        case .tls(let host):
            return "与 \(host) 的 HTTPS 证书校验失败（可能是自签名、已过期或域名不匹配）。"
                + "确认站点可信后，可在导入页开启「允许不受信任的证书」再试。"
        case .unavailable(let detail):
            return detail ?? "资源暂时不可用"
        }
    }
}

enum CatalogPaths {
    static var root: URL { LibraryPaths.overlayRoot.appendingPathComponent("catalog", isDirectory: true) }

    static func artwork(scriptSourceID: UUID) -> URL {
        root.appendingPathComponent("artwork", isDirectory: true)
            .appendingPathComponent(scriptSourceID.uuidString, isDirectory: true)
    }

    static func artworkURL(sourceID: UUID, urlString: String, quick: Bool) -> URL {
        let digest = SHA256.hash(data: Data(urlString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let name = (quick ? "q-" : "") + String(digest.prefix(40)) + ".jpg"
        return artwork(scriptSourceID: sourceID).appendingPathComponent(name)
    }
}
