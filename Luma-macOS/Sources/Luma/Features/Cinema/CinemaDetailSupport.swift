import SwiftUI
import AppKit
import LumaCore
import LumaContentCore


/// 影片 / 剧集 / 演职员详情页的主题色，跟随系统外观：
/// 深色下保持原来的影院暗色，浅色下切成与海报墙一致的浅灰，
/// 文字、玻璃底板与描边一起翻转，不再整页固定在暗色里。
enum CinemaDetailTone {
    /// 页面底色：浅色直接吃窗口底色，与海报墙无缝衔接。
    static let page = dynamic(dark: NSColor(calibratedRed: 0.055, green: 0.06, blue: 0.075, alpha: 1),
                              light: .windowBackgroundColor)
    /// 前景：深色下是白，浅色下是近黑的墨色；透明度沿用原来的层次。
    static let ink = dynamic(dark: .white, light: NSColor(calibratedWhite: 0.10, alpha: 1))
    /// 浮层卡片的实色底板（悬停档案）：深色下是深面板，浅色下是近白面板。
    static let plate = dynamic(dark: NSColor(calibratedRed: 0.075, green: 0.08, blue: 0.095, alpha: 1),
                               light: NSColor(calibratedWhite: 0.99, alpha: 1))
    /// 强调色前景：深色下是品牌琥珀，浅色下压深一档，小字号在浅底上也能读清。
    static let accent = dynamic(dark: NSColor(calibratedRed: 1.00, green: 0.77, blue: 0.42, alpha: 1),
                                light: NSColor(calibratedRed: 0.70, green: 0.43, blue: 0.02, alpha: 1))

    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// 卡片投影：浅色外观下整体减淡，避免浅底上出现一圈脏影。
    static func shadow(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor.black.withAlphaComponent(dark ? opacity : opacity * 0.35)
        })
    }
}

/// 影院详情面板尽量吃满窗口：大屏更大，小屏也不会溢出。
var cinemaDetailWindowSize: CGSize {
    let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    return CGSize(width: min(1480, max(1000, visible.width - 120)),
                  height: min(980, max(720, visible.height - 100)))
}

/// 详情页竖版海报的香槟外框：左上偏铜、右下偏亮，像蓝光盒的金属包边。
var cinemaChampagneFrame: LinearGradient {
    LinearGradient(colors: [Color(red: 0.24, green: 0.17, blue: 0.09),
                            Color(red: 0.66, green: 0.46, blue: 0.19),
                            Color(red: 0.90, green: 0.76, blue: 0.49)],
                   startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// 详情页竖版海报宽度：文档要求 180–220，按档案卡宽度断点取值，2:3 比例。
func cinemaDetailPosterWidth(for cardWidth: CGFloat) -> CGFloat {
    switch cardWidth {
    case ..<820: return 180
    case ..<1100: return 200
    default: return 220
    }
}

/// 卡片模式胶片条的一格数据：电影 / 剧集先归一成同一种展示结构。
struct CardStripItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let artwork: String?
}

/// 胶片条可用宽度：按它算一行放得下几格，用「展开成网格」替代横向滚动。
struct CinemaStripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 卡片模式胶片条的单格宽度（16:9）。
let cinemaCardStripCellWidth: CGFloat = 208

// MARK: - 规格角标

/// 角标流式布局：一行放不下自动换行，窄卡也能完整显示 4K / DV / Atmos / 类型。
struct CinemaBadgeFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                width = max(width, lineWidth)
                height += lineHeight + lineSpacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
        width = max(width, lineWidth)
        height += lineHeight
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// 集卡在网格里的位置：悬停时把完整档案浮在该集旁边，而不是覆盖卡片本身。
struct CinemaEpisodeAnchorKey: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>],
                       nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 人物页作品卡的锚点：悬停时把作品档案浮在这张卡旁边。
struct CinemaWorkAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 规格角标组：4K / DV / HDR10+ / 10bit / Atmos / DTS-HD / 60fps / 类型。
struct CinemaSpecBadges: View {
    let tags: [String]
    var fontSize: CGFloat = 8.5
    var tint: Color = .white
    var background: Color = .black.opacity(0.5)

    var body: some View {
        CinemaBadgeFlow(spacing: max(3, fontSize * 0.45),
                        lineSpacing: max(2, fontSize * 0.35)) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.94))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, max(4, fontSize * 0.62))
                    .padding(.vertical, max(1.5, fontSize * 0.3))
                    .background(background, in: Capsule())
            }
        }
    }
}

