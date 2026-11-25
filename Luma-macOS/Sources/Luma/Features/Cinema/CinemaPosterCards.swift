import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 主视觉卡、海报卡与列表行。

// MARK: - 主视觉卡片

struct CinemaHeroCard: View {
    let entry: CinemaEntry
    let onPlay: () -> Void
    let onDetail: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CinemaArtwork(urlString: entry.backdropURL ?? entry.posterURL, contentMode: .fill)
                .frame(height: 260)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.30), .black.opacity(0.86)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if !entry.subtitle.isEmpty {
                        Text(entry.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    if let rating = entry.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.35), in: Capsule())
                    }
                    if entry.kind == .tv {
                        Text("剧集")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                }
                let heroTags = cinemaBadgeTags(entry.file)
                if !heroTags.isEmpty {
                    CinemaSpecBadges(tags: heroTags,
                                     fontSize: 10.5,
                                     background: .white.opacity(0.16))
                        .frame(maxWidth: 620, alignment: .leading)
                }
                if let overview = entry.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Label("播放", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.white.opacity(hover ? 0.95 : 0.88), in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .onHover { hover = $0 }

                    Button(action: onDetail) {
                        Label("详情", systemImage: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.14), in: Capsule())
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .buttonStyle(.plain)
                }
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
        .onTapGesture(perform: onDetail)
    }
}

// MARK: - 海报卡片

struct CinemaPosterCard: View {
    let entry: CinemaEntry
    /// 同版本文件数：由聚合快照算好传入，卡片不再自己扫描整个影院索引。
    let versionCount: Int
    /// 海报墙里跟随网格列宽；书架里固定 156×234。
    var fillWidth: Bool = false
    let onOpen: () -> Void
    var onPlay: (() -> Void)? = nil
    var onDetail: (() -> Void)? = nil

    @EnvironmentObject private var store: LibraryStore
    @AppStorage("cinema_show_rating_badge") private var showRatingBadge = true
    @AppStorage("cinema_show_format_badge") private var showFormatBadge = true
    /// 悬停状态留在卡片内部：只有这张卡重绘，不会带着整页聚合一起重算。
    @State private var hovered = false
    /// 右键「手动刮削」打开的选片面板。
    @State private var showMatchSheet = false
    /// 右键「更换海报 / 背景」的候选面板。
    @State private var artworkRequest: CinemaArtworkPickerRequest?

