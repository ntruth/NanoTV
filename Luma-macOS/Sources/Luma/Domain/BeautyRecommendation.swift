import Foundation
import LumaCore

/// 一张照片的美化候选。只存 id 与建议，避免把 `PhotoItem` 复制一份后界面状态过期。
struct BeautyCandidate: Identifiable, Codable {
    let photoID: UUID
    let advice: BeautyAdvice

    var id: UUID { photoID }
}

/// 推荐分组：把「偏暗 / 偏亮 / 偏灰 / 偏色 / 偏软」分开，方便按同一套参数批量处理。
struct BeautyGroup: Identifiable, Codable {
    enum Kind: String, CaseIterable, Codable {
        case dark
        case bright
        case flat
        case cast
        case soft

        var title: String {
            switch self {
            case .dark: return "偏暗"
            case .bright: return "偏亮"
            case .flat: return "发灰"
            case .cast: return "偏色"
            case .soft: return "偏软"
            }
        }

        var icon: String {
            switch self {
            case .dark: return "moon.stars"
            case .bright: return "sun.max"
            case .flat: return "circle.lefthalf.filled"
            case .cast: return "thermometer.medium"
            case .soft: return "camera.metering.center.weighted"
            }
        }

        var hint: String {
            switch self {
            case .dark: return "室内、逆光与夜景居多，提亮后细节更清楚"
            case .bright: return "高光容易发白，压暗后层次更完整"
            case .flat: return "阴天或隔着玻璃拍摄，提升对比后不再蒙灰"
            case .cast: return "室内灯光让白平衡偏移，回正后颜色更自然"
            case .soft: return "轻微手抖或对焦不实，提升锐度更利落"
            }
        }
    }

    let kind: Kind
    let candidates: [BeautyCandidate]

    var id: String { kind.rawValue }
    var count: Int { candidates.count }
}

/// 一次「智能美化」扫描的结果；按范围签名写入当前图库的 `derived_reports`，重开面板可直接回填。
struct BeautyReport: Codable {
    let scannedAt: Date
    let scannedCount: Int
    let groups: [BeautyGroup]

    /// 至少命中一个分组的照片数量（同一张照片只计一次）。
    var distinctCount: Int {
        Set(groups.flatMap { $0.candidates.map(\.photoID) }).count
    }

    /// 命中分组里已被收藏的数量，用于说明「推荐优先照顾收藏」。
    func favoriteCount(in photos: [UUID: PhotoItem]) -> Int {
        Set(groups.flatMap { $0.candidates.map(\.photoID) })
            .filter { photos[$0]?.isFavorite == true }
            .count
    }
}