/// 卡片角标：只挑最重要的 1–2 个 —— 分辨率 > HDR 规格 > 音质，不铺满海报。
func cinemaBadgeTags(_ file: CinemaFile?, limit: Int = 2) -> [String] {
    guard let file else { return [] }
    let tags = file.displayTags
    let resolution = ["4K", "2K", "1080P"]
    let dynamicRange = ["DV", "HDR10+", "HDR10", "HDR", "HLG"]
    let audio = ["Atmos", "DTS:X", "TrueHD", "DTS-HD", "DTS"]
    var picked: [String] = []
    if let value = resolution.first(where: { tags.contains($0) }) { picked.append(value) }
    if let value = dynamicRange.first(where: { tags.contains($0) }) { picked.append(value) }
    if let value = audio.first(where: { tags.contains($0) }) { picked.append(value) }
    // 没有分辨率 / 音画标记时退回其他标记（10bit / 60fps 等），但不铺满。
    if picked.isEmpty { picked = tags }
    return Array(picked.prefix(limit))
}

// MARK: - 详情页共用的小工具

/// 可展开的长简介：超过 6 行才出现「展开全文」。
struct CinemaSynopsis: View {
    let text: String

    @State private var expanded = false

    var isLong: Bool { text.count > 180 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 12.8))
                .foregroundStyle(.secondary)
                .lineSpacing(6)
                .lineLimit(expanded ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if isLong {
                Button(expanded ? "收起" : "展开全文") {
                    withAnimation(.easeOut(duration: 0.18)) {
                        expanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
        }
    }
}

/// 2026-11-20 → 2026 年 11 月 20 日
func cinemaDateText(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let parts = raw.split(separator: "-")
    guard parts.count >= 3,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
        return raw
    }
    return "\(year) 年 \(month) 月 \(day) 日"
}

func cinemaMinutesText(_ minutes: Int?) -> String? {
    guard let minutes, minutes > 0 else { return nil }
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest) 分钟" }
    return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分钟"
}

func cinemaStatusText(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    switch raw {
    case "Released": return "已上映"
    case "Returning Series": return "连载中"
    case "Ended": return "已完结"
    case "Canceled", "Cancelled": return "已取消"
    case "In Production": return "制作中"
    case "Post Production": return "后期制作"
    case "Planned": return "已计划"
    case "Rumored": return "传闻中"
    default: return raw
    }
}

func cinemaLanguageName(_ code: String?) -> String? {
    guard let code, !code.isEmpty else { return nil }
    let names: [String: String] = [
        "zh": "汉语", "cn": "汉语", "en": "英语", "ja": "日语", "ko": "韩语",
        "fr": "法语", "de": "德语", "es": "西班牙语", "it": "意大利语",
        "ru": "俄语", "hi": "印地语", "th": "泰语", "pt": "葡萄牙语",
        "sv": "瑞典语", "da": "丹麦语", "nl": "荷兰语", "pl": "波兰语"
    ]
    return names[code.lowercased()] ?? code.uppercased()
}

/// TMDB 国家名是英文：资料卡里换成中文，常见国家之外的保留原文。
func cinemaCountryName(_ raw: String) -> String {
    let names: [String: String] = [
        "China": "中国", "Hong Kong": "中国香港", "Taiwan": "中国台湾",
        "Japan": "日本", "South Korea": "韩国", "Korea": "韩国",
        "United States of America": "美国", "United States": "美国",
        "United Kingdom": "英国", "France": "法国", "Germany": "德国",
        "Italy": "意大利", "Spain": "西班牙", "India": "印度",
        "Thailand": "泰国", "Canada": "加拿大", "Australia": "澳大利亚",
        "Russia": "俄罗斯", "Singapore": "新加坡", "Malaysia": "马来西亚"
    ]
    return names[raw] ?? raw
}

func cinemaMoneyText(_ value: Int64?) -> String? {
    guard let value, value > 0 else { return nil }
    if value >= 100_000_000 {
        return String(format: "约 %.2f 亿美元", Double(value) / 100_000_000)
    }
    return String(format: "约 %.0f 万美元", Double(value) / 10_000)
}

// MARK: - 影院库（刮削后的电影 / 电视剧）

/// 影院里的详情目标：剧集 / 影片详情在页面内展示，其余面板仍用 sheet。
enum CinemaDetailTarget: Identifiable {
    case series(CinemaSeries)
    case entry(CinemaEntry)
    case newList
    case search
    case history
    case notifications
    case pin
    case folder(CinemaFolder)
    case folderMatch(CinemaFolder)
    case match(CinemaEntry)

    var id: String {
        switch self {
        case .series(let series): return "series-\(series.id)"
        case .entry(let entry): return "entry-\(entry.id.uuidString)"
        case .newList: return "new-list"
        case .search: return "search"
        case .history: return "history"
        case .notifications: return "notifications"
        case .pin: return "pin"
        case .folder(let folder): return "folder-\(folder.id)"
        case .folderMatch(let folder): return "folder-match-\(folder.id)"
        case .match(let entry): return "match-\(entry.id.uuidString)"
        }
    }
}
