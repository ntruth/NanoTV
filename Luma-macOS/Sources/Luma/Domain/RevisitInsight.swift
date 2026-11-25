import Foundation

/// 一个可重看的人物 / 地点 / 场景 / 年份主体。
enum RevisitSubjectKind: String, CaseIterable, Identifiable {
    case people
    case places
    case scenes
    case years

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: return "人物"
        case .places: return "地点"
        case .scenes: return "场景"
        case .years: return "年份"
        }
    }

    var icon: String {
        switch self {
        case .people: return "person.2"
        case .places: return "mappin.and.ellipse"
        case .scenes: return "sparkles"
        case .years: return "calendar"
        }
    }

    var emptyHint: String {
        switch self {
        case .people: return "完成人物分析后，这里会按人物归并旧照片。"
        case .places: return "旧照片需要带 GPS 地点信息才会按地点归并。"
        case .scenes: return "完成端侧场景分析后，这里会按内容继续细分。"
        case .years: return "还没有足够早的照片可以按年份回看。"
        }
    }
}

/// 人物主体输入：只带重看分组需要的最小字段。
struct RevisitPersonSeed: Identifiable {
    let id: String
    let name: String
    let assetIDs: [UUID]
    let coverPhotoID: UUID?
    let coverData: Data?
}

/// 「值得重看」的派生数据：把所有旧照片按人物 / 地点 / 场景 / 年份拆成可重看的主体。
/// 纯内存计算，不落库、不上传。
struct RevisitInsight {
    struct YearCount: Identifiable, Equatable {
        let year: Int
        let count: Int
        var id: Int { year }
    }

    struct Subject: Identifiable {
        let id: String
        let kind: RevisitSubjectKind
        let title: String
        let subtitle: String
        let icon: String
        /// 按拍摄时间升序，详情页默认「最早优先」。
        let photos: [PhotoItem]
        /// 人物主体的人脸裁切头像。
        let coverData: Data?
        /// 详情页的年份分层：点某一层就只看那一年的旧照片。
        let yearCounts: [YearCount]
        let photosByYear: [Int: [PhotoItem]]
        /// 摘要文案：年份跨度 · 地点数 · 从未打开的张数。
        let narrative: String
        let placeCount: Int
        let unseenCount: Int

        var count: Int { photos.count }
        var cover: PhotoItem? { photos.first }
        var firstYear: Int? { yearCounts.first?.year }
        var lastYear: Int? { yearCounts.last?.year }
    }

    var photos: [PhotoItem] = []
    var onlyUnseen = false
    var unseenCount = 0
    var oldestDate: Date?
    /// 最久没有被打开的照片，用于今日之选与「时光碎片」。
    var forgottenPhotos: [PhotoItem] = []
    var initialKind: RevisitSubjectKind = .people
    private var buckets: [RevisitSubjectKind: [Subject]] = [:]

    var totalCount: Int { photos.count }

    var summaryText: String {
        var parts: [String] = ["\(totalCount.formatted()) 张值得重看"]
        if let oldestDate {
            parts.append("最早来自 \(Calendar.current.component(.year, from: oldestDate)) 年")
        }
        if unseenCount > 0 {
            parts.append("\(unseenCount.formatted()) 张从未打开")
        }
        return parts.joined(separator: " · ")
    }

    func subjects(for kind: RevisitSubjectKind) -> [Subject] {
        buckets[kind] ?? []
    }

    func allSubject() -> Subject? {
        guard !photos.isEmpty else { return nil }
        return Self.makeSubject(id: "all",
                                kind: .years,
                                title: "所有值得重看",
                                subtitle: summaryText,
                                icon: "clock.arrow.circlepath",
                                photos: photos,
                                coverData: nil)
    }

    static func make(photos: [PhotoItem],
                     onlyUnseen: Bool,
                     people: [RevisitPersonSeed],
                     analysis: [UUID: PhotoAnalysis]) -> RevisitInsight {
        let sorted = photos
            .filter { $0.deletedAt == nil && !$0.isHidden }
            .sorted { $0.capturedAt < $1.capturedAt }
        var insight = RevisitInsight()
        insight.photos = sorted
        insight.onlyUnseen = onlyUnseen
        insight.unseenCount = sorted.reduce(0) { $0 + ($1.viewedAt == nil ? 1 : 0) }
        insight.oldestDate = sorted.first?.capturedAt
        insight.forgottenPhotos = forgottenRanking(sorted)
        insight.buckets = [
            .people: peopleSubjects(sorted, people: people),
            .places: placeSubjects(sorted),
            .scenes: sceneSubjects(sorted, analysis: analysis),
            .years: yearSubjects(sorted)
        ]
        insight.initialKind = RevisitSubjectKind.allCases.first {
            !(insight.buckets[$0] ?? []).isEmpty
        } ?? .years
        return insight
    }

    // MARK: - 分组

    private static func peopleSubjects(_ photos: [PhotoItem],
                                       people: [RevisitPersonSeed]) -> [Subject] {
        guard !photos.isEmpty, !people.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        return people.compactMap { person -> Subject? in
            let shared = person.assetIDs.compactMap { byID[$0] }
            guard shared.count >= 2 else { return nil }
            let ordered = shared.sorted { $0.capturedAt < $1.capturedAt }
            return makeSubject(id: "person-\(person.id)",
                               kind: .people,
                               title: person.name,
                               subtitle: "\(shared.count.formatted()) 张 · \(spanText(ordered))",
                               icon: "person.fill",
                               photos: ordered,
                               coverData: person.coverData)
        }
        .sorted { $0.count > $1.count }
        .prefix(10)
        .map { $0 }
    }

