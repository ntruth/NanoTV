import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 合集详情、通知与 PIN 弹窗。

// MARK: - 合集详情页（B3）

struct CinemaCollectionSheet: View {
    let collectionID: Int
    let name: String
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var info: CinemaCollectionInfo?

    var entries: [CinemaEntry] {
        store.cinemaCollection(collectionID: collectionID)
    }

    var versionCount: Int {
        entries.reduce(0) { $0 + max(1, store.cinemaVersions(for: $1).count) }
    }

    var watchedCount: Int {
        entries.filter { store.cinemaProgress[$0.id]?.isFinished == true }.count
    }

    var nextEntry: CinemaEntry? {
        entries.first { !(store.cinemaProgress[$0.id]?.isFinished ?? false) }
    }

    var totalHours: String {
        let seconds = entries.reduce(0.0) { $0 + ($1.file.duration ?? 0) }
        guard seconds > 0 else { return "—" }
        return String(format: "%.1f 小时", seconds / 3600)
    }

    /// 未入库的下一部：只提示，不生成空条目。
    var missingPart: CinemaCollectionPart? {
        guard let info, !info.parts.isEmpty else { return nil }
        // 合集 ID 都是 TMDB 的，只拿 TMDB 条目的 ID 判重。
        let owned = Set(entries.filter { $0.provider == .tmdb }.compactMap(\.tmdbID))
        let pending = info.parts.filter { !owned.contains($0.tmdbID) }
        guard !pending.isEmpty else { return nil }
        let lastYear = entries.last?.year ?? 0
        return pending.first { ($0.year ?? 0) >= lastYear } ?? pending.first
    }

    var body: some View {
        ZStack {
            cinemaSheetBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    posterRow
                    columns
                    fileNote
                }
                .padding(.horizontal, 28)
                .padding(.top, 54)
                .padding(.bottom, 32)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: min(1220, cinemaDetailWindowSize.width),
               height: min(880, cinemaDetailWindowSize.height))
        .preferredColorScheme(.dark)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(14)
            .keyboardShortcut(.cancelAction)
        }
        .task {
            info = await store.cinemaCollectionInfo(collectionID: collectionID)
        }
    }

    var header: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("合集 · COLLECTION")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(LumaBrand.amber.opacity(0.9))
                Text(name)
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                Text("\(entries.count) 部 · \(versionCount) 个版本 · 已看 \(watchedCount) / \(entries.count) · 总时长 \(totalHours)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button {
                    playAll()
                } label: {
                    Label("按上映顺序播放", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(entries.isEmpty)
                Button("关闭") { dismiss() }
                    .controlSize(.regular)
            }
        }
    }

    var posterRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(entries) { entry in
                    Button {
                        open(entry)
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                if let url = entry.artworkURL {
                                    CinemaArtwork(urlString: url, contentMode: .fill)
                                } else {
                                    PhotoThumbnailView(photo: entry.file.photoItem, purpose: .cover(240))
                                }
                            }
                            .frame(width: 118, height: 174)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
                            }
                            .overlay(alignment: .topLeading) {
                                if store.cinemaProgress[entry.id]?.isFinished == true {
                                    Text("已看")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundStyle(LumaBrand.amber)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.black.opacity(0.62)))
                                        .padding(6)
                                }
                            }
                            Text(entry.year.map(String.init) ?? "—")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(entry.title)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    var columns: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) {
                collectionSectionTitle("合集简介")
                if let overview = info?.overview, !overview.isEmpty {
                    CinemaSynopsis(text: overview)
                } else {
                    Text("TMDB 没有提供合集简介。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                HStack(spacing: 7) {
                    chip("自动合集", highlight: true)
                    chip("TMDB 归属")
                    chip("按年份排序")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                collectionSectionTitle("合集统计")
                VStack(spacing: 0) {
                    statRow("影片", "\(entries.count) 部")
                    statRow("版本", "\(versionCount) 个")
                    statRow("已看", "\(watchedCount) 部")
                    if let missingPart {
                        statRow("下一部", "\(missingPart.title)（\(missingPart.year.map(String.init) ?? "未定") 未入库）",
                                highlight: true)
                    } else if let nextEntry {
                        statRow("下一部", nextEntry.title, highlight: true)
                    } else if !entries.isEmpty {
                        statRow("下一部", "全部看完", highlight: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
                }
            }
            .frame(width: 340)
        }
    }

    var fileNote: some View {
        Text("同一部片的多版本在合集里折叠为一个海报，播放前可在详情页选版本。未入库的续集只做提示，不生成空条目。")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    func collectionSectionTitle(_ title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(LumaBrand.amber)
                .frame(width: 3, height: 13)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
        }
    }

    func statRow(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: highlight ? .semibold : .regular))
                .foregroundStyle(highlight ? LumaBrand.amber : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    func chip(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(highlight ? LumaBrand.amber : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(highlight ? LumaBrand.amber.opacity(0.12)
                                                 : Color.primary.opacity(0.06)))
            .overlay {
                Capsule().strokeBorder(highlight ? LumaBrand.amber.opacity(0.30)
                                                 : Color.primary.opacity(0.08), lineWidth: 0.6)
            }
    }

    func playAll() {
        guard let entry = nextEntry ?? entries.first else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            store.openCinema(entry)
        }
    }

    func open(_ entry: CinemaEntry) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onOpenEntry(entry)
        }
    }
}

