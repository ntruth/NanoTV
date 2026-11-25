import Foundation
import LumaContentCore

// MARK: - 网络电视

/// 电视频道搜索的检索词归一。
/// 用户习惯说「上海电视台」「湖南卫视台」这类带后缀的名字，而源里的频道名往往不带后缀，
/// 直接按整串匹配会一条都搜不到；这里统一拆成可用于包含匹配的关键词。
enum TVSearchQuery {
    private static let suffixes = ["广播电视台", "电视台", "频道", "直播", "高清", "uhd", "hd", "台"]

    /// 返回原词与去后缀后的词（去重）；「上海电视台」→ ["上海电视台", "上海"]。
    static func tokens(_ raw: String) -> [String] {
        let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        var tokens = [keyword]
        var value = keyword
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where value.count > suffix.count
                && value.lowercased().hasSuffix(suffix.lowercased()) {
                value = String(value.dropLast(suffix.count))
                changed = true
                break
            }
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != keyword { tokens.append(trimmed) }
        return tokens
    }

    /// 频道是否命中关键词：频道名 / 分组 / 省份归属逐项判断。
    /// 省份归属让「上海」也能找到东方卫视、哈哈炫动这类不带省名的本地台。
    static func matchesChannelIdentity(_ channel: TVChannel, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        if tokens.contains(where: { channel.name.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        if tokens.contains(where: { channel.group.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        let section = channel.province ?? TVProvinces.section(for: channel.name)
        return tokens.contains { section.localizedCaseInsensitiveContains($0) }
    }
}

/// 默认接入的地区。大陆优先央视与地方卫视，其他地区取自公开国家列表。
enum TVRegion: String, Codable, CaseIterable, Identifiable, Hashable {
    case mainland
    case hongKong
    case taiwan
    case usa
    case japan
    case korea
    case uk
    case france
    case germany
    case italy
    case singapore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainland: return "大陆"
        case .hongKong: return "香港"
        case .taiwan: return "台湾"
        case .usa: return "美国"
        case .japan: return "日本"
        case .korea: return "韩国"
        case .uk: return "英国"
        case .france: return "法国"
        case .germany: return "德国"
        case .italy: return "意大利"
        case .singapore: return "新加坡"
        }
    }
}

/// 一条 M3U 播放列表来源。默认不接入任何源，由用户自行接入。
struct TVPlaylist: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var urlString: String
    var region: TVRegion
    var isEnabled: Bool
    /// 最近一次连接检测的结果：延迟、频道数与错误信息。
    var lastCheckedAt: Date?
    var lastLatencyMilliseconds: Int?
    var lastChannelCount: Int?
    var lastError: String?
    /// XMLTV 节目单地址：优先从 M3U 头部的 `url-tvg` / `x-tvg-url` 读取，也可手动填写。
    var epgURLString: String?

    init(id: UUID = UUID(),
         name: String,
         urlString: String,
         region: TVRegion,
         isEnabled: Bool = true,
         epgURLString: String? = nil) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.region = region
        self.isEnabled = isEnabled
        self.epgURLString = epgURLString
    }
}

extension TVPlaylist {
    /// 界面上显示的来源地址：本地导入的列表只说明「本地播放列表」，不铺一串文件路径。
    var displayAddress: String {
        urlString.lowercased().hasPrefix("file://") ? "本地播放列表（已复制到图库）" : urlString
    }

    /// 补充节目单：epg.pw 中国区，709 个频道，未来 5 天齐全，用来补齐主 EPG 缺的未来排期。
    /// 两份 XMLTV 合并后按频道扣掉重复节目，正好覆盖前 3 天 / 后 3 天。
    static let supplementEPGURLString = "https://epg.pw/xmltv/epg_CN.xml"

    /// 旧版「测试源」加入的三条公开列表：功能已下线，升级时按地址一次性清理。
    static let retiredTestSourceURLs: Set<String> = [
        "https://gitee.com/c939984606/My-IPTV/raw/master/IPTV.m3u8",
        "https://iptv-org.github.io/iptv/languages/zho.m3u",
        "https://gh-proxy.org/raw.githubusercontent.com/Kimentanm/aptv/master/m3u/iptv.m3u"
    ]

