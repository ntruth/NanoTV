import Foundation

/// 「人物」页的聚合筛选：全部 / 已命名 / 待命名 / 宠物。
/// 参考「位置」页的聚合层级切换，只影响卡片分组与展示，不改变识别结果。
enum PeopleGroupFilter: String, CaseIterable, Identifiable {
    case all
    case named
    case unnamed
    case pets

    var id: String { rawValue }

    /// 切换控件上的标签。
    var shortTitle: String {
        switch self {
        case .all: return "全部"
        case .named: return "已命名"
        case .unnamed: return "待命名"
        case .pets: return "宠物"
        }
    }

    var title: String { shortTitle }

    var icon: String {
        switch self {
        case .all: return "person.2"
        case .named: return "person.crop.circle.badge.checkmark"
        case .unnamed: return "person.crop.circle.badge.questionmark"
        case .pets: return "pawprint"
        }
    }

    var help: String {
        switch self {
        case .all: return "显示全部人物与宠物"
        case .named: return "只看已命名的人物"
        case .unnamed: return "只看尚未命名的聚类"
        case .pets: return "只看宠物"
        }
    }

    /// 筛选后为空时的标题与说明。
    var emptyTitle: String {
        switch self {
        case .all: return "没有人物"
        case .named: return "还没有已命名的人物"
        case .unnamed: return "没有待命名的人物"
        case .pets: return "还没有识别到宠物"
        }
    }

    var emptyHint: String {
        switch self {
        case .all: return "连接 macOS 官方「照片」图库或分析本机照片后，这里会显示人物与宠物。"
        case .named: return "在官方「照片」里给人物命名后，这里会自动出现；本机聚类可右键卡片重命名。"
        case .unnamed: return "所有聚类都已命名，或当前图库还没有可用的识别结果。"
        case .pets: return "宠物结果来自官方「照片」的端侧识别；本机人脸聚类不区分人物与宠物。"
        }
    }
}

/// 经常同框的人：人物摘要与地点摘要共用。
struct PhotoCompanion: Identifiable, Equatable {
    let id: String
    let name: String
    let count: Int
    /// 头像来源：拾光本地照片 ID 或系统图库关键照片 ID。
    let coverPhotoID: UUID?
    /// 官方图库直接给出的人脸裁切图。
    let coverData: Data?
}

/// 人物详情「摘要」的派生数据：只由当前人物的可见照片与同框关系计算，纯内存、不落库。
struct PersonInsight {
    struct YearCount: Identifiable, Equatable {
        let year: Int
        let count: Int
        var id: Int { year }
    }

    struct PlaceCount: Identifiable, Equatable {
        let name: String
        let count: Int
        var id: String { name }
    }

    struct PeriodSlice: Identifiable, Equatable {
        let title: String
        let count: Int
        let fraction: Double
        var id: String { title }
    }

    /// 与当前人物经常同框的其他人（本地聚类或官方识别结果）。
    typealias Companion = PhotoCompanion

    var photoCount: Int = 0
    var videoCount: Int = 0
    var firstDate: Date?
    var lastDate: Date?
    var years: [YearCount] = []
    var places: [PlaceCount] = []
    /// 按时段（清晨 / 白天 / 傍晚 / 夜晚）统计，顺序固定。
    var periods: [PeriodSlice] = []
    var companions: [Companion] = []
    /// 每年挑一张最值得回看的照片，按拍摄时间倒序。
    var highlights: [PhotoItem] = []
    /// 用于「色彩气质」采样的照片，最多 10 张。
    var palettePhotos: [PhotoItem] = []

    var totalCount: Int { photoCount + videoCount }

    var activeYear: YearCount? {
        years.max { lhs, rhs in
            lhs.count == rhs.count ? lhs.year < rhs.year : lhs.count < rhs.count
        }
    }

    var dominantPeriod: PeriodSlice? {
        periods.max { $0.fraction < $1.fraction }
    }

