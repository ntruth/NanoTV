import AppKit
import SwiftUI
import LumaContentCore

struct PhotoMosaicView: View {
    let photos: [PhotoItem]
    var count: Int = 4

    var body: some View {
        GeometryReader { geo in
            let visibleCount = photos.isEmpty ? count : min(count, photos.count)
            let spacing: CGFloat = 2
            let cellWidth = max(1, (geo.size.width - spacing * CGFloat(visibleCount - 1)) / CGFloat(visibleCount))
            HStack(spacing: spacing) {
                ForEach(0..<visibleCount, id: \.self) { index in
                    Group {
                        if index < photos.count {
                            PhotoThumbnailView(photo: photos[index])
                        } else {
                            // 缺图占位用语义色，浅色下不会出现深灰黑块。
                            Color.primary.opacity(0.06)
                        }
                    }
                    .frame(width: cellWidth, height: geo.size.height)
                }
            }
        }
    }
}

struct SmartCollectionCard: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let photos: [PhotoItem]
    var tint: Color = .accentColor
    let action: () -> Void
}

struct CollectionsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var hoveredID: String?

    var cards: [SmartCollectionCard] {
        let revisit = store.revisitPhotos
        return [
            SmartCollectionCard(id: "favorites", title: "个人收藏", subtitle: "\(store.photos(for: .favorites).count) 项",
                                icon: "heart.fill", photos: Array(store.photos(for: .favorites).prefix(4)), tint: .pink) {
                store.navigate(to: .favorites)
            },
            SmartCollectionCard(id: "revisit", title: "值得重看", subtitle: "\(revisit.count) 项旧照片",
                                icon: "clock.arrow.circlepath", photos: Array(revisit.prefix(4)), tint: .mint) {
                store.navigate(to: .revisit)
            },
            SmartCollectionCard(id: "recent", title: "最近保存", subtitle: "\(store.photos(for: .recentlySaved).count) 项",
                                icon: "square.and.arrow.down", photos: Array(store.photos(for: .recentlySaved).prefix(4)), tint: .blue) {
                store.navigate(to: .recentlySaved)
            },
            SmartCollectionCard(id: "videos", title: "视频", subtitle: "\(store.photos(for: .videos).count) 个",
                                icon: "video.fill", photos: Array(store.photos(for: .videos).prefix(4)), tint: .purple) {
                store.navigate(to: .videos)
            },
            SmartCollectionCard(id: "screenshots", title: "截屏", subtitle: "\(store.photos(for: .screenshots).count) 项",
                                icon: "camera.viewfinder", photos: Array(store.photos(for: .screenshots).prefix(4)), tint: .teal) {
                store.navigate(to: .screenshots)
            },
            SmartCollectionCard(id: "selfies", title: "自拍", subtitle: "\(store.photos(for: .selfies).count) 项",
                                icon: "person.crop.square", photos: Array(store.photos(for: .selfies).prefix(4)), tint: .orange) {
                store.navigate(to: .selfies)
            },
            SmartCollectionCard(id: "panoramas", title: "全景照片", subtitle: "\(store.photos(for: .panoramas).count) 项",
                                icon: "pano", photos: Array(store.photos(for: .panoramas).prefix(4)), tint: .indigo) {
                store.navigate(to: .panoramas)
            },
            SmartCollectionCard(id: "edited", title: "已编辑", subtitle: "\(store.photos.filter { $0.hasEdits }.count) 项",
                                icon: "slider.horizontal.3", photos: Array(store.photos.filter { $0.hasEdits }.prefix(4)), tint: .gray) {
                store.navigate(to: .library)
                store.photoFilter = .edited
            },
            SmartCollectionCard(id: "loose", title: "不在相簿中", subtitle: "\(loosePhotos.count) 项",
                                icon: "rectangle.stack.badge.minus", photos: Array(loosePhotos.prefix(4)), tint: .brown) {
                store.navigate(to: .library)
                store.photoFilter = .notInAlbum
            }
        ]
    }

    var loosePhotos: [PhotoItem] {
        let ids = Set(store.albums.flatMap { $0.photoIDs })
        return store.photos.filter { $0.deletedAt == nil && !$0.isHidden && !ids.contains($0.id) }
    }

    /// 置顶的「那年今日」，取最近的一年。
    var throwbackHero: PhotoMemory? {
        store.memories.first { $0.kind == .throwback }
    }

    var memoriesToShow: [PhotoMemory] {
        store.memories.filter { $0.id != throwbackHero?.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let hero = throwbackHero {
                    throwbackBanner(hero)
                }

                if !memoriesToShow.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("回忆")
                                .font(.system(size: 17, weight: .semibold))
                            Text("自动生成的影片")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(memoriesToShow) { memory in
                                    memoryCard(memory)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !store.trips.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("旅行")
                                .font(.system(size: 17, weight: .semibold))
                            Text("按时间与地点自动串联")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(store.trips) { trip in
                                    tripCard(trip)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 268, maximum: 380), spacing: 16)], spacing: 16) {
                    ForEach(cards) { card in
                        collectionCard(card)
                            .onTapGesture { card.action() }
                            .onHover { hovering in
                                hoveredID = hovering ? card.id : (hoveredID == card.id ? nil : hoveredID)
                            }
                    }
                }
            }
            .padding(24)
        }
    }

    func throwbackBanner(_ memory: PhotoMemory) -> some View {
        Button {
            store.activeMemory = memory
        } label: {
            ZStack(alignment: .bottomLeading) {
                PhotoMosaicView(photos: Array(memory.photos.prefix(4)))
                LinearGradient(colors: [.clear, .black.opacity(0.82)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                        Text("那年今日")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())

                    Text(memory.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Text(memory.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(18)

                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    }
                    Spacer()
                }
                .padding(16)
            }
            .frame(height: 216)
            .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("播放那年今日")
    }

    func tripCard(_ trip: TripStory) -> some View {
        Button {
            store.activeTrip = trip
        } label: {
            ZStack(alignment: .bottomLeading) {
                PhotoMosaicView(photos: Array(trip.photos.prefix(4)))
                LinearGradient(colors: [.clear, .black.opacity(0.8)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text(trip.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(trip.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .padding(12)

                VStack {
                    HStack {
                        Image(systemName: "airplane.departure")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.3), in: Circle())
                            .background(.ultraThinMaterial, in: Circle())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(10)
            }
            .frame(width: 258, height: 168)
            .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("查看旅行故事线")
    }

    func memoryCard(_ memory: PhotoMemory) -> some View {
        Button {
            store.activeMemory = memory
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let first = memory.photos.first {
                    PhotoThumbnailView(photo: first)
                } else {
                    LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.2)],
                                   startPoint: .top, endPoint: .bottom)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.78)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text(memory.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(memory.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(12)

                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 21))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer()
                }
                .padding(10)
            }
            .frame(width: 178, height: 224)
            .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("播放回忆影片")
    }

    func collectionCard(_ card: SmartCollectionCard) -> some View {
        ZStack(alignment: .bottomLeading) {
            if card.photos.isEmpty {
                LinearGradient(colors: [card.tint.opacity(0.55), card.tint.opacity(0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: card.icon)
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(.primary.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PhotoMosaicView(photos: card.photos)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text(card.subtitle)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(14)

            VStack {
                HStack {
                    Image(systemName: card.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.28), in: Circle())
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay {
                            Circle().strokeBorder(card.tint.opacity(0.55), lineWidth: 0.8)
                        }
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
        }
        .frame(height: 186)
        .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: settings.cardRadius)
                .strokeBorder(Color.white.opacity(hoveredID == card.id ? 0.35 : 0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(hoveredID == card.id ? 0.24 : 0.18),
                radius: hoveredID == card.id ? 14 : 10, y: hoveredID == card.id ? 6 : 4)
        .scaleEffect(hoveredID == card.id && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hoveredID)
        .contentShape(RoundedRectangle(cornerRadius: settings.cardRadius))
    }
}

struct AlbumsOverviewView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    /// 非空时只展示该文件夹下的子文件夹与相簿（点侧边栏文件夹进入时使用）。
    var folderID: UUID? = nil
    @State private var namePrompt: NamePromptPayload?
    @State private var hoveredKey: String?
    @State private var dropTargetAlbumID: UUID?

    /// 卡片墙每行列数：默认尺寸下 5 个，随工具栏缩放变化。
    var body: some View {
        GeometryReader { proxy in
            let liveByID = livePhotoIndex
            let childFolders = visibleFolders
            let childAlbums = visibleAlbums
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if childFolders.isEmpty && childAlbums.isEmpty {
                        emptyState
                    } else if store.albumDisplayStyle == .grid {
                        let folderPhotos = folderPhotosMap(childFolders, liveByID: liveByID)
                        // 按可用宽度均分列宽，默认铺满窗口，不让右侧留空。
                        let spacing: CGFloat = 22
                        let available = max(0, proxy.size.width - 48)
                        let maxFit = max(1, Int((available + spacing) / (120 + spacing)))
                        let columnCount = min(store.cardColumns, maxFit)
                        let itemWidth = max(120, (available - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                                                 count: columnCount),
                                  alignment: .leading,
                                  spacing: 26) {
                            ForEach(childFolders) { folder in
                                folderCard(folder, width: itemWidth,
                                           photos: folderPhotos[folder.id] ?? [])
                            }
                            ForEach(childAlbums) { album in
                                albumCard(album, width: itemWidth,
                                          photo: albumCover(album, liveByID: liveByID))
                            }
                        }
                    } else if store.albumDisplayStyle == .list {
                        listLayout(childFolders: childFolders,
                                   childAlbums: childAlbums,
                                   folderPhotos: folderPhotosMap(childFolders, liveByID: liveByID),
                                   liveByID: liveByID,
                                   width: proxy.size.width)
                    } else {
                        collageLayout(childFolders: childFolders,
                                      childAlbums: childAlbums,
                                      folderPhotos: folderPhotosMap(childFolders, liveByID: liveByID),
                                      liveByID: liveByID)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(settings.motion.layout, value: store.albumDisplayStyle)
        .sheet(item: $namePrompt) { payload in
            NamePromptSheet(payload: payload)
                .environmentObject(store)
        }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // 页面标题与返回层级已由窗口工具栏统一展示，这里只保留数量与操作。
            Text("\(visibleAlbums.count) 个相簿, \(visibleFolders.count) 个文件夹")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            displayStyleMenu
            Menu {
                Button("新建相簿") { namePrompt = .newAlbum(folderID: folderID) }
                Button("新建文件夹") { namePrompt = .newFolder(parentID: folderID) }
            } label: {
                Label("新建", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    var displayStyleMenu: some View {
        AlbumDisplayStyleMenu()
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(folderID == nil ? "还没有相簿" : "这个文件夹是空的")
                .font(.system(size: 17, weight: .semibold))
            Text(folderID == nil
                 ? "新建相簿，或导入文件夹时自动按目录创建。"
                 : "可以在这个文件夹里新建相簿或子文件夹。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("新建相簿") { namePrompt = .newAlbum(folderID: folderID) }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    /// 只展示当前层级的子文件夹：顶层的「所有相簿」是第 1 层，进入文件夹后逐层向下。
    var visibleFolders: [AlbumFolder] {
        store.childFolders(of: folderID)
    }

    /// 只展示当前层级的直接相簿（顶层即未归入任何文件夹的相簿）。
    var visibleAlbums: [Album] {
        store.albums(in: folderID)
    }

    var livePhotoIndex: [UUID: PhotoItem] {
        Dictionary(store.photos.lazy.filter { $0.deletedAt == nil && !$0.isHidden }.map { ($0.id, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// 相簿封面：用户指定优先，否则取相簿内第一张（照片或视频缩略图）。
    func albumCover(_ album: Album, liveByID: [UUID: PhotoItem]) -> PhotoItem? {
        if let coverID = album.coverPhotoID,
           album.photoIDs.contains(coverID),
           let cover = liveByID[coverID] {
            return cover
        }
        for id in album.photoIDs {
            if let photo = liveByID[id] { return photo }
        }
        return nil
    }

    /// 文件夹封面：从子树的相簿里取最多 4 张，用于四宫格缩略图。
    func folderPhotosMap(_ folders: [AlbumFolder],
                                 liveByID: [UUID: PhotoItem]) -> [UUID: [PhotoItem]] {
        var result: [UUID: [PhotoItem]] = [:]
        for folder in folders {
            let folderIDs = store.folderSubtreeIDs(folder.id)
            var photos: [PhotoItem] = []
            for album in store.albums where album.folderID.map({ folderIDs.contains($0) }) ?? false {
                for photo in albumPhotos(album, liveByID: liveByID, limit: 4) where photos.count < 4 {
                    if !photos.contains(where: { $0.id == photo.id }) { photos.append(photo) }
                }
                if photos.count >= 4 { break }
            }
            result[folder.id] = photos
        }
        return result
    }

    // MARK: - 列表 / 拼贴墙

    /// 相簿封面照片：用户指定封面优先，最多取 4 张用于列表与拼贴墙的拼贴。
    func albumPhotos(_ album: Album,
                             liveByID: [UUID: PhotoItem],
                             limit: Int = 4) -> [PhotoItem] {
        var result: [PhotoItem] = []
        if let coverID = album.coverPhotoID, let cover = liveByID[coverID] {
            result.append(cover)
        }
        for id in album.photoIDs where result.count < limit {
            if id == album.coverPhotoID { continue }
            if let photo = liveByID[id] { result.append(photo) }
        }
        return result
    }

    func albumPhotoCount(_ album: Album, liveByID: [UUID: PhotoItem]) -> Int {
        album.photoIDs.reduce(0) { total, id in total + (liveByID[id] == nil ? 0 : 1) }
    }

    func folderAlbumCount(_ folder: AlbumFolder) -> Int {
        let ids = store.folderSubtreeIDs(folder.id)
        return store.albums.reduce(0) { total, album in
            guard let folderID = album.folderID, ids.contains(folderID) else { return total }
            return total + 1
        }
    }

    func listLayout(childFolders: [AlbumFolder],
                            childAlbums: [Album],
                            folderPhotos: [UUID: [PhotoItem]],
                            liveByID: [UUID: PhotoItem],
                            width: CGFloat) -> some View {
        let spacing: CGFloat = 28
        let available = max(240, width - 48)
        let columns = max(1, min(6, Int((available + spacing) / (300 + spacing))))
        let itemWidth = (available - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let thumb = min(160, max(64, CGFloat(store.thumbSize) * 0.75))
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(itemWidth),
                                                            spacing: spacing,
                                                            alignment: .leading),
                                       count: columns),
                         alignment: .leading,
                         spacing: 24) {
            ForEach(childFolders) { folder in
                folderListRow(folder, photo: folderPhotos[folder.id]?.first, thumb: thumb)
            }
            ForEach(childAlbums) { album in
                albumListRow(album,
                             cover: albumCover(album, liveByID: liveByID),
                             liveByID: liveByID,
                             thumb: thumb)
            }
        }
    }

    func collageLayout(childFolders: [AlbumFolder],
                               childAlbums: [Album],
                               folderPhotos: [UUID: [PhotoItem]],
                               liveByID: [UUID: PhotoItem]) -> some View {
        // 拼贴墙的方块跟随工具栏缩放（56…360 → 120…320）。
        let tile = min(320, max(120, CGFloat(store.thumbSize) * 1.7))
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: tile, maximum: tile),
                                            spacing: 10, alignment: .top)],
                         alignment: .leading,
                         spacing: 10) {
            ForEach(childFolders) { folder in
                folderCollageTile(folder, photos: folderPhotos[folder.id] ?? [], side: tile)
            }
            ForEach(childAlbums) { album in
                albumCollageTile(album,
                                 photos: albumPhotos(album, liveByID: liveByID),
                                 liveByID: liveByID,
                                 side: tile)
            }
        }
    }

    func folderListRow(_ folder: AlbumFolder, photo: PhotoItem?, thumb: CGFloat) -> some View {
        AlbumOverviewRow(title: folder.name,
                         subtitle: folderAlbumCount(folder).formatted(),
                         cover: photo,
                         placeholder: .folder,
                         side: thumb,
                         action: { store.navigate(to: .folder(folder.id)) },
                         menu: { folderMenuItems(folder) })
            .accessibilityLabel("文件夹 \(folder.name)")
    }

    func albumListRow(_ album: Album,
                              cover: PhotoItem?,
                              liveByID: [UUID: PhotoItem],
                              thumb: CGFloat) -> some View {
        let count = albumPhotoCount(album, liveByID: liveByID)
        return AlbumOverviewRow(title: album.name,
                                subtitle: count.formatted(),
                                cover: cover,
                                placeholder: .album,
                                side: thumb,
                                highlighted: dropTargetAlbumID == album.id,
                                action: { store.navigate(to: .album(album.id)) },
                                menu: { albumMenuItems(album) })
            .onDrop(of: [.plainText], isTargeted: albumDropBinding(album)) { providers in
                PhotoDrag.loadIDs(from: providers) { ids in
                    guard !ids.isEmpty else { return }
                    store.addToAlbum(album.id, photoIDs: Set(ids))
                }
                return true
            }
            .accessibilityLabel("相簿 \(album.name)")
    }

    func folderCollageTile(_ folder: AlbumFolder, photos: [PhotoItem], side: CGFloat) -> some View {
        AlbumOverviewTile(title: folder.name,
                          subtitle: "\(folderAlbumCount(folder)) 个相簿",
                          photos: photos,
                          placeholder: .folder,
                          side: side,
                          isFolder: true,
                          action: { store.navigate(to: .folder(folder.id)) },
                          menu: { folderMenuItems(folder) })
            .accessibilityLabel("文件夹 \(folder.name)")
    }

    func albumCollageTile(_ album: Album,
                                  photos: [PhotoItem],
                                  liveByID: [UUID: PhotoItem],
                                  side: CGFloat) -> some View {
        let count = albumPhotoCount(album, liveByID: liveByID)
        return AlbumOverviewTile(title: album.name,
                                 subtitle: "\(count) 项",
                                 photos: photos,
                                 placeholder: .album,
                                 side: side,
                                 isFolder: false,
                                 highlighted: dropTargetAlbumID == album.id,
                                 action: { store.navigate(to: .album(album.id)) },
                                 menu: { albumMenuItems(album) })
            .onDrop(of: [.plainText], isTargeted: albumDropBinding(album)) { providers in
                PhotoDrag.loadIDs(from: providers) { ids in
                    guard !ids.isEmpty else { return }
                    store.addToAlbum(album.id, photoIDs: Set(ids))
                }
                return true
            }
            .accessibilityLabel("相簿 \(album.name)")
    }

    func albumDropBinding(_ album: Album) -> Binding<Bool> {
        Binding(
            get: { dropTargetAlbumID == album.id },
            set: { targeted in
                if targeted {
                    dropTargetAlbumID = album.id
                } else if dropTargetAlbumID == album.id {
                    dropTargetAlbumID = nil
                }
            }
        )
    }

    // MARK: - 卡片

    func folderCard(_ folder: AlbumFolder, width: CGFloat, photos: [PhotoItem]) -> some View {
        let key = "folder-\(folder.id.uuidString)"
        return VStack(alignment: .leading, spacing: 8) {
            FolderMosaicImage(photos: photos, side: width)
                .frame(width: width, height: max(120, width * 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(hoveredKey == key ? 0.18 : 0), radius: 14, y: 6)
                .scaleEffect(hoveredKey == key && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hoveredKey)

            caption(folder.name, subtitle: "")
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .onTapGesture {
            store.navigate(to: .folder(folder.id))
        }
        .contextMenu {
            folderMenuItems(folder)
        }
        .accessibilityLabel("文件夹 \(folder.name)")
    }

    /// 文件夹卡片的右键菜单：网格 / 列表 / 拼贴墙共用。
    @ViewBuilder
    func folderMenuItems(_ folder: AlbumFolder) -> some View {
        Button("打开文件夹") { store.navigate(to: .folder(folder.id)) }
        Divider()
        Button("新建相簿…") { namePrompt = .newAlbum(folderID: folder.id) }
        Button("新建子文件夹…") { namePrompt = .newFolder(parentID: folder.id) }
        Divider()
        Button("重命名文件夹…") { namePrompt = .renameFolder(folder.id, current: folder.name) }
        Button("删除文件夹", role: .destructive) { store.deleteFolder(folder.id) }
    }

    /// 相簿卡片的右键菜单：网格 / 列表 / 拼贴墙共用。
    @ViewBuilder
    func albumMenuItems(_ album: Album) -> some View {
        Button("打开相簿") { store.navigate(to: .album(album.id)) }
        Button("重命名相簿…") {
            namePrompt = .renameAlbum(album.id, current: album.name)
        }
        Menu("移到文件夹") {
            Button("相簿顶层") { store.moveAlbum(album.id, toFolder: nil) }
            if !store.folderOptions.isEmpty { Divider() }
            ForEach(store.folderOptions) { option in
                Button(option.path) { store.moveAlbum(album.id, toFolder: option.id) }
            }
        }
        if album.coverPhotoID != nil {
            Divider()
            Button("恢复自动封面") { store.setAlbumCover(nil, for: album.id) }
        }
        Divider()
        Button("删除相簿", role: .destructive) { store.deleteAlbum(album.id) }
    }

    func albumCard(_ album: Album, width: CGFloat, photo: PhotoItem?) -> some View {
        let key = "album-\(album.id.uuidString)"
        let path = album.folderID.map { store.folderPath($0) } ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            AlbumCoverImage(photo: photo, side: width)
                .frame(width: width, height: max(120, width * 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(dropTargetAlbumID == album.id ? Color.accentColor : Color.primary.opacity(0.08),
                                      lineWidth: dropTargetAlbumID == album.id ? 2 : 0.5)
                }
                .shadow(color: .black.opacity(hoveredKey == key ? 0.18 : 0), radius: 14, y: 6)
                .scaleEffect(hoveredKey == key && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hoveredKey)

            caption(album.name, subtitle: path)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .onDrop(of: [.plainText], isTargeted: albumDropBinding(album)) { providers in
            PhotoDrag.loadIDs(from: providers) { ids in
                guard !ids.isEmpty else { return }
                store.addToAlbum(album.id, photoIDs: Set(ids))
            }
            return true
        }
        .onTapGesture {
            store.navigate(to: .album(album.id))
        }
        .contextMenu {
            albumMenuItems(album)
        }
        .accessibilityLabel("相簿 \(album.name)")
    }

    func caption(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 2)
    }
}