    /// 旧版本自动接入过的内置源 id：三条默认源 + 更早的 11 条地区源。
    /// 升级时从图库库里移除，之后默认不再自动添加任何源。
    static var retiredBuiltInIDs: Set<UUID> {
        var ids: Set<UUID> = [
            UUID(uuidString: "6F1B7C2A-1000-4A11-9C01-000000000101")!,
            UUID(uuidString: "6F1B7C2A-1000-4A11-9C01-000000000102")!,
            UUID(uuidString: "6F1B7C2A-1000-4A11-9C01-000000000103")!
        ]
        for index in 1...11 {
            let suffix = String(format: "%012d", index)
            if let id = UUID(uuidString: "6F1B7C2A-1000-4A11-9C01-\(suffix)") {
                ids.insert(id)
            }
        }
        return ids
    }
}

/// 一条可播放的电视频道（同一频道只保留最高画质线路）。
struct TVChannel: Identifiable, Hashable {
    var id: String
    var name: String
    var group: String
    var logoURL: String?
    var streamURL: String
    var headers: [String: String]
    var isHLS: Bool
    var qualityLabel: String?
    var playlistID: UUID
    var region: TVRegion
    /// 地方台所属省份（大陆列表才有）：用于「按省份」聚合展示。
    var province: String? = nil
    /// M3U 的 `tvg-id`：EPG 节目单与回看映射的稳定键。
    var tvgID: String? = nil
    /// 回看地址模板（`catchup-source`），可能含 `${start}` / `${end}` 等占位符。
    var catchUpSource: String? = nil
    /// 源声明的回看天数。
    var catchUpDays: Int? = nil
    /// 实际可回看天数：源没声明时按 3 天收敛——实测公共源的回看窗口多为 3～4 天，
    /// 给 7 天只会让后面几天点开是空的。
    var effectiveCatchUpDays: Int { max(1, catchUpDays ?? 3) }
    /// 当前播放的是回看而不是直播：只影响播放模式与界面标识。
    var isCatchUp: Bool = false
    /// M3U 里同一频道的候选线路数（含当前线路）；信号页显示「N 线路」。
    var lineCount: Int = 1
    /// 备用线路：播放失败时按顺序顺延，信号详情里可设为默认。
    var alternateStreamURLs: [String] = []

    /// 线路列表：当前线路在最前，后面是去重后的备用线路。
    var streamLines: [String] {
        var seen = Set<String>()
        return ([streamURL] + alternateStreamURLs).filter { seen.insert($0).inserted }
    }

    /// 同名频道匹配用的归一化名称：去掉空白与画质后缀，便于跨源找备用线路。
    static func normalizedName(_ name: String) -> String {
        var value = name.lowercased().replacingOccurrences(of: " ", with: "")
        let suffixes = ["超高清", "高清", "超清", "蓝光", "4k", "ipv6", "hd", "sd"]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where value.hasSuffix(suffix) && value.count > suffix.count {
                value.removeLast(suffix.count)
                changed = true
            }
        }
        return value
    }
}

/// 频道展示顺序，贴合国内用户的找台习惯：
/// 央视 1~N → 中央其他（CGTN / 4K / 海外版）→ 凤凰 → 各省（卫视优先）→ 港澳台 / 海外。
/// 只决定展示顺序，不影响源本身的接入顺序。
enum TVChannelOrder {
    private struct Key {
        var bucket: Int
        var ordinal: Int
        var provinceRank: Int
        var satellite: Int
    }

    static func sorted(_ channels: [TVChannel]) -> [TVChannel] {
        channels
            .map { (key: key(for: $0), channel: $0) }
            .sorted { lhs, rhs in
                if lhs.key.bucket != rhs.key.bucket { return lhs.key.bucket < rhs.key.bucket }
                switch lhs.key.bucket {
                case 0:
                    if lhs.key.ordinal != rhs.key.ordinal { return lhs.key.ordinal < rhs.key.ordinal }
                case 3:
                    if lhs.key.provinceRank != rhs.key.provinceRank {
                        return lhs.key.provinceRank < rhs.key.provinceRank
                    }
                    if lhs.key.satellite != rhs.key.satellite {
                        return lhs.key.satellite < rhs.key.satellite
                    }
                default:
                    break
                }
                return lhs.channel.name.localizedStandardCompare(rhs.channel.name) == .orderedAscending
            }
            .map(\.channel)
    }

