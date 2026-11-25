import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 海报墙与书架用的卡片组件。

/// 海报卡尺寸：海报墙里跟随网格列宽（按 2:3 由宽度推高），书架里固定 156×234。
/// 尺寸用透明底板锁定、卡片内容放 overlay：角标 / 长标题的最小宽高不会再反过来
/// 把卡片撑大，同一行每张卡始终是同一个 2:3 矩形。
struct CinemaWallCardSizing: ViewModifier {
    let fillWidth: Bool

    func body(content: Content) -> some View {
        if fillWidth {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { content }
        } else {
            content.frame(width: 156, height: 234)
        }
    }
}

/// 演职员头像：悬停时头像微微抬起、琥珀渐变描边加光晕，右上角弹出「打开」角标，
/// 名字跟着变琥珀色，一眼就知道点头像能进人物页。
struct CinemaCastTile: View {
    let member: CinemaCastMember
    let onOpen: () -> Void
    /// 右键「在网络影院搜索 TA」。
    let onSearchOnline: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 5) {
                ZStack {
                    if let url = member.profileURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        Circle().fill(Color.secondary.opacity(0.18))
                        Image(systemName: "person.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(hovered
                                          ? AnyShapeStyle(AngularGradient(colors: [LumaBrand.amber,
                                                                                   LumaBrand.coral,
                                                                                   LumaBrand.amber],
                                                                          center: .center))
                                          : AnyShapeStyle(Color.primary.opacity(0.10)),
                                          lineWidth: hovered ? 1.6 : 0.6)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 17, height: 17)
                        .background(LumaBrand.amber, in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.5) }
                        .scaleEffect(hovered ? 1 : 0.4)
                        .opacity(hovered ? 1 : 0)
                        .offset(x: 1.5, y: 1.5)
                }
                .shadow(color: LumaBrand.amber.opacity(hovered ? 0.42 : 0),
                        radius: hovered ? 9 : 0, y: 2)
                .scaleEffect(hovered ? 1.06 : 1)
                .offset(y: hovered ? -2 : 0)

                Text(member.name)
                    .font(.system(size: 11, weight: hovered ? .semibold : .medium))
                    .foregroundStyle(hovered ? LumaBrand.amber : Color.primary)
                    .lineLimit(1)
                Text(member.character ?? " ")
                    .font(.system(size: 10))
                    .foregroundStyle(hovered ? Color.primary.opacity(0.82) : Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hovered)
        .contextMenu {
            Button("网络影院搜索 \(member.name)（即将上线）") { onSearchOnline() }
        }
        .help("查看 \(member.name) 的人物页；右键可在网络影院搜索（即将上线）")
    }
}

struct CinemaSeriesCard: View {
    let series: CinemaSeries
    /// 海报墙里跟随网格列宽（外框和海报永远同宽）；书架里固定 156×234。
    var fillWidth: Bool = false
    let onOpen: () -> Void

    @EnvironmentObject private var store: LibraryStore
    /// 悬停状态留在卡片内部：只有这张卡重绘，不会带着整页聚合一起重算。
    @State private var hovered = false
    /// 右键「手动刮削」打开的选片面板。
    @State private var showMatchSheet = false
    /// 右键「更换海报 / 背景」的候选面板。
    @State private var artworkRequest: CinemaArtworkPickerRequest?

