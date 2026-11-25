import Foundation

// MARK: - 智能相簿

/// 智能相簿的条件字段，覆盖官方「照片」里常用的判定维度。
enum SmartAlbumField: String, Codable, CaseIterable, Identifiable {
    case mediaType
    case favorite
    case edited
    case keyword
    case camera
    case lens
    case place
    case hasLocation
    case capturedAfter
    case capturedBefore
    case minMegapixels
    case minFileSizeMB
    case filename
    case minDuration
    /// 端侧场景识别结果（需先在图库侧边栏「场景」里完成分析）。
    case scene
    /// 图内是否识别到文字（OCR）。
    case hasText
    /// 图内文字内容。
    case ocrText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mediaType: return "媒体类型"
        case .favorite: return "个人收藏"
        case .edited: return "已编辑"
        case .keyword: return "关键词"
        case .camera: return "相机"
        case .lens: return "镜头"
        case .place: return "地点"
        case .hasLocation: return "包含位置"
        case .capturedAfter: return "拍摄日期晚于"
        case .capturedBefore: return "拍摄日期早于"
        case .minMegapixels: return "最小像素（百万）"
        case .minFileSizeMB: return "最小文件（MB）"
        case .filename: return "文件名包含"
        case .minDuration: return "最短时长（秒）"
        case .scene: return "场景识别为"
        case .hasText: return "图内含文字"
        case .ocrText: return "图内文字包含"
        }
    }

    var icon: String {
        switch self {
        case .mediaType: return "square.stack.3d.up"
        case .favorite: return "heart"
        case .edited: return "slider.horizontal.3"
        case .keyword: return "tag"
        case .camera: return "camera"
        case .lens: return "camera.aperture"
        case .place: return "mappin.and.ellipse"
        case .hasLocation: return "location"
        case .capturedAfter, .capturedBefore: return "calendar"
        case .minMegapixels: return "arrow.up.left.and.arrow.down.right"
        case .minFileSizeMB: return "internaldrive"
        case .filename: return "doc.text"
        case .minDuration: return "timer"
        case .scene: return "sparkles"
        case .hasText, .ocrText: return "text.viewfinder"
        }
    }

    enum ValueKind {
        case choice([String])
        case toggle
        case text
        case date
        case number
    }

    var valueKind: ValueKind {
        switch self {
        case .mediaType: return .choice(["照片", "视频", "截屏", "全景", "自拍"])
        case .scene: return .choice(SceneCatalog.categories.map(\.title))
        case .favorite, .edited, .hasLocation, .hasText: return .toggle
        case .capturedAfter, .capturedBefore: return .date
        case .minMegapixels, .minFileSizeMB, .minDuration: return .number
        default: return .text
        }
    }

    var defaultValue: String {
        switch valueKind {
        case .choice(let options): return options.first ?? ""
        case .toggle: return "是"
        case .date: return SmartAlbumDate.string(from: Date())
        case .number: return ""
        case .text: return ""
        }
    }

    var placeholder: String {
        switch self {
        case .minMegapixels: return "例如 8"
        case .minFileSizeMB: return "例如 5"
        case .minDuration: return "例如 30"
        case .keyword: return "输入关键词"
        case .camera: return "例如 iPhone"
        case .lens: return "例如 24-70"
        case .place: return "例如 杭州"
        case .filename: return "输入文件名片段"
        case .ocrText: return "输入图内文字"
        default: return "输入值"
        }
    }

    static func mediaKind(for label: String) -> MediaKind? {
        switch label {
        case "照片": return .photo
        case "视频": return .video
        case "截屏": return .screenshot
        case "全景": return .panorama
        case "自拍": return .selfie
        default: return nil
        }
    }
}