// MARK: - 通知中心（F4）

struct CinemaNotificationSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var groups: [(String, [CinemaNotification])] {
        let calendar = Calendar.current
        var today: [CinemaNotification] = []
        var week: [CinemaNotification] = []
        var older: [CinemaNotification] = []
        for item in store.cinemaNotifications {
            if calendar.isDateInToday(item.date) {
                today.append(item)
            } else if let days = calendar.dateComponents([.day], from: item.date, to: Date()).day,
                      days < 7 {
                week.append(item)
            } else {
                older.append(item)
            }
        }
        return [("今天", today), ("本周", week), ("更早", older)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if store.cinemaNotifications.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.0) { group in
                            Text(group.0)
                                .font(.system(size: 9.5, weight: .bold))
                                .tracking(1.4)
                                .foregroundStyle(.tertiary)
                            ForEach(group.1) { item in
                                row(item)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 620, height: 560)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
    }

    var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("通知")
                    .font(.system(size: 14, weight: .semibold))
                Text("仅保留最近 30 天")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            if store.cinemaUnreadNotificationCount > 0 {
                Text("\(store.cinemaUnreadNotificationCount) 未读")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(LumaBrand.coral)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(LumaBrand.coral.opacity(0.14)))
            }
            Spacer(minLength: 0)
            Button("全部已读") {
                store.markAllCinemaNotificationsRead()
            }
            .controlSize(.small)
            Button("清空") {
                store.clearCinemaNotifications()
            }
            .controlSize(.small)
            Button("完成") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bell.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有通知")
                .font(.system(size: 12.5, weight: .medium))
            Text("刮削完成、匹配失败和字幕下载都会归档到这里。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func row(_ item: CinemaNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint(item.kind))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12, weight: item.read ? .regular : .semibold))
                    .foregroundStyle(item.read ? Color.secondary : Color.primary)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(timeText(item.date))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if let action = item.action {
                Button(action) {
                    handle(action, item)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(item.read ? Color.primary.opacity(0.025) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(item.read ? Color.white.opacity(0.04) : Color.white.opacity(0.09),
                              lineWidth: 0.6)
        }
        .onTapGesture {
            markRead(item)
        }
    }

    func handle(_ action: String, _ item: CinemaNotification) {
        markRead(item)
        if action == "重试", let key = item.scopeKey {
            dismiss()
            Task { await store.retryCinemaScope(key: key) }
        } else {
            store.postCinemaToast(.info, title: "已标记为处理", detail: item.title)
        }
    }

    func markRead(_ item: CinemaNotification) {
        guard let index = store.cinemaNotifications.firstIndex(where: { $0.id == item.id }),
              !store.cinemaNotifications[index].read else { return }
        store.cinemaNotifications[index].read = true
        store.persistCinemaNotifications()
    }

    func tint(_ kind: CinemaNotificationKind) -> Color {
        switch kind {
        case .success: return .green
        case .failure: return LumaBrand.coral
        case .progress: return LumaBrand.amber
        case .info: return LumaBrand.violet
        }
    }

    func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 文件夹详情

struct CinemaFolderDetailView: View {
    let scope: CinemaScope
    let onPlay: (CinemaEntry) -> Void
    let onOpenEntry: (CinemaEntry) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var folder: CinemaFolder
    /// 已经钻过的目录链，用来返回上一级。
    @State private var trail: [String]
    @State private var scraping = false
    @State private var matchRequest: CinemaQuickMatchRequest?

    init(folder: CinemaFolder,
         scope: CinemaScope,
         onPlay: @escaping (CinemaEntry) -> Void,
         onOpenEntry: @escaping (CinemaEntry) -> Void) {
        self.scope = scope
        self.onPlay = onPlay
        self.onOpenEntry = onOpenEntry
        _folder = State(initialValue: folder)
        _trail = State(initialValue: [folder.path])
    }

    var entriesByID: [UUID: CinemaEntry] {
        Dictionary(folder.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var sortedPhotos: [PhotoItem] {
        folder.photos.sorted { lhs, rhs in
            let left = CinemaScraper.parse(filename: lhs.displayFilename, folderHint: folder.hint)
            let right = CinemaScraper.parse(filename: rhs.displayFilename, folderHint: folder.hint)
            if (left.season ?? 0) != (right.season ?? 0) {
                return (left.season ?? 0) < (right.season ?? 0)
            }
            if (left.episode ?? 0) != (right.episode ?? 0) {
                return (left.episode ?? 0) < (right.episode ?? 0)
            }
            return lhs.displayFilename.localizedStandardCompare(rhs.displayFilename) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(folder.children) { child in
                        childRow(child)
                    }
                    if !folder.children.isEmpty, !sortedPhotos.isEmpty {
                        sectionLabel("本目录视频 · \(sortedPhotos.count)")
                    }
                    ForEach(sortedPhotos) { photo in
                        row(photo)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 760, height: 580)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
        .onChange(of: store.cinemaFolderRefreshToken) { _, _ in
            refresh()
        }
        .sheet(item: $matchRequest) { request in
            CinemaMatchSheet(photos: request.photos, folderHint: folder.hint) {
                matchRequest = nil
                refresh()
            }
            .environmentObject(store)
        }
    }

    func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 7) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    func childRow(_ child: CinemaFolder) -> some View {
        Button {
            trail.append(child.path)
            folder = child
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let url = child.posterURL ?? child.backdropURL {
                            CinemaArtwork(urlString: url, contentMode: .fill)
                        } else if let photo = child.firstPhoto {
                            PhotoThumbnailView(photo: photo, purpose: .cover(120))
                        } else {
                            Color.secondary.opacity(0.12)
                        }
                    }
                    .frame(width: 96, height: 54)
                    .clipped()

                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(child.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("\(child.matchedCount)/\(child.totalCount) 已识别")
                            .foregroundStyle(child.isMatched ? LumaBrand.amber : Color.secondary)
                        Text(child.displayPath)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 9.5))
                }

                Spacer(minLength: 0)

                if child.hasChildren {
                    Text("\(child.children.count) 个子目录")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Text("\(child.photos.count) 个视频")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if trail.count > 1 {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("返回上一级")
                .padding(.top, 32)
            }

            ZStack {
                if let url = folder.posterURL ?? folder.backdropURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else if let photo = folder.firstPhoto {
                    PhotoThumbnailView(photo: photo, purpose: .cover(160))
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 60, height: 90)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.displayTitle)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(folder.displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("\(folder.matchedCount)/\(folder.totalCount) 已识别")
                        .foregroundStyle(folder.isMatched ? LumaBrand.amber : Color.secondary)
                    if folder.episodeCount > 0 {
                        Text("\(folder.episodeCount) 集")
                            .foregroundStyle(.secondary)
                    }
                    Text("本目录 \(folder.photos.count) · 共 \(folder.totalCount) 个视频")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10, weight: .medium))
            }

            Spacer(minLength: 0)

            if scraping {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("刮削中…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("手动匹配…") {
                    matchRequest = CinemaQuickMatchRequest(photos: folder.subtreePhotos)
                }
                .controlSize(.small)
                Button {
                    scrape()
                } label: {
                    Label("刮削此目录", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
            }
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    func row(_ photo: PhotoItem) -> some View {
        let entry = entriesByID[photo.id]
        return HStack(spacing: 10) {
            ZStack {
                if let url = entry?.gridArtworkURL ?? entry?.artworkURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else {
                    PhotoThumbnailView(photo: photo, purpose: .cover(120))
                }
            }
            .frame(width: 96, height: 54)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry?.title ?? photo.displayFilename)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let subtitle = entry?.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                    Text(photo.displayFilename)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 9.5))
            }

            Spacer(minLength: 0)

            Text(entry == nil ? "未刮削" : (entry?.matched == true ? "已识别" : "未识别"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(entry?.matched == true ? LumaBrand.amber : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(entry?.matched == true
                                           ? LumaBrand.amber.opacity(0.14)
                                           : Color.secondary.opacity(0.12)))

            if let entry, entry.matched {
                Button("播放") { onPlay(entry) }
                    .controlSize(.small)
            }
            if let entry {
                Button("详情") { onOpenEntry(entry) }
                    .controlSize(.small)
            }
            if entry?.matched != true {
                Button("匹配") {
                    matchRequest = CinemaQuickMatchRequest(photos: [photo])
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    func scrape() {
        guard !scraping else { return }
        scraping = true
        Task {
            await store.scrapeCinemaFolder(folder, scope: scope)
            refresh()
            scraping = false
        }
    }

    func refresh() {
        if let updated = store.cinemaFolder(path: folder.path, scope: scope) {
            folder = updated
        }
    }

    func goBack() {
        guard trail.count > 1 else { return }
        trail.removeLast()
        guard let path = trail.last,
              let updated = store.cinemaFolder(path: path, scope: scope) else { return }
        folder = updated
    }
}

// MARK: - 家长控制解锁

struct CinemaPINPromptSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var hasPIN: Bool {
        CinemaKeychain.has(.parentalPIN)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(LumaBrand.coral)
                Text("家长控制")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(hasPIN
                 ? "输入 4 位 PIN 解锁本次会话；退出应用后会重新上锁。"
                 : "还没有设置 PIN。可直接解锁，建议到 设置 › 影院 › 家长控制 里设置。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(unlock)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LumaBrand.coral)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("解锁") { unlock() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaBrand.amber)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    func unlock() {
        if store.unlockCinemaParental(pin: pin) {
            dismiss()
        } else {
            errorMessage = "PIN 不正确，请重试。"
            pin = ""
        }
    }
}