    private static func key(for channel: TVChannel) -> Key {
        let name = channel.name
        // 央视 1~N：CCTV-1 / CCTV1 / 央视一套 / 中央八台。
        // 4K / 海外版（CCTV-4 America）这类变体归到「中央其他」，排在正牌 1~N 后面。
        if let ordinal = cctvOrdinal(name) {
            let variant = hasVariantMarker(name)
            return Key(bucket: variant ? 1 : 0,
                       ordinal: variant ? 0 : ordinal,
                       provinceRank: 0,
                       satellite: 0)
        }
        // 其余中央台：CGTN、CCTV-4K、CCTV-4 America、央视新闻…
        if TVProvinces.isCentral(name) {
            return Key(bucket: 1, ordinal: 0, provinceRank: 0, satellite: 0)
        }
        // 凤凰单独一档：中文 / 资讯 / 香港。
        if name.contains("凤凰") {
            return Key(bucket: 2, ordinal: 0, provinceRank: 0, satellite: 0)
        }
        // 港澳台 / 海外频道排在各省之后。
        if channel.region != .mainland || isForeignGroup(channel.group) {
            return Key(bucket: 4, ordinal: 0, provinceRank: 0, satellite: 0)
        }
        // 各省：按行政区顺序，省会级卫视排省内第一。
        let section = channel.province ?? TVProvinces.section(for: name)
        return Key(bucket: 3,
                   ordinal: 0,
                   provinceRank: TVProvinces.rank(section),
                   satellite: TVProvinces.isSatellite(name) ? 0 : 1)
    }

    // MARK: 央视频道号

    /// 从台名里解析央视的台号：CCTV-1 / CCTV1 / 央视一套 / 中央八台。
    /// 「央视4K超高清」也会解析出 4，但会被 `hasVariantMarker` 归到变体，排在正牌 4 之后。
    private static func cctvOrdinal(_ name: String) -> Int? {
        let compact = name.uppercased().replacingOccurrences(of: " ", with: "")
        if let range = compact.range(of: #"CCTV[-_－]?(\d{1,2})"#, options: .regularExpression) {
            let digits = compact[range].filter(\.isNumber)
            if let value = Int(digits) { return value }
        }
        for prefix in ["央视", "中央"] {
            guard let range = compact.range(of: prefix) else { continue }
            let rest = compact[range.upperBound...]
            var token = ""
            for character in rest {
                if character.isNumber || chineseDigit(character) != nil {
                    token.append(character)
                } else {
                    break
                }
            }
            if let value = parseNumberToken(token), value >= 1 { return value }
        }
        return nil
    }

    private static func parseNumberToken(_ token: String) -> Int? {
        guard !token.isEmpty else { return nil }
        if let value = Int(token) { return value }
        var total = 0
        var current = 0
        for character in token {
            guard let value = chineseDigit(character) else { continue }
            if value == 10 {
                total += (current == 0 ? 1 : current) * 10
                current = 0
            } else {
                current = current * 10 + value
            }
        }
        let result = total + current
        return result > 0 ? result : nil
    }

    private static func chineseDigit(_ character: Character) -> Int? {
        switch character {
        case "零": return 0
        case "一": return 1
        case "二", "两": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "七": return 7
        case "八": return 8
        case "九": return 9
        case "十": return 10
        default: return nil
        }
    }

    /// 海外版 / 4K / Plus 这类变体：同台号的正牌频道在前，变体随后。
    private static func hasVariantMarker(_ name: String) -> Bool {
        let upper = name.uppercased()
        if upper.contains("4K") || upper.contains("8K") || upper.contains("UHD") { return true }
        let letters = upper.filter { $0.isASCII && $0.isLetter }
        return !letters.replacingOccurrences(of: "CCTV", with: "").isEmpty
    }

    private static func isForeignGroup(_ group: String) -> Bool {
        ["港澳", "香港", "澳门", "台湾", "国际", "海外"]
            .contains { group.contains($0) }
    }
}

