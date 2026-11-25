import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 影院页的文件夹视图：目录、面包屑与目录内的视频磁贴。

extension CinemaLibraryView {
    // MARK: 文件夹

    var folderColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16, alignment: .top)]
    }

    var folderVideoColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 158, maximum: 194), spacing: 12, alignment: .top)]
    }

    /// 整棵文件夹树按路径索引：钻取、面包屑和刷新后的兜底都靠它。
    var folderIndex: [String: CinemaFolder] {
        var result: [String: CinemaFolder] = [:]
        func walk(_ folder: CinemaFolder) {
            result[folder.path] = folder
            for child in folder.children { walk(child) }
        }
        folders.forEach(walk)
        return result
    }

    var currentFolder: CinemaFolder? {
        selectedFolderPath.flatMap { folderIndex[$0] }
    }

    var visibleFolders: [CinemaFolder] {
        currentFolder?.children ?? folders
    }

    /// 从顶层到当前目录的路径链，用于面包屑。
    var breadcrumbPaths: [String] {
        guard let selected = selectedFolderPath else { return [] }
        let index = folderIndex
        var paths: [String] = []
        var cursor: String? = selected
        while let current = cursor, let folder = index[current] {
            paths.append(current)
            cursor = folder.parentPath
        }
        return paths.reversed()
    }

    @ViewBuilder
    var folderContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            folderHeader

            if !foldersLoaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在整理文件夹…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if folders.isEmpty {
                folderPlaceholder("还没有可聚合的文件夹",
                                  detail: "先在相簿里扫描这个网盘，或点击顶栏「刮削」生成影院条目。")
            } else if selectedFolderPath != nil, currentFolder == nil {
                folderPlaceholder("这个目录已不存在",
                                  detail: "可能刚被删除或重新扫描过了。")
                Button("返回顶层") { goToRoot() }
                    .controlSize(.small)
            } else {
                folderLevel
            }
        }
    }

    @ViewBuilder
    var folderLevel: some View {
        if !visibleFolders.isEmpty {
            LazyVGrid(columns: folderColumns, alignment: .leading, spacing: 16) {
                ForEach(visibleFolders) { folder in
                    folderCard(folder)
                }
            }
        } else if let currentFolder, currentFolder.photos.isEmpty {
            folderPlaceholder("这个目录里没有视频",
                              detail: "换一层看看，或回到顶层重新扫描。")
        }

        if let currentFolder, !currentFolder.photos.isEmpty {
            folderVideosSection(currentFolder)
        }
    }

    func folderPlaceholder(_ title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    var folderHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // 返回统一收进顶栏控制台（铭牌换成「返回」），这里不再放一枚小箭头：
                // 两处返回并存既难点击，也和顶栏重复。
                Text(currentFolder?.displayTitle ?? "文件夹")
                    .font(.system(size: 15, weight: .semibold))
                Text(folderHeadline)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("按目录聚合 · 点进文件夹可一直往下钻")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)

                if let currentFolder {
                    if scrapingFolderIDs.contains(currentFolder.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            quickScrapeFolder(currentFolder)
                        } label: {
                            Label("刮削本目录", systemImage: "wand.and.stars")
                        }
                        .controlSize(.small)
                        .disabled(currentFolder.subtreePhotos.isEmpty)
                        Button {
                            panelTarget = .folderMatch(currentFolder)
                        } label: {
                            Label("匹配…", systemImage: "magnifyingglass")
                        }
                        .controlSize(.small)
                        .disabled(currentFolder.subtreePhotos.isEmpty)
                    }
                }
                Button {
                    refreshFolders()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            breadcrumb
        }
    }

    var folderHeadline: String {
        if let currentFolder {
            return "\(currentFolder.photos.count) 个视频 · \(currentFolder.children.count) 个子目录"
        }
        return "\(folders.count) 个顶层目录"
    }

    /// 文件夹层级面包屑：与图库相簿 / 网盘目录共用 `LumaBreadcrumbBar`。
    @ViewBuilder
    var breadcrumb: some View {
        if currentFolder != nil {
            HStack(spacing: 8) {
                LumaBreadcrumbBar(crumbs: folderCrumbs) { crumb in
                    selectedFolderPath = crumb.id == "root" ? nil : crumb.id
                }
                Spacer(minLength: 0)
                if let path = currentFolder?.displayPath {
                    Text(path)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// 根 + 每一级目录，选中态由 `LumaBreadcrumbBar` 自己标出最后一级。
    var folderCrumbs: [LumaBreadcrumbBar.Crumb] {
        [LumaBreadcrumbBar.Crumb(id: "root", title: "全部文件夹")]
            + breadcrumbPaths.map { path in
                LumaBreadcrumbBar.Crumb(id: path,
                                        title: folderIndex[path]?.name
                                            ?? LibraryStore.cinemaFolderName(of: path))
            }
    }

    func folderCard(_ folder: CinemaFolder) -> some View {
        let hovered = hoveredFolderID == folder.id
        let scraping = scrapingFolderIDs.contains(folder.id)

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = folder.backdropURL ?? folder.posterURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else if let photo = folder.firstPhoto {
                        PhotoThumbnailView(photo: photo, purpose: .cover(420))
                    } else {
                        Color.secondary.opacity(0.12)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 158)
                .clipped()

                LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.30), .black.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                        Text(folder.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if folder.hasChildren {
                            Text("\(folder.children.count) 个子文件夹")
                                .font(.system(size: 8.5, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.white.opacity(0.18), in: Capsule())
                        }
                        if let kind = folder.kind {
                            Text(kind == .tv ? "剧集" : "电影")
                                .font(.system(size: 8.5, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.white.opacity(0.18), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))

                    Text(folder.displayTitle)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    HStack(spacing: 5) {
                        Text(folderStatusText(folder))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        HStack(spacing: 2) {
                            Text(folder.hasChildren ? "进入" : "查看")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    if scraping {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                            .padding(6)
                            .background(.black.opacity(0.35), in: Circle())
                    } else {
                        folderActionButton("wand.and.stars", help: "刮削这个目录（含子目录）") {
                            quickScrapeFolder(folder)
                        }
                        folderActionButton("magnifyingglass", help: "手动匹配这个目录") {
                            panelTarget = .folderMatch(folder)
                        }
                    }
                }
                .padding(8)
                .opacity(hovered ? 1 : 0.55)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(folder.isMatched ? LumaBrand.amber : Color.secondary.opacity(0.6))
                    .frame(width: 4, height: 4)
                Text(folder.matchedCount > 0 ? "\(folder.matchedCount) 已识别" : "未识别")
                    .foregroundStyle(folder.isMatched ? LumaBrand.amber : Color.secondary)
                if folder.unmatchedCount > 0 {
                    Text("· \(folder.unmatchedCount) 未识别")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(folder.totalCount) 个视频")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovered ? LumaBrand.amber.opacity(0.55) : Color.primary.opacity(0.08),
                              lineWidth: hovered ? 1 : 0.6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            enterFolder(folder)
        }
        .onHover { hovering in
            if hovering {
                hoveredFolderID = folder.id
            } else if hoveredFolderID == folder.id {
                hoveredFolderID = nil
            }
        }
        .contextMenu {
            Button("进入文件夹") { enterFolder(folder) }
            Button("目录详情…") { panelTarget = .folder(folder) }
            Divider()
            Button(folder.subtreePhotos.isEmpty
                   ? "刮削此目录"
                   : "刮削此目录（\(folder.subtreePhotos.count) 个视频）") {
                quickScrapeFolder(folder)
            }
            Button("手动匹配此目录…") { panelTarget = .folderMatch(folder) }
            Divider()
            Button("在影院中查看") {
                if let mountID = folder.mountID {
                    store.navigate(to: .cloudCinema(mountID))
                } else {
                    store.navigate(to: .cinema)
                }
            }
        }
        .help(folder.displayPath)
    }

    /// 当前目录直属的视频：钻到最里层时直接平铺，不用再开面板。
    func folderVideosSection(_ folder: CinemaFolder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("本目录视频")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(folder.photos.count) 个")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: folderVideoColumns, alignment: .leading, spacing: 12) {
                ForEach(folder.photos) { photo in
                    folderVideoTile(photo)
                }
            }
        }
    }

    func folderVideoTile(_ photo: PhotoItem) -> some View {
        let entry = store.cinemaEntries(for: scope)[photo.id]
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = entry?.gridArtworkURL ?? entry?.artworkURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        PhotoThumbnailView(photo: photo, purpose: .cover(190))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .clipped()

                LinearGradient(colors: [.black.opacity(0.42), .clear],
                               startPoint: .bottom, endPoint: .top)
                Text(entry?.matched == true ? "已识别" : "未识别")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background((entry?.matched == true ? LumaBrand.amber : Color.black).opacity(0.85),
                                in: Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(entry?.title ?? photo.displayFilename)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(photo.displayFilename)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let entry {
                detailTarget = .entry(entry)
            } else {
                store.cinemaQuickMatch = CinemaQuickMatchRequest(photos: [photo])
            }
        }
        .contextMenu {
            if let entry {
                Button("播放") { store.openCinema(entry) }
                Button("详情") { detailTarget = .entry(entry) }
                Divider()
            }
            Button("手动匹配…") {
                store.cinemaQuickMatch = CinemaQuickMatchRequest(photos: [photo])
            }
            Button(entry == nil ? "刮削" : "重新刮削") {
                Task { await store.scrapeCinemaPhotos([photo]) }
            }
        }
        .help(photo.displayFilename)
    }

    func folderActionButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.42), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    func folderStatusText(_ folder: CinemaFolder) -> String {
        var parts: [String] = [folder.displayPath]
        if folder.hasChildren {
            parts.append("\(folder.children.count) 个子目录")
        }
        return parts.joined(separator: " · ")
    }

    func quickScrapeFolder(_ folder: CinemaFolder) {
        guard !scrapingFolderIDs.contains(folder.id) else { return }
        scrapingFolderIDs.insert(folder.id)
        Task {
            await store.scrapeCinemaFolder(folder, scope: scope)
            refreshFolders()
            scrapingFolderIDs.remove(folder.id)
        }
    }

    func refreshFolders() {
        foldersLoaded = false
        folders = store.cinemaFolders(for: scope)
        foldersLoaded = true
        syncFolderSelection()
    }

    /// 刷新后如果当前目录已不存在（重扫 / 换盘），回到顶层。
    func syncFolderSelection() {
        guard let selected = selectedFolderPath else { return }
        if folderIndex[selected] == nil {
            selectedFolderPath = nil
        }
    }

    func enterFolder(_ folder: CinemaFolder) {
        selectedFolderPath = folder.path
    }

    func goUp() {
        guard let current = currentFolder else { return }
        selectedFolderPath = current.parentPath.flatMap { folderIndex[$0] }?.path
    }

    func goToRoot() {
        selectedFolderPath = nil
    }
}