    var badgeTags: [String] {
        cinemaBadgeTags(entry.file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if entry.artworkURL != nil {
                        CinemaArtwork(urlString: entry.artworkURL, contentMode: .fill)
                    } else {
                        // 没匹配到海报时先显示视频自己的缩略图，至少能看见内容。
                        PhotoThumbnailView(photo: entry.file.photoItem, purpose: .cover(156))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.10), .black.opacity(0.72)],
                               startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !entry.subtitle.isEmpty {
                        Text(entry.subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                // 底部片名 / 副标题整体上移，避免被卡片下沿和海报自带的片名压住。
                .padding(.horizontal, 9)
                .padding(.top, 9)
                .padding(.bottom, 16)

                VStack {
                    // 左上铺满画质 / 音质 / 类型角标（可换行），右上只留评分与版本。
                    // 左角标用 maxWidth 而不是定宽：窄卡片时先压缩它，评分 / 未识别角标不会被挤出卡片。
                    HStack(alignment: .top, spacing: 5) {
                        if showFormatBadge {
                            CinemaSpecBadges(tags: badgeTags, fontSize: 8)
                                .frame(maxWidth: 102, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 3) {
                            if versionCount > 1 {
                                Text("\(versionCount) 版本")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.48), in: Capsule())
                            }
                            if !entry.matched {
                                Text("未识别")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.48), in: Capsule())
                            } else if showRatingBadge, let rating = entry.rating, rating > 0 {
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
            // 悬停只加深描边与投影，不放大：放大后描边溢出格子，外框和海报内容对不齐。
            .shadow(color: .black.opacity(hovered ? 0.26 : 0.14),
                    radius: hovered ? 12 : 6, y: hovered ? 7 : 3)
            .animation(.easeOut(duration: 0.16), value: hovered)
            .overlay(alignment: .bottomTrailing) {
                if hovered {
                    HStack(spacing: 5) {
                        if let onPlay {
                            Button(action: onPlay) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 22, height: 22)
                                    .background(LumaBrand.amber, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("播放")
                        }
                        if let onDetail {
                            Button(action: onDetail) {
                                Image(systemName: "info")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(.black.opacity(0.55), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("详情")
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: fillWidth ? .infinity : 156, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) {
            if let onDetail { onDetail() } else { onOpen() }
        }
        .onTapGesture(perform: onOpen)
        .help(entry.file.filename)
        .contextMenu {
            CinemaEntryContextMenu(
                entry: entry,
                onPlay: {
                    if let onPlay { onPlay() } else { onOpen() }
                },
                onDetail: {
                    if let onDetail { onDetail() } else { onOpen() }
                },
                onManualMatch: {
                    // 右键菜单收起后再弹面板，避免菜单窗口抢焦点导致 sheet 不出现。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showMatchSheet = true }
                },
                onArtwork: { kind in requestArtwork(kind) }
            )
        }
        .sheet(isPresented: $showMatchSheet) {
            CinemaMatchSheet(entry: entry) { showMatchSheet = false }
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

    /// 换封面：候选面板自己去拉图，这里只负责递请求。
    func requestArtwork(_ kind: CinemaArtworkKind) {
        guard entry.matched, entry.tmdbID != nil else {
            store.showToast("先匹配这部片，才能更换封面")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: entry)
        }
    }
}

// MARK: - 共用右键菜单

/// 影片 / 集卡的统一右键菜单：海报墙、列表行、卡片模式共用，避免三套菜单各缺一半。
struct CinemaEntryContextMenu: View {
    let entry: CinemaEntry
    var onPlay: () -> Void
    var onDetail: () -> Void
    var onManualMatch: () -> Void
    var onArtwork: (CinemaArtworkKind) -> Void

    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Button("播放") { onPlay() }
        Button("查看详情") { onDetail() }
        Button(store.cinemaUserState(for: entry.id).favorite ? "取消收藏" : "收藏") {
            store.toggleCinemaFavorite(entry.id)
        }
        Button(store.cinemaUserState(for: entry.id).watchlist ? "移出想看" : "加入想看") {
            store.toggleCinemaWatchlist(entry.id)
        }
        if !store.cinemaLists.isEmpty {
            Menu("加入清单") {
                ForEach(store.cinemaLists) { list in
                    Button(list.name) {
                        store.addToCinemaList(list.id, entryID: entry.id)
                    }
                }
            }
        }
        Button("重新刮削") {
            Task { await store.rescrapeCinema(entry) }
        }
        Button("手动刮削…") { onManualMatch() }
        Button("选择海报…") { onArtwork(.poster) }
        Button("选择背景…") { onArtwork(.backdrop) }
        if store.cinemaVersionCount(for: entry) > 1 {
            Button(store.isCinemaDefaultVersion(entry) ? "已是默认版本" : "设为默认版本") {
                store.setCinemaDefaultVersion(entry)
            }
            .disabled(store.isCinemaDefaultVersion(entry))
        }
        Button("在访达中显示") { store.revealCinemaEntryInFinder(entry) }
        if entry.file.cloudMountID != nil {
            Button("缓存到图库") {
                Task { await store.cacheCinemaEntryToLibrary(entry) }
            }
        }
        Button(store.cinemaProgress[entry.id]?.isFinished == true ? "标记为未看" : "标记为已看") {
            let watched = store.cinemaProgress[entry.id]?.isFinished != true
            store.setCinemaWatched(entry, watched: watched)
        }
        Button("复制文件路径") {
            let text = entry.file.cloudPath ?? entry.file.filename
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            store.showToast("已复制路径")
        }
        if entry.file.isCloud {
            Button("在资料库中显示") {
                if let mountID = entry.file.cloudMountID {
                    store.navigate(to: .cloudMount(mountID))
                }
            }
        }
        Divider()
        Button("忽略（以后不刮削）") {
            store.ignoreCinemaEntry(entry)
        }
        Button("删除视频文件…", role: .destructive) {
            store.confirmDeleteCinemaEntries([entry], title: entry.title)
        }
    }
}

// MARK: - 列表行

struct CinemaListRow: View {
    let artworkURL: String?
    let fallbackPhoto: PhotoItem?
    let title: String
    let subtitle: String
    let year: String
    let rating: Double?
    let genres: String
    let spec: String
    let badge: String
    let progress: CinemaProgressRecord?
    let onOpen: () -> Void
    /// 单击先选中；默认同时进详情，关掉后单击只选中、双击才进详情。
    var selected = false
    var onSelect: (() -> Void)?
    var onPlay: (() -> Void)?
    var singleClickOpensDetail = true

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            poster

            titleColumn
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)

            Text(year)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            ratingView
                .frame(width: 56, alignment: .leading)

            Text(genres == "—" ? "" : genres)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            Text(spec == "—" ? "" : spec)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            statusView
                .frame(width: 104, alignment: .trailing)

            playKey
                .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? LumaBrand.amber.opacity(0.10)
                             : (hovered ? Color.primary.opacity(0.045) : Color.clear))
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(LumaBrand.amber)
                    .frame(width: 2)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.055))
                .frame(height: 0.5)
                .padding(.leading, 12)
        }
        .contentShape(Rectangle())
        .modifier(CinemaFocusRing(active: selected))
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture {
            onSelect?()
            if singleClickOpensDetail || onSelect == nil {
                onOpen()
            }
        }
        .help(subtitle)
    }

    var poster: some View {
        ZStack {
            if let artworkURL {
                CinemaArtwork(urlString: artworkURL, contentMode: .fill)
            } else if let fallbackPhoto {
                PhotoThumbnailView(photo: fallbackPhoto, purpose: .cover(70))
            }
        }
        .frame(width: 44, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(hovered ? 0.18 : 0.06), radius: 4, y: 2)
    }

    var titleColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(hovered ? 1 : 0.92))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let progress, progress.fraction > 0.01, !progress.isFinished {
                HStack(spacing: 6) {
                    progressBar(progress.fraction)
                        .frame(maxWidth: 160)
                    Text("已看 \(Int(progress.fraction * 100))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(LumaBrand.amber)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 2)
    }

    @ViewBuilder
    var ratingView: some View {
        if let rating, rating > 0 {
            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(LumaBrand.amber)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    var statusView: some View {
        HStack(spacing: 5) {
            // 文档约定：状态点只在列表出现：绿=已看、琥珀=有进度、红=未识别。
            Circle()
                .fill(statusDotColor)
                .frame(width: 5, height: 5)
            Text(statusText)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(statusTextColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusDotColor.opacity(0.10), in: Capsule())
    }

    var statusText: String {
        if badge == "未识别" { return "未识别" }
        guard let progress else { return badge }
        if progress.isFinished { return "已看完" }
        if progress.fraction > 0.01 { return "\(Int(progress.fraction * 100))%" }
        return badge
    }

    var statusTextColor: Color {
        if badge == "未识别" { return LumaBrand.coral }
        guard let progress else { return .secondary }
        if progress.isFinished { return .green }
        return progress.fraction > 0.01 ? LumaBrand.amber : .secondary
    }

    @ViewBuilder
    var playKey: some View {
        if let onPlay, hovered {
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 22, height: 22)
                    .background(LumaBrand.amber, in: Circle())
            }
            .buttonStyle(.plain)
            .help("播放")
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.45))
        }
    }

    var statusDotColor: Color {
        if badge == "未识别" { return LumaBrand.coral }
        guard let progress else { return Color.secondary.opacity(0.35) }
        if progress.isFinished { return .green }
        return progress.fraction > 0.01 ? LumaBrand.amber : Color.secondary.opacity(0.35)
    }
}

// MARK: - 卡片模式宽幅卡

/// 卡片模式的宽幅卡：16:9 背景图 + 底部信息层。
/// 悬停浮起并出现播放键；信息层只保留片名、年份 / 类型、评分、规格与进度。
struct CinemaWideCard: View {
    let title: String
    let meta: String
    let artworkURL: String?
    let fallbackPhoto: PhotoItem?
    let rating: Double?
    let badges: [String]
    let progressFraction: Double?
    let progressText: String?
    let onOpen: () -> Void
    let onPlay: () -> Void

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork

            LinearGradient(colors: [.clear, .black.opacity(0.20), .black.opacity(0.82)],
                           startPoint: .center, endPoint: .bottom)

            info
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovered ? LumaBrand.amber.opacity(0.45) : Color.white.opacity(0.08),
                              lineWidth: hovered ? 1 : 0.8)
        }
        .overlay(alignment: .topLeading) { badgeRow }
        .overlay(alignment: .topTrailing) { playKey }
        .shadow(color: .black.opacity(hovered ? 0.26 : 0.10),
                radius: hovered ? 16 : 8,
                y: hovered ? 8 : 4)
        .scaleEffect(hovered ? 1.012 : 1)
        .animation(.easeOut(duration: 0.16), value: hovered)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .help(meta.isEmpty ? title : "\(title) · \(meta)")
    }

    var artwork: some View {
        ZStack {
            Color.black.opacity(0.30)
            if let artworkURL {
                CinemaArtwork(urlString: artworkURL, contentMode: .fill)
            } else if let fallbackPhoto {
                PhotoThumbnailView(photo: fallbackPhoto, purpose: .cover(600))
            } else {
                LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            HStack(spacing: 8) {
                if let rating, rating > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8.5))
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(LumaBrand.amber)
                }
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let progressText {
                    Text(progressText)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
            }
            if let progressFraction, progressFraction > 0.01 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.20))
                        Capsule()
                            .fill(LumaBrand.amber)
                            .frame(width: max(2, geo.size.width * min(1, progressFraction)))
                    }
                }
                .frame(height: 2.5)
                .padding(.top, 1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var badgeRow: some View {
        HStack(spacing: 5) {
            ForEach(badges, id: \.self) { badge in
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.42), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
                    }
            }
        }
        .padding(12)
    }

    var playKey: some View {
        Button(action: onPlay) {
            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(LumaBrand.amber.opacity(hovered ? 1 : 0), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(hovered ? 0 : 0.16), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(hovered ? 0.28 : 0), radius: 8, y: 3)
                .opacity(hovered ? 1 : 0)
                .scaleEffect(hovered ? 1 : 0.86)
                .animation(.easeOut(duration: 0.14), value: hovered)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .allowsHitTesting(hovered)
        .help("播放")
    }
}