/// 一条直播线路的播放元数据：并入其它源的同名频道后，各线路的协议与请求头可能不同
/// （运营商 IPTV 常是 HLS 且不需要 UA，公网源常是 HTTP-FLV 且必须带 UA）。
struct TVLineMetadata: Hashable {
    var headers: [String: String]
    var isHLS: Bool

    /// 地址本身是否 HLS：只有显式 .m3u8 才算，`.php` / 无扩展名交给地址推断。
    static func inferredHLS(for url: String) -> Bool {
        url.lowercased().contains(".m3u8")
    }
}

/// 一个源下的分类（按类型分组），用于侧边栏的二级层级。
struct TVCategory: Identifiable, Hashable {
    var group: String
    var count: Int

    var id: String { group }
}

/// 网络电视总览的分页：直播 / 夜航 / 节目回看 / 信号 / 源库。
/// 「夜航」把赛事、黄金时段、综艺与人物纪录按晚间时段重新编排。
enum TVHubTab: String, CaseIterable, Identifiable, Hashable {
    case channels
    case tonight
    case guide
    case status
    case overview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .channels: return "直播"
        case .tonight: return "夜航"
        case .guide: return "节目回看"
        case .status: return "信号"
        case .overview: return "源库"
        }
    }

    var symbol: String {
        switch self {
        case .channels: return "tv"
        case .tonight: return "moon.stars.fill"
        case .guide: return "calendar.badge.clock"
        case .status: return "waveform.path.ecg"
        case .overview: return "externaldrive"
        }
    }

    /// 上次停留的分页：旧的「总览 / 频道 / 状态」映射到新的「源库 / 直播 / 信号」。
    static func persisted(_ raw: String?) -> TVHubTab {
        switch raw {
        case "sources": return .overview
        case "live": return .channels
        case "catchup": return .guide
        case let value?: return TVHubTab(rawValue: value) ?? .channels
        case nil: return .channels
        }
    }
}

/// 频道墙的分组方式：按频道类型（新闻 / 体育…）、按省份聚合地方台，或按国家 / 地区。
enum TVGroupingMode: String, CaseIterable, Identifiable, Hashable {
    case category
    case province
    case country

    var id: String { rawValue }

    var title: String {
        switch self {
        case .category: return "按类型"
        case .province: return "按省份"
        case .country: return "按国家"
        }
    }
}

/// 频道所属国家 / 地区：「按国家」聚合与筛选共用。
/// 先看分组标题与台名里的国家关键词（iptv-org 这类多国混排的列表只能靠它），
/// 认不出来再退回列表声明的地区。
enum TVCountries {
    static let order = ["中国大陆", "香港", "澳门", "台湾", "日本", "韩国",
                        "美国", "英国", "法国", "德国", "意大利", "新加坡", "其他"]

    static func country(for channel: TVChannel) -> String {
        let text = "\(channel.group) \(channel.name)".lowercased()
        for (country, keywords) in table where keywords.contains(where: { text.contains($0) }) {
            return country
        }
        return country(for: channel.region)
    }

    static func country(for region: TVRegion) -> String {
        switch region {
        case .mainland: return "中国大陆"
        case .hongKong: return "香港"
        case .taiwan: return "台湾"
        case .usa: return "美国"
        case .japan: return "日本"
        case .korea: return "韩国"
        case .uk: return "英国"
        case .france: return "法国"
        case .germany: return "德国"
        case .italy: return "意大利"
        case .singapore: return "新加坡"
        }
    }

    static func rank(_ country: String) -> Int {
        order.firstIndex(of: country) ?? order.count
    }

    /// 关键词按「越具体越靠前」排列：同时出现「香港」和「卫视」时按香港算。
    /// 港澳台频道常用繁体台名，简繁两种写法都要认。
    private static let table: [(String, [String])] = [
        ("香港", ["香港", "凤凰", "鳳凰", "hong kong", "tvb", "翡翠台", "hkstv"]),
        ("澳门", ["澳门", "澳門", "macau", "macao"]),
        ("台湾", ["台湾", "臺灣", "taiwan", "台视", "台視", "中视", "中視",
                 "华视", "華視", "民视", "民視", "公视", "公視", "原住民", "客家", "hakka"]),
        ("日本", ["日本", "japan", "nhk"]),
        ("韩国", ["韩国", "韓國", "korea", "kbs", "mbc", "sbs"]),
        ("美国", ["美国", "美國", "usa", "cnn", "nbc", "bloomberg", "fox news"]),
        ("英国", ["英国", "英國", "bbc", "itv", "sky news"]),
        ("法国", ["法国", "法國", "france"]),
        ("德国", ["德国", "德國", "germany", "deutsche"]),
        ("意大利", ["意大利", "italy", "rai"]),
        ("新加坡", ["新加坡", "singapore"])
    ]
}