struct SmartRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var field: SmartAlbumField = .keyword
    var value: String = ""

    var summary: String {
        let display = value.isEmpty ? "…" : value
        switch field {
        case .mediaType: return "媒体类型为「\(display)」"
        case .favorite: return value == "否" ? "不在个人收藏" : "在个人收藏"
        case .edited: return value == "否" ? "未编辑" : "已编辑"
        case .hasLocation: return value == "否" ? "没有位置" : "有位置"
        case .capturedAfter: return "拍摄日期晚于 \(display)"
        case .capturedBefore: return "拍摄日期早于 \(display)"
        case .minMegapixels: return "像素不低于 \(display) 百万"
        case .minFileSizeMB: return "文件不小于 \(display) MB"
        case .minDuration: return "时长不短于 \(display) 秒"
        case .keyword: return "关键词包含「\(display)」"
        case .camera: return "相机包含「\(display)」"
        case .lens: return "镜头包含「\(display)」"
        case .place: return "地点包含「\(display)」"
        case .filename: return "文件名包含「\(display)」"
        case .scene: return "场景为「\(display)」"
        case .hasText: return value == "否" ? "图内没有文字" : "图内有文字"
        case .ocrText: return "图内文字包含「\(display)」"
        }
    }

    func matches(_ photo: PhotoItem, analysis: PhotoAnalysis? = nil) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.lowercased()
        switch field {
        case .mediaType:
            guard let kind = SmartAlbumField.mediaKind(for: trimmed) else { return true }
            return photo.kind == kind
        case .favorite:
            return photo.isFavorite == (trimmed == "是")
        case .edited:
            return photo.hasEdits == (trimmed == "是")
        case .hasLocation:
            return photo.hasLocation == (trimmed == "是")
        case .keyword:
            guard !needle.isEmpty else { return true }
            return photo.tags.contains { $0.lowercased().contains(needle) }
        case .camera:
            guard !needle.isEmpty else { return true }
            let camera = [photo.make, photo.model].compactMap { $0 }.joined(separator: " ")
            return camera.lowercased().contains(needle)
        case .lens:
            guard !needle.isEmpty else { return true }
            return (photo.lens ?? "").lowercased().contains(needle)
        case .place:
            guard !needle.isEmpty else { return true }
            let place = [photo.placeCountry, photo.placeProvince, photo.placeCity,
                         photo.placeDistrict, photo.placePOI]
                .compactMap { $0 }.joined(separator: " ")
            return place.lowercased().contains(needle)
        case .filename:
            guard !needle.isEmpty else { return true }
            return photo.displayFilename.lowercased().contains(needle)
                || photo.originalName.lowercased().contains(needle)
        case .capturedAfter:
            guard let date = SmartAlbumDate.date(from: trimmed) else { return true }
            return photo.capturedAt >= date
        case .capturedBefore:
            guard let date = SmartAlbumDate.date(from: trimmed) else { return true }
            return photo.capturedAt <= date
        case .minMegapixels:
            guard let value = Double(trimmed) else { return true }
            let megapixels = Double(photo.pixelWidth) * Double(photo.pixelHeight) / 1_000_000
            return megapixels >= value
        case .minFileSizeMB:
            guard let value = Double(trimmed) else { return true }
            return Double(photo.fileSize) >= value * 1_048_576
        case .minDuration:
            guard let value = Double(trimmed) else { return true }
            return (photo.duration ?? 0) >= value
        case .scene:
            guard let category = SceneCatalog.categories.first(where: { $0.title == trimmed }) else {
                return true
            }
            guard let analysis else { return false }
            return SceneCatalog.matches(category, analysis: analysis, photo: photo)
        case .hasText:
            let hasText = !(analysis?.text.isEmpty ?? true)
            return hasText == (trimmed == "是")
        case .ocrText:
            guard !needle.isEmpty else { return true }
            return (analysis?.text.lowercased().contains(needle) ?? false)
        }
    }
}

struct SmartAlbum: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = "新建智能相簿"
    var matchAll: Bool = true
    var rules: [SmartRule] = [SmartRule()]

    func matches(_ photo: PhotoItem, analysis: PhotoAnalysis? = nil) -> Bool {
        guard !rules.isEmpty else { return true }
        if matchAll {
            return rules.allSatisfy { $0.matches(photo, analysis: analysis) }
        }
        return rules.contains { $0.matches(photo, analysis: analysis) }
    }

    var summary: String {
        rules.isEmpty ? "没有条件" : rules.map(\.summary).joined(separator: matchAll ? " 且 " : " 或 ")
    }
}

enum SmartAlbumDate {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
