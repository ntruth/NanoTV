import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 海报 / 背景候选选择面板。

/// 详情页滚动偏移：用顶部锚点在滚动坐标系里的位置判断是否滚过档案卡。
struct CinemaScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 统一的键盘焦点环：列表行、集卡都用同一套描边与柔光，避免各处风格不一。
struct CinemaFocusRing: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(LumaBrand.amber.opacity(0.9), lineWidth: 2)
                    .shadow(color: LumaBrand.amber.opacity(0.35), radius: 6)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 手动选封面

enum CinemaArtworkKind: String, Identifiable {
    case poster
    case backdrop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .poster: return "海报"
        case .backdrop: return "背景"
        }
    }
}

struct CinemaArtworkPickerRequest: Identifiable {
    let id = UUID()
    let kind: CinemaArtworkKind
    let entry: CinemaEntry
}

/// 封面候选面板：打开时自己去拉候选，详情页 / 卡片 / 列表行共用同一份实现。
struct CinemaArtworkPickerSheet: View {
    let kind: CinemaArtworkKind
    let entry: CinemaEntry
    let onPick: (String) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [CinemaArtworkCandidate] = []
    @State private var loading = true
    /// 没匹配 / 拉不到图时直接写在面板里，不再弹完再提示。
    @State private var message: String?

    var tileSize: CGSize {
        kind == .poster ? CGSize(width: 130, height: 195) : CGSize(width: 240, height: 135)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("选择\(kind.title)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                Text(loading ? "加载中…" : "\(candidates.count) 张")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                Spacer(minLength: 0)
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(LumaBrand.amber)
            }
            .padding(16)

            Divider().opacity(0.25)

            Group {
                if loading {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在获取\(kind.title)…")
                            .font(.system(size: 11))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 22))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.35))
                        Text(message ?? "没有找到可用的\(kind.title)")
                            .font(.system(size: 12))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize.width), spacing: 14)],
                                  alignment: .leading, spacing: 14) {
                            ForEach(candidates) { candidate in
                                Button {
                                    onPick(candidate.url)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        CinemaArtwork(urlString: candidate.url,
                                                      contentMode: .fill,
                                                      maxPixelSize: 520)
                                            .frame(width: tileSize.width, height: tileSize.height)
                                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .strokeBorder(CinemaDetailTone.ink.opacity(0.16), lineWidth: 0.8)
                                            }
                                        HStack(spacing: 6) {
                                            Text(candidate.language ?? "原版")
                                            if let rating = candidate.rating, rating > 0 {
                                                Text(String(format: "★ %.1f", rating))
                                                    .foregroundStyle(LumaBrand.amber.opacity(0.9))
                                            }
                                        }
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(CinemaDetailTone.page)
        .task { await load() }
    }

    func load() async {
        guard entry.matched, entry.tmdbID != nil else {
            loading = false
            message = "先匹配这部片，才能更换\(kind.title)"
            return
        }
        let result = await store.cinemaArtworkCandidates(for: entry)
        candidates = kind == .poster ? result.posters : result.backdrops
        if candidates.isEmpty { message = "没有找到可用的\(kind.title)" }
        loading = false
    }
}