    /// 摘要页头图的候选：优先横图，避免大封面被竖图裁得只剩一条。
    var coverPhoto: PhotoItem? {
        highlights.first { $0.aspectRatio >= 1.05 } ?? highlights.first
    }

    var countText: String {
        var parts: [String] = []
        if photoCount > 0 { parts.append("\(photoCount.formatted()) 张照片") }
        if videoCount > 0 { parts.append("\(videoCount.formatted()) 个视频") }
        if parts.isEmpty { parts.append("0 张照片") }
        return parts.joined(separator: "、")
    }

    var dateRangeText: String {
        guard let firstDate, let lastDate else { return "" }
        let first = DateText.monthFormatter.string(from: firstDate)
        let last = DateText.monthFormatter.string(from: lastDate)
        return first == last ? first : "\(first) – \(last)"
    }

    var subtitle: String {
        let range = dateRangeText
        return range.isEmpty ? countText : "\(countText) · \(range)"
    }

    /// 一句话人物画像：只陈述能从照片里直接得出的结论。
    var narrative: String {
        var parts: [String] = []
        if let firstDate, let lastDate, firstDate != lastDate {
            parts.append("\(DateText.monthFormatter.string(from: firstDate)) 到 \(DateText.monthFormatter.string(from: lastDate))，镜头里留下了 \(totalCount.formatted()) 个瞬间")
        } else if totalCount > 0 {
            parts.append("镜头里留下了 \(totalCount.formatted()) 个瞬间")
        }
        if let activeYear, activeYear.count > 0, years.count > 1 {
            parts.append("\(activeYear.year) 年出现得最频繁（\(activeYear.count.formatted()) 张）")
        }
        if !places.isEmpty {
            let names = places.prefix(2).map(\.name).joined(separator: "、")
            parts.append(places.count > 2 ? "足迹常落在 \(names) 等地" : "足迹常落在 \(names)")
        }
        if let companion = companions.first {
            parts.append("最常与 \(companion.name) 同框")
        }
        if let period = dominantPeriod, period.fraction >= 0.35, period.title != "白天" {
            parts.append("偏爱\(period.title)的画面")
        }
        guard !parts.isEmpty else { return "还没有足够的影像来描绘这段故事。" }
        return parts.joined(separator: "；") + "。"
    }

    // MARK: - 从照片生成

    /// 本地图库 / 系统图库快照模式：照片已经在内存里，直接派生。
    static func make(photos: [PhotoItem]) -> PersonInsight {
        let sorted = photos.sorted { $0.capturedAt > $1.capturedAt }
        var insight = PersonInsight()
        insight.photoCount = sorted.reduce(0) { $0 + ($1.isVideo ? 0 : 1) }
        insight.videoCount = sorted.count - insight.photoCount
        insight.firstDate = sorted.last?.capturedAt
        insight.lastDate = sorted.first?.capturedAt
        insight.years = yearCounts(sorted)
        insight.places = placeCounts(sorted)
        insight.periods = periodSlices(sorted)
        insight.highlights = PhotoInsightSamples.highlights(sorted)
        insight.palettePhotos = PhotoInsightSamples.paletteSamples(sorted, highlights: insight.highlights)
        return insight
    }

    /// SQL 聚合模式（系统图库索引）：各字段由 `SystemIndex` 直接给出。
    static func make(photoCount: Int,
                     videoCount: Int,
                     firstDate: Date?,
                     lastDate: Date?,
                     years: [YearCount],
                     places: [PlaceCount],
                     periods: [PeriodSlice],
                     companions: [Companion],
                     highlights: [PhotoItem],
                     palettePhotos: [PhotoItem]) -> PersonInsight {
        PersonInsight(photoCount: photoCount,
                      videoCount: videoCount,
                      firstDate: firstDate,
                      lastDate: lastDate,
                      years: years,
                      places: places,
                      periods: periods,
                      companions: companions,
                      highlights: highlights,
                      palettePhotos: palettePhotos)
    }