/// 频道墙的快捷筛选：收藏 / 最近。
enum TVQuickFilter: String, CaseIterable, Identifiable, Hashable {
    case favorites
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "收藏"
        case .recent: return "最近"
        }
    }

    var symbol: String {
        switch self {
        case .favorites: return "star.fill"
        case .recent: return "clock"
        }
    }
}

/// 关注的球队 / 联赛：节目标题里命中关键词，就被当成「我的主队」。
/// 关注只影响夜航的高亮、筛选与提醒，不会修改节目单。
struct TVSportFollow: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, Hashable {
        case team
        case league
    }

    var keyword: String
    var kind: Kind
    var createdAt: Date

    var id: String { keyword }
}

/// 一条电视录制：定时等待 → 录制中 → 完成 / 失败 / 取消。
/// 录制本身复用 `IngestService` 的远端片段能力，文件落在图库里。
struct TVRecording: Codable, Identifiable, Hashable {
    enum State: String, Codable, Hashable {
        case scheduled
        case recording
        case finished
        case failed
        case cancelled
    }

    var id: UUID
    var channelID: String
    var channelName: String
    /// 所属播放列表：登记任务中心时用作源 ID。
    var playlistID: UUID
    var title: String
    var streamURL: String
    var headers: [String: String]
    var isHLS: Bool
    var start: Date
    /// 计划录制时长（秒）。
    var duration: TimeInterval
    var state: State
    /// 完成后落进图库的条目 id。
    var photoID: String?
    var note: String?
    var createdAt: Date

    var end: Date { start.addingTimeInterval(duration) }
    var isPending: Bool { state == .scheduled || state == .recording }
    /// 错过开始太久（10 分钟）就不再补录，避免打开应用时突然抓一堆旧节目。
    var isExpired: Bool { Date().timeIntervalSince(start) > 600 }
}

/// 频道分组：把 iptv-org 的英文 group-title 映射成中文，并固定展示顺序。
enum TVGrouping {
    static let order: [String] = [
        "央视", "卫视", "港澳台", "地方", "新闻", "综合", "财经", "体育", "电影", "剧集",
        "娱乐", "少儿", "纪实", "文化", "音乐", "生活", "购物", "宗教",
        "家庭", "教育", "科教", "天气", "旅游", "汽车", "美食", "户外", "未分类", "其他"
    ]

    static func display(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "其他" }
        switch raw.lowercased() {
        case "news": return "新闻"
        case "general": return "综合"
        case "business": return "财经"
        case "sports": return "体育"
        case "movies": return "电影"
        case "series": return "剧集"
        case "entertainment": return "娱乐"
        case "kids", "children": return "少儿"
        case "documentary": return "纪实"
        case "culture": return "文化"
        case "music": return "音乐"
        case "lifestyle": return "生活"
        case "shop": return "购物"
        case "religious": return "宗教"
        case "animation": return "少儿"
        case "family": return "家庭"
        case "education": return "教育"
        case "science": return "科教"
        case "weather": return "天气"
        case "travel": return "旅游"
        case "auto": return "汽车"
        case "cooking", "food": return "美食"
        case "outdoor": return "户外"
        case "undefined": return "其他"
        default: return raw
        }
    }

    static func rank(_ group: String) -> Int {
        order.firstIndex(of: group) ?? order.count
    }

    /// 大陆列表里按频道名细分央视 / 卫视，优先于原 group-title。
    static func refine(_ group: String, name: String, region: TVRegion) -> String {
        guard region == .mainland else { return group }
        let upper = name.uppercased()
        if upper.hasPrefix("CCTV") || upper.hasPrefix("CGTN") { return "央视" }
        if name.contains("卫视") || upper.contains("SATELLITE") { return "卫视" }
        return group
    }
}