    private static func placeSubjects(_ photos: [PhotoItem]) -> [Subject] {
        PlaceClusterBuilder.clusters(from: photos)
            .filter { $0.count >= 2 }
            .prefix(8)
            .map { cluster in
                makeSubject(id: "place-\(cluster.id)",
                            kind: .places,
                            title: cluster.title,
                            subtitle: "\(cluster.count.formatted()) 张 · \(cluster.subtitle ?? cluster.group)",
                            icon: "mappin.and.ellipse",
                            photos: cluster.photos.sorted { $0.capturedAt < $1.capturedAt },
                            coverData: nil)
            }
    }

    /// 只保留适合作「回忆」的场景，票据 / 证件这类工具性分类不参与重看。
    private static let revisitSceneIDs = ["nature", "architecture", "night", "activities",
                                          "food", "landmarks", "plants", "pets", "animals",
                                          "transport"]

    private static func sceneSubjects(_ photos: [PhotoItem],
                                      analysis: [UUID: PhotoAnalysis]) -> [Subject] {
        guard !analysis.isEmpty else { return [] }
        var subjects: [Subject] = []
        for id in revisitSceneIDs {
            guard let category = SceneCatalog.category(id: id) else { continue }
            let matched = photos.filter { photo in
                guard let result = analysis[photo.id] else { return false }
                return SceneCatalog.matches(category, analysis: result, photo: photo)
            }
            guard matched.count >= 3 else { continue }
            subjects.append(makeSubject(id: "scene-\(category.id)",
                                        kind: .scenes,
                                        title: category.title,
                                        subtitle: "\(matched.count.formatted()) 张旧照片",
                                        icon: category.icon,
                                        photos: matched.sorted { $0.capturedAt < $1.capturedAt },
                                        coverData: nil))
        }
        return subjects
            .sorted { $0.count > $1.count }
            .prefix(8)
            .map { $0 }
    }

    private static func yearSubjects(_ photos: [PhotoItem]) -> [Subject] {
        Dictionary(grouping: photos) {
            Calendar.current.component(.year, from: $0.capturedAt)
        }
        .map { year, items in
            makeSubject(id: "year-\(year)",
                        kind: .years,
                        title: "\(year) 年",
                        subtitle: "\(items.count.formatted()) 张旧照片",
                        icon: "calendar",
                        photos: items.sorted { $0.capturedAt < $1.capturedAt },
                        coverData: nil)
        }
        .sorted { $0.id < $1.id }
    }

    /// 统一算好年份分层、地点数与未打开数，详情页只做展示不再遍历照片。
    private static func makeSubject(id: String,
                                    kind: RevisitSubjectKind,
                                    title: String,
                                    subtitle: String,
                                    icon: String,
                                    photos: [PhotoItem],
                                    coverData: Data?) -> Subject {
        var byYear: [Int: [PhotoItem]] = [:]
        byYear.reserveCapacity(8)
        var places = Set<String>()
        var unseen = 0
        for photo in photos {
            let year = Calendar.current.component(.year, from: photo.capturedAt)
            byYear[year, default: []].append(photo)
            if photo.viewedAt == nil { unseen += 1 }
            if let place = photo.placeCity ?? photo.placeDistrict ?? photo.placePOI,
               !place.isEmpty {
                places.insert(place)
            }
        }
        let yearCounts = byYear.keys.sorted().map {
            YearCount(year: $0, count: byYear[$0]?.count ?? 0)
        }
        return Subject(id: id,
                       kind: kind,
                       title: title,
                       subtitle: subtitle,
                       icon: icon,
                       photos: photos,
                       coverData: coverData,
                       yearCounts: yearCounts,
                       photosByYear: byYear,
                       narrative: narrative(yearCounts: yearCounts,
                                            placeCount: places.count,
                                            unseenCount: unseen),
                       placeCount: places.count,
                       unseenCount: unseen)
    }

    private static func narrative(yearCounts: [YearCount],
                                  placeCount: Int,
                                  unseenCount: Int) -> String {
        var parts: [String] = []
        if let first = yearCounts.first?.year, let last = yearCounts.last?.year {
            parts.append(first == last ? "\(first) 年" : "\(first) – \(last)")
        }
        if placeCount > 0 { parts.append("\(placeCount) 个地点") }
        if unseenCount > 0 { parts.append("\(unseenCount) 张从未打开") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 排序与文案

    /// 越久没打开、越旧、越接近收藏的照片越靠前。
    private static func forgottenRanking(_ photos: [PhotoItem]) -> [PhotoItem] {
        let now = Date()
        return photos.sorted {
            forgottenScore($0, now: now) > forgottenScore($1, now: now)
        }
        .prefix(12)
        .map { $0 }
    }

    private static func forgottenScore(_ photo: PhotoItem, now: Date) -> Double {
        var score = 0.0
        if let viewedAt = photo.viewedAt {
            score += min(400, now.timeIntervalSince(viewedAt) / 86_400)
        } else {
            score += 500
        }
        score += min(300, now.timeIntervalSince(photo.capturedAt) / 86_400 / 30)
        if photo.isFavorite { score += 25 }
        return score
    }

    private static func spanText(_ photos: [PhotoItem]) -> String {
        guard let first = photos.first, let last = photos.last else { return "" }
        let firstYear = Calendar.current.component(.year, from: first.capturedAt)
        let lastYear = Calendar.current.component(.year, from: last.capturedAt)
        return firstYear == lastYear ? "\(firstYear) 年" : "\(firstYear) – \(lastYear)"
    }
}