    /// 把「小时 → 张数」翻译成固定的四段时段。
    static func periods(fromHourCounts counts: [Int: Int]) -> [PeriodSlice] {
        let titles = ["清晨", "白天", "傍晚", "夜晚"]
        var buckets = [Int](repeating: 0, count: titles.count)
        for (hour, count) in counts {
            switch hour {
            case 5..<9: buckets[0] += count
            case 9..<17: buckets[1] += count
            case 17..<20: buckets[2] += count
            default: buckets[3] += count
            }
        }
        let total = max(1, buckets.reduce(0, +))
        return titles.enumerated().map { index, title in
            PeriodSlice(title: title,
                        count: buckets[index],
                        fraction: Double(buckets[index]) / Double(total))
        }
    }

    // MARK: - 统计细节

    private static func yearCounts(_ photos: [PhotoItem]) -> [YearCount] {
        var counts: [Int: Int] = [:]
        for photo in photos {
            let year = Calendar.current.component(.year, from: photo.capturedAt)
            counts[year, default: 0] += 1
        }
        return counts.map { YearCount(year: $0.key, count: $0.value) }
            .sorted { $0.year < $1.year }
    }

    private static func placeCounts(_ photos: [PhotoItem]) -> [PlaceCount] {
        var counts: [String: Int] = [:]
        for photo in photos {
            guard let name = photo.placeCity ?? photo.placeDistrict
                ?? photo.placeProvince ?? photo.placePOI,
                !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        return counts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        .prefix(4)
        .map { PlaceCount(name: $0.key, count: $0.value) }
    }

    private static func periodSlices(_ photos: [PhotoItem]) -> [PeriodSlice] {
        var counts: [Int: Int] = [:]
        for photo in photos {
            let hour = Calendar.current.component(.hour, from: photo.capturedAt)
            counts[hour, default: 0] += 1
        }
        return periods(fromHourCounts: counts)
    }
}

/// 人物 / 地点摘要共用的照片挑选规则：高光时刻与色彩采样。
enum PhotoInsightSamples {
    /// 每年一张「高光」：收藏优先，其次分辨率与编辑状态，其余用收藏 / 最近的照片补齐。
    static func highlights(_ photos: [PhotoItem], limit: Int = 8) -> [PhotoItem] {
        let candidates = photos.filter { !$0.isVideo }
        guard !candidates.isEmpty else { return [] }
        var picks: [PhotoItem] = []
        var used = Set<UUID>()

        let byYear = Dictionary(grouping: candidates) {
            Calendar.current.component(.year, from: $0.capturedAt)
        }
        for year in byYear.keys.sorted(by: >) {
            guard picks.count < limit else { break }
            guard let best = byYear[year]?.max(by: { highlightScore($0) < highlightScore($1) }) else { continue }
            picks.append(best)
            used.insert(best.id)
        }

        let fallback = candidates
            .filter { !used.contains($0.id) }
            .sorted {
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite && !$1.isFavorite }
                return $0.capturedAt > $1.capturedAt
            }
        for photo in fallback where picks.count < limit {
            picks.append(photo)
            used.insert(photo.id)
        }
        return picks.sorted { $0.capturedAt > $1.capturedAt }
    }

    static func paletteSamples(_ photos: [PhotoItem],
                               highlights: [PhotoItem],
                               limit: Int = 10) -> [PhotoItem] {
        var result = highlights
        var seen = Set(result.map(\.id))
        for photo in photos where result.count < limit {
            guard !photo.isVideo, seen.insert(photo.id).inserted else { continue }
            result.append(photo)
        }
        return Array(result.prefix(limit))
    }

    private static func highlightScore(_ photo: PhotoItem) -> Double {
        var score = Double(photo.pixelWidth * photo.pixelHeight) / 1_000_000
        if photo.isFavorite { score += 60 }
        if photo.hasEdits { score += 12 }
        return score
    }
}