    /// 单独声明，避免 body 里的表达式类型检查超时。
    var overlayGradient: LinearGradient {
        LinearGradient(colors: [Color.clear,
                                Color.black.opacity(0.10),
                                Color.black.opacity(0.72)],
                       startPoint: .center,
                       endPoint: .bottom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if series.artworkURL != nil {
                        CinemaArtwork(urlString: series.artworkURL, contentMode: .fill)
                    } else if let latest = series.latestEpisode {
                        PhotoThumbnailView(photo: latest.file.photoItem, purpose: .cover(156))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                overlayGradient

                VStack(alignment: .leading, spacing: 3) {
                    Text(series.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(series.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                // 底部片名 / 副标题整体上移，避免被卡片下沿和海报自带的片名压住。
                .padding(.horizontal, 9)
                .padding(.top, 9)
                .padding(.bottom, 16)

                VStack {
                    // 157pt 的竖版卡：左上只放最重要的 1–2 个音画角标，右上留评分。
                    // 左角标用 maxWidth：窄卡片时优先压缩角标，右侧评分始终留在卡内。
                    HStack(alignment: .top, spacing: 5) {
                        CinemaSpecBadges(tags: cinemaBadgeTags(series.latestEpisode?.file),
                                         fontSize: 8)
                            .frame(maxWidth: 102, alignment: .leading)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 3) {
                            if !series.isMatched {
                                Text("未识别")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(.black.opacity(0.48), in: Capsule())
                            } else if let rating = series.rating, rating > 0 {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.48), in: Capsule())
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(7)
            }
            .modifier(CinemaWallCardSizing(fillWidth: fillWidth))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? LumaBrand.amber.opacity(0.55) : Color.white.opacity(0.08),
                                  lineWidth: hovered ? 1.2 : 0.5)
            }
            // 悬停只加深描边与投影，不再放大卡片：放大后描边会溢出格子，外框和海报对不齐。
            .shadow(color: .black.opacity(hovered ? 0.26 : 0.14),
                    radius: hovered ? 12 : 6, y: hovered ? 7 : 3)
            .animation(.easeOut(duration: 0.16), value: hovered)
        }
        .frame(maxWidth: fillWidth ? .infinity : 156, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
        .help("\(series.title) · \(series.subtitle)")
        .contextMenu {
            Button("查看 \(series.episodeCount) 集") { onOpen() }
            Button("手动刮削…") {
                // 右键菜单收起后再弹面板，避免菜单窗口抢焦点导致 sheet 不出现。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showMatchSheet = true }
            }
            Button("选择海报…") { requestArtwork(.poster) }
            Button("选择背景…") { requestArtwork(.backdrop) }
            Button(series.latestEpisode.flatMap { store.cinemaProgress[$0.id]?.isFinished } == true ? "标记为未看" : "标记为已看") {
                guard let sample = series.latestEpisode else { return }
                let watched = store.cinemaProgress[sample.id]?.isFinished != true
                store.setCinemaWatched(sample, watched: watched)
            }
            if let sample = series.latestEpisode {
                Button("复制文件路径") {
                    let text = sample.file.cloudPath ?? sample.file.filename
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    store.showToast("已复制路径")
                }
                Button("在访达中显示") { store.revealCinemaEntryInFinder(sample) }
            }
            Divider()
            Button("忽略整部剧（以后不刮削）") {
                store.ignoreCinemaSeries(series)
            }
            Button("删除整部剧文件…", role: .destructive) {
                store.confirmDeleteCinemaEntries(series.episodes, title: series.title)
            }
        }
        .sheet(isPresented: $showMatchSheet) {
            // 整部剧一起手动匹配：面板里可以统一选剧并按文件名排季集。
            CinemaMatchSheet(photos: series.episodes.map(\.file.photoItem),
                             folderHint: series.episodes.first?.folderHint) {
                showMatchSheet = false
            }
            .environmentObject(store)
        }
        .sheet(item: $artworkRequest) { request in
            CinemaArtworkPickerSheet(kind: request.kind, entry: request.entry) { url in
                store.applyCinemaArtwork(request.entry,
                                         posterURL: request.kind == .poster ? url : nil,
                                         backdropURL: request.kind == .backdrop ? url : nil)
            }
        }
        .id("series-\(series.id)")
    }

    /// 换封面：用剧里一集已匹配的条目做代理，写回时 `applyCinemaArtwork` 会同步整部剧。
    func requestArtwork(_ kind: CinemaArtworkKind) {
        guard let sample = series.episodes.first(where: { $0.matched && $0.tmdbID != nil }) else {
            store.showToast("先匹配这部剧，才能更换封面")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: sample)
        }
    }
}

// MARK: - 剧集主视觉

struct CinemaSeriesHeroCard: View {
    let series: CinemaSeries
    var onPlay: (() -> Void)? = nil
    let onOpen: () -> Void

    @EnvironmentObject private var store: LibraryStore
    @State private var hover = false
    @State private var showMatchSheet = false
    @State private var artworkRequest: CinemaArtworkPickerRequest?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CinemaArtwork(urlString: series.backdropURL ?? series.posterURL, contentMode: .fill)
                .frame(height: 260)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.30), .black.opacity(0.86)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                Text(series.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(series.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    if let rating = series.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.35), in: Capsule())
                    }
                }
                let heroTags = cinemaBadgeTags(series.latestEpisode?.file)
                if !heroTags.isEmpty {
                    CinemaSpecBadges(tags: heroTags,
                                     fontSize: 10.5,
                                     background: .white.opacity(0.16))
                        .frame(maxWidth: 620, alignment: .leading)
                }
                if let overview = series.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                Button(action: onOpen) {
                    Label("查看 \(series.episodeCount) 集", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.white.opacity(hover ? 0.95 : 0.88), in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .padding(.top, 2)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.10))
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("查看 \(series.episodeCount) 集") { onOpen() }
            if let onPlay {
                Button("继续播放") { onPlay() }
            }
            Button("手动刮削…") {
                // 菜单收起后再弹面板，避免菜单窗口抢焦点导致 sheet 不出现。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showMatchSheet = true }
            }
            Button("选择海报…") { requestArtwork(.poster) }
            Button("选择背景…") { requestArtwork(.backdrop) }
            if let sample = series.latestEpisode {
                Button(store.cinemaProgress[sample.id]?.isFinished == true ? "标记为未看" : "标记为已看") {
                    let watched = store.cinemaProgress[sample.id]?.isFinished != true
                    store.setCinemaWatched(sample, watched: watched)
                }
                Button("复制文件路径") {
                    let text = sample.file.cloudPath ?? sample.file.filename
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    store.showToast("已复制路径")
                }
            }
            Divider()
            Button("忽略整部剧（以后不刮削）") {
                store.ignoreCinemaSeries(series)
            }
        }
        .sheet(isPresented: $showMatchSheet) {
            CinemaMatchSheet(photos: series.episodes.map(\.file.photoItem),
                             folderHint: series.episodes.first?.folderHint) {
                showMatchSheet = false
            }
            .environmentObject(store)
        }
        .sheet(item: $artworkRequest) { request in
            CinemaArtworkPickerSheet(kind: request.kind, entry: request.entry) { url in
                store.applyCinemaArtwork(request.entry,
                                         posterURL: request.kind == .poster ? url : nil,
                                         backdropURL: request.kind == .backdrop ? url : nil)
            }
        }
    }

    /// 换封面：取剧里一集已匹配的条目做代理，写回时同步整部剧。
    func requestArtwork(_ kind: CinemaArtworkKind) {
        guard let sample = series.episodes.first(where: { $0.matched && $0.tmdbID != nil }) else {
            store.showToast("先匹配这部剧，才能更换封面")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: sample)
        }
    }
}

// MARK: - 剧集分集
