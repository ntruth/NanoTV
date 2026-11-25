import SwiftUI
import AppKit

struct PhotoCell: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var selectionModel: SelectionModel
    let photo: PhotoItem
    let width: CGFloat
    let height: CGFloat
    /// 指定圆角；瀑布流等卡片式布局会传更大的半径。
    var cornerRadius: CGFloat?
    /// 常驻投影：让卡片从背景里浮起来（瀑布流使用）。
    var elevated: Bool = false
    /// 非图库网格（地图 / 地点 / 卡片墙）打开查看器时的顺序基准，用于序号、总数与左右翻页。
    var viewerContext: [PhotoItem]?
    /// 堆叠网格里这张代表图的整组张数（网格统一算好传入，避免每格重复计算指纹）。
    var stackCount: Int = 1
    /// 这摞照片是否来自连拍组：连拍双击进查看器整组浏览，其它堆叠双击原地展开。
    var stackIsBurst: Bool = false
    @State private var image: NSImage?
    @State private var didLoad = false
    @State private var isHovering = false
    /// 鼠标在格子里的位置：让悬停高光跟着指针走，画面不位移也能有玻璃质感。
    @State private var hoverPoint: CGPoint?

    private var isSelected: Bool { selectionModel.ids.contains(photo.id) }

    /// 读屏也播报视频时长（网格角标只是视觉提示）。
    private var accessibilityValueText: String {
        var parts = [DateText.dayFormatter.string(from: photo.capturedAt)]
        if photo.isVideo, settings.metadata.duration, let duration = photo.duration, duration > 0 {
            parts.append(formatDuration(duration))
        }
        return parts.joined(separator: " · ")
    }

    /// 网格单元格跟随设置里的小封面圆角，和侧边栏缩略图保持同一套半径。
    private var corner: CGFloat { cornerRadius ?? settings.smallCoverRadius }

    /// 网格加载键：只有格子尺寸档位变化时才重新解码缩略图。
    private var gridLoadKey: String {
        "\(photo.cacheKey)|\(ImageLoader.pixelBucket(for: max(width, height) * 2))"
    }

    private var actionIDs: Set<UUID> {
        selectionModel.ids.contains(photo.id) && !selectionModel.ids.isEmpty ? selectionModel.ids : [photo.id]
    }

    /// 悬停提示：鼠标停在缩略图上就能确认文件名、拍摄时间与规格，不用打开信息面板。
    private var hoverHelpText: String {
        var parts: [String] = [photo.displayFilename,
                               DateText.dayFormatter.string(from: photo.capturedAt)]
        if photo.pixelWidth > 0, photo.pixelHeight > 0 {
            parts.append("\(photo.pixelWidth)×\(photo.pixelHeight)")
        }
        if photo.fileSize > 0 {
            parts.append(formatFileSize(photo.fileSize))
        }
        if photo.isVideo, let duration = photo.duration, duration > 0 {
            parts.append(formatDuration(duration))
        }
        if stackCount > 1 {
            parts.append(store.isStackExpanded(photo.id)
                         ? "已展开的堆叠 · \(stackCount) 张，双击收起"
                         : "堆叠 · \(stackCount) 张，双击展开")
        }
        return parts.joined(separator: " · ")
    }

    /// 按设置打开：查看器 / 编辑器 / 系统默认应用。
    private func openPhotoBySettings() {
        // 地图 / 地点 / 卡片墙这类网格自带顺序，查看器序号与翻页以它为准。
        if let viewerContext, settings.photoOpenMode == .viewer {
            store.openViewer(photo.id, context: viewerContext)
        } else {
            store.openPhoto(photo.id, by: settings.photoOpenMode)
        }
    }

    // MARK: 元数据浮层

    private var metadata: MetadataOptions { settings.metadata }

    private var metadataChips: [PhotoMetadataChip] {
        var chips: [PhotoMetadataChip] = []
        if metadata.edited, photo.hasEdits {
            chips.append(PhotoMetadataChip(id: "edited", icon: "slider.horizontal.3", text: "已编辑"))
        }
        if metadata.fileType {
            let ext = (photo.displayFilename as NSString).pathExtension.uppercased()
            chips.append(PhotoMetadataChip(id: "type", icon: nil,
                                           text: ext.isEmpty ? (photo.isVideo ? "视频" : "照片") : ext))
        }
        if metadata.fileType, photo.isLivePhoto {
            chips.append(PhotoMetadataChip(id: "live", icon: "livephoto", text: "实况"))
        }
        if metadata.resolution, photo.pixelWidth > 0, photo.pixelHeight > 0 {
            chips.append(PhotoMetadataChip(id: "size",
                                           icon: nil,
                                           text: "\(photo.pixelWidth)×\(photo.pixelHeight)"))
        }
        if metadata.fileSize, photo.fileSize > 0 {
            chips.append(PhotoMetadataChip(id: "bytes",
                                           icon: nil,
                                           text: formatFileSize(photo.fileSize)))
        }
        if metadata.camera, let camera = photo.model ?? photo.make {
            chips.append(PhotoMetadataChip(id: "camera", icon: "camera", text: camera))
        }
        if metadata.location, let place = photo.placeTitle {
            chips.append(PhotoMetadataChip(id: "place",
                                           icon: "mappin.and.ellipse",
                                           text: place))
        }
        if metadata.capturedDate {
            chips.append(PhotoMetadataChip(id: "date",
                                           icon: nil,
                                           text: DateText.dayFormatter.string(from: photo.capturedAt)))
        }
        if metadata.keywords, let tags = photo.keywords, !tags.isEmpty {
            chips.append(PhotoMetadataChip(id: "tags",
                                           icon: "tag",
                                           text: tags.prefix(2).map { "#\($0)" }.joined(separator: " ")))
        }
        if metadata.source {
            let source: String
            if photo.isSystem {
                source = "引用文件"
            } else if photo.isCloud {
                source = "云端"
            } else {
                source = "本地"
            }
            chips.append(PhotoMetadataChip(id: "source", icon: "externaldrive", text: source))
        }
        return chips
    }

    private var metadataOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            if metadata.title {
                Text(photo.displayTitle)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.65), radius: 2, y: 0.5)
                    .padding(.leading, isHovering ? 22 : 0)
            }
            Spacer(minLength: 0)
            if width >= 110 {
                let chips = metadataChips
                if !chips.isEmpty {
                    metadataChipRow(Array(chips.prefix(3)))
                    if chips.count > 3 {
                        metadataChipRow(Array(chips.dropFirst(3).prefix(3)))
                    }
                }
            }
        }
        .padding(7)
        .padding(.bottom, photo.isVideo ? 18 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.08), .black.opacity(0.62)],
                           startPoint: .center,
                           endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }

    private func metadataChipRow(_ chips: [PhotoMetadataChip]) -> some View {
        HStack(spacing: 3) {
            ForEach(chips) { chip in
                HStack(spacing: 2) {
                    if let icon = chip.icon {
                        Image(systemName: icon)
                            .font(.system(size: 7, weight: .semibold))
                    }
                    Text(chip.text)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.8)
                .background(.black.opacity(0.42), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// 悬停时描边高光跟随指针方向，形成一圈会「追光」的边缘。
    private var hoverRimAngle: Angle {
        guard let point = hoverPoint, width > 0, height > 0 else { return .degrees(-45) }
        return .radians(atan2(Double(point.y - height / 2), Double(point.x - width / 2)))
    }

    var body: some View {
        ZStack {
            // 占位：柔和的灰阶渐变，避免加载时出现一整块死灰。
            LinearGradient(colors: [Color(nsColor: .quaternaryLabelColor).opacity(0.22),
                                    Color(nsColor: .quaternaryLabelColor).opacity(0.10)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)

            if let image {
                // 必须把图片约束在单元格尺寸内：aspectRatio(.fill) 会让图片按自身比例撑大
                // ZStack，导致右下角的时长角标被外层裁掉（正方形网格尤其明显）。
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .scaleEffect(isHovering ? 1.03 : 1)
                    .brightness(isHovering ? 0.07 : 0)
                    .saturation(isHovering ? 1.08 : 1)
                    .clipped()
                    .transition(.opacity)
            } else if didLoad {
                Image(systemName: photo.isVideo ? "video" : "photo")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            }

            // 悬停质感：轻微放大提亮 + 斜向玻璃反光 + 跟随指针的柔和高光。
            if isHovering {
                LinearGradient(colors: [Color.white.opacity(0.20),
                                        .clear,
                                        Color.black.opacity(0.10)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                    .blendMode(.softLight)
                    .allowsHitTesting(false)

                GeometryReader { proxy in
                    let point = hoverPoint ?? CGPoint(x: proxy.size.width / 2,
                                                      y: proxy.size.height / 2)
                    RadialGradient(colors: [Color.white.opacity(0.34), .clear],
                                   center: UnitPoint(x: min(max(point.x / max(proxy.size.width, 1), 0), 1),
                                                     y: min(max(point.y / max(proxy.size.height, 1), 0), 1)),
                                   startRadius: 0,
                                   endRadius: max(proxy.size.width, proxy.size.height) * 0.9)
                        .blendMode(.softLight)
                }
                .allowsHitTesting(false)
            }

            if settings.metadata.hasTextOverlay {
                metadataOverlay
            }

            // 视频角标：始终显示，让视频在网格里一眼可辨；右下角对齐系统「照片」。
            if photo.isVideo {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 3) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 8, weight: .semibold))
                            if settings.metadata.duration, let duration = photo.duration, duration > 0 {
                                Text(formatDuration(duration))
                                    .font(.system(size: 9, weight: .semibold))
                                    .monospacedDigit()
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.42), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                    .padding(6)
                }
                .allowsHitTesting(false)
            }

            if photo.isFavorite, settings.metadata.favorite {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "heart.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.32), in: Circle())
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.3), radius: 2)
                    }
                    Spacer()
                }
                .padding(6)
                .allowsHitTesting(false)
            }

            // 堆叠角标：左上角显示整组张数，一眼看出这是一摞照片。
            if stackCount > 1 {
                VStack {
                    HStack(spacing: 0) {
                        HStack(spacing: 2.5) {
                            Image(systemName: "square.stack.3d.down.right.fill")
                                .font(.system(size: 7.5, weight: .semibold))
                            Text("\(stackCount)")
                                .font(.system(size: 9, weight: .semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.46), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .allowsHitTesting(false)
            }

            // 色标：左侧细条，不遮挡画面；与评分 / 旗标共同构成整理状态。
            if photo.labelColor != .none {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(photo.labelColor.color)
                        .frame(width: 3)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
            }

            // 评分 / 旗标：左下角小胶囊，避免与右下角视频时长冲突。
            if photo.starRating > 0 || photo.pickFlag != .none {
                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        if photo.starRating > 0 {
                            HStack(spacing: 1.5) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 7.5, weight: .semibold))
                                Text("\(photo.starRating)")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .background(.black.opacity(0.44), in: Capsule())
                        }
                        if photo.pickFlag != .none {
                            Image(systemName: photo.pickFlag.icon)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(3.5)
                                .background(photo.pickFlag.color.opacity(0.82), in: Circle())
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                }
                .allowsHitTesting(false)
            }

            // 选中态只保留强调色描边，不再叠加勾选角标。
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            // 常驻发丝边；悬停时换成跟随指针方向的强调色渐变描边，并带一圈柔和光晕。
            if isHovering && !isSelected {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        AngularGradient(colors: [
                            Color.white.opacity(0.85),
                            settings.accentColor.opacity(0.85),
                            Color.white.opacity(0.25),
                            settings.accentColor.opacity(0.55),
                            Color.white.opacity(0.85)
                        ], center: .center, angle: hoverRimAngle),
                        lineWidth: 1.6
                    )
                    .shadow(color: settings.accentColor.opacity(0.45), radius: 6)
                    .allowsHitTesting(false)
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
        }
        .overlay(alignment: .top) {
            // 顶部 1px 高光，模拟玻璃边缘受光；只在悬停时出现，不做扫光动画。
            LinearGradient(colors: [.white.opacity(isHovering ? 0.45 : 0), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 1)
                .padding(.horizontal, corner + 2)
                .allowsHitTesting(false)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
        }
        .overlay {
            if isSelected {
                // 内圈白色细线让彩色描边在亮色照片上也能看清。
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .inset(by: 1.5)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
            }
        }
        .modifier(PhotoCellShadow(selected: isSelected, elevated: elevated))
        .animation(settings.motion.hover, value: isHovering)
        .animation(.easeOut(duration: 0.18), value: image != nil)
        .contentShape(Rectangle())
        .onDrag {
            PhotoDrag.provider(for: actionIDs)
        } preview: {
            PhotoDragPreview(image: image, count: actionIDs.count)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hoverPoint = point
                if !isHovering { isHovering = true }
            case .ended:
                isHovering = false
                hoverPoint = nil
            }
        }
        .photoClickActions(
            single: {
                // 单击只负责选择；打开走双击（或键盘回车），避免点选时被查看器打断。
                let flags = NSEvent.modifierFlags
                if flags.contains(.command) || flags.contains(.shift) {
                    store.handleTap(photo.id)
                } else if selectionModel.ids.contains(photo.id), selectionModel.ids.count > 1 {
                    // 在多选中再次单击其中一项：保留多选，只更新锚点。
                    store.selectionAnchorID = photo.id
                } else {
                    store.handleTap(photo.id)
                }
            },
            double: {
                if stackCount > 1, store.isStackExpanded(photo.id) {
                    // 已展开的堆叠：双击收起。
                    withAnimation(settings.motion.layout) {
                        store.toggleStackExpansion(photo.id)
                    }
                } else if stackCount > 1, !stackIsBurst {
                    // 同场景 / 实况堆叠：双击在原地铺开整组。
                    withAnimation(settings.motion.layout) {
                        store.toggleStackExpansion(photo.id)
                    }
                } else {
                    // 连拍组的代表图直接进查看器：查看器本身就按整组浏览。
                    openPhotoBySettings()
                }
            }
        )
        .onDrop(of: [.text], isTargeted: nil) { providers, location in
            // 系统相簿：拖拽改顺序，经 PhotoKit 写回「照片」。
            if let systemAlbumID = store.currentSystemAlbumID {
                PhotoDrag.loadIDs(from: providers) { ids in
                    guard !ids.isEmpty, !ids.contains(photo.id) else { return }
                    Task { @MainActor in
                        store.moveSystemPhotos(Set(ids),
                                               inSystemAlbum: systemAlbumID,
                                               before: photo.id,
                                               after: location.x > width / 2)
                    }
                }
                return true
            }
            guard let albumID = store.currentAlbumID else { return false }
            PhotoDrag.loadIDs(from: providers) { ids in
                guard let draggedID = ids.first, draggedID != photo.id else { return }
                Task { @MainActor in
                    store.moveAlbumPhotos(albumID: albumID,
                                          moving: Set(ids),
                                          targetID: photo.id,
                                          after: location.x > width / 2)
                }
            }
            return true
        }
        .contextMenu {
            PhotoContextMenu(photo: photo, actionIDs: actionIDs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.displayTitle)
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint("单击选择；双击打开；按住 ⌘ 或 ⇧ 单击可多选")
        .help(hoverHelpText)
        .task(id: gridLoadKey) {
            didLoad = false
            let loaded = await PhotoThumbnailLoader.load(photo: photo,
                                                         purpose: .grid(maxPixel: max(width, height) * 2),
                                                         store: store) { quick in
                // 快速层先出图；滑出视野时任务被取消，目标档位不会再覆盖。
                image = quick
                didLoad = true
            }
            guard !Task.isCancelled else { return }
            if let loaded { image = loaded }
            didLoad = true
        }
    }

}

/// 网格与列表共用的照片右键菜单。
struct PhotoContextMenu: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var selectionModel: SelectionModel
    let photo: PhotoItem
    /// 右键目标：点击的项目在选区里时是整选区，否则只有这一项（由 `PhotoCell` 计算）。
    let actionIDs: Set<UUID>

    /// 导出 / 旋转 / 打印等仍以「选区」为入参的方法，先同步一次选区。
    private func selectTargets() {
        selectionModel.ids = actionIDs
    }

    var body: some View {
        Group {
            stackItems
            menuItems
        }
    }

    /// 堆叠组：展开 / 收起整组（堆叠关闭时 `stackCount` 恒为 1，这里自动隐藏）。
    @ViewBuilder
    private var stackItems: some View {
        let count = store.stackCount(for: photo.id)
        if count > 1 {
            Button(store.isStackExpanded(photo.id)
                   ? "收起堆叠（\(count) 张）"
                   : "展开堆叠（\(count) 张）") {
                withAnimation(.snappy(duration: 0.22)) {
                    store.toggleStackExpansion(photo.id)
                }
            }
            Divider()
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        // 菜单文案按整选区状态显示，多选时不会出现「收藏」却实际批量取消的错觉。
        let flags = store.selectionCommonFlags(actionIDs)
        if photo.isSystem {
            Button("打开") {
                store.openViewer(photo.id)
            }
            if !photo.isVideo {
                Button("查找相似照片") {
                    store.findSimilarPhotos(to: photo.id)
                }
            }
            // 当前图库就是官方「照片」图库时，拾光可以补充元数据（只写拾光数据库）。
            if store.canEditNativeOverlay {
                Button(flags.allFavorite ? "取消收藏" : "收藏") {
                    store.toggleFavorite(ids: actionIDs)
                }
                Button(flags.allHidden ? "取消隐藏" : "隐藏") {
                    store.setHidden(actionIDs, hidden: !flags.allHidden)
                }
                Button("添加关键词…") {
                    selectTargets()
                    store.showKeywordManager = true
                }
                if store.canEditMetadataWorkflow {
                    PhotoMetadataMenu(photo: photo, actionIDs: actionIDs)
                }
            }
            // 官方库作为当前图库时，相簿的增删改与照片归入都通过 PhotoKit 写回「照片」。
            if store.canManageSystemAlbums {
                if !store.systemAlbums.isEmpty || !store.systemFolders.isEmpty {
                    // 与侧边栏同一棵树、同一顺序：文件夹展开成子菜单，相簿按图库原始顺序排列。
                    Menu("加入相簿") {
                        SystemAlbumMenuItems(parent: nil, ids: actionIDs)
                    }
                }
                if case .systemAlbum(let albumID) = store.sidebarItem {
                    Divider()
                    Button("移出此相簿") {
                        store.removeSystemPhotos(actionIDs, fromSystemAlbum: albumID)
                    }
                    Button("移到最前") {
                        store.moveSystemPhotos(actionIDs, inSystemAlbum: albumID, toTop: true)
                    }
                    Button("移到最后") {
                        store.moveSystemPhotos(actionIDs, inSystemAlbum: albumID, toTop: false)
                    }
                    if !store.systemAlbums.isEmpty || !store.systemFolders.isEmpty {
                        Menu("移动到相簿") {
                            SystemAlbumMenuItems(parent: nil, ids: actionIDs, movingFrom: albumID)
                        }
                    }
                }
                Divider()
                if !photo.isVideo {
                    Button("编辑…") {
                        store.openEditor(photo.id)
                    }
                }
                Button("修改拍摄信息…") {
                    store.presentSystemMetadataEditor(actionIDs)
                }
                Button("新建相簿并加入所选…") {
                    store.presentNewSystemAlbumWithPhotos(actionIDs)
                }
                Button("移到「照片」的最近删除", role: .destructive) {
                    store.confirmDelete(actionIDs)
                }
            }
            if actionIDs.count > 1 {
                Button("导出所选到文件夹…") {
                    selectTargets()
                    store.presentBatchExport()
                }
            } else {
                Button("导出…") {
                    store.export(photo.id)
                }
            }
            Button("在访达中显示") {
                store.revealInFinder(ids: actionIDs)
            }
            if !photo.isVideo {
                Button("设为桌面背景") {
                    store.setAsDesktopBackground(photo.id)
                }
            }
            Divider()
            Button("导入到我的图库") {
                selectTargets()
                store.importSystemSelectionToLibrary()
            }
        } else if photo.isCloud {
            Button("打开") {
                store.openViewer(photo.id)
            }
            if !photo.isVideo {
                Button("查找相似照片") {
                    store.findSimilarPhotos(to: photo.id)
                }
            }
            Button(flags.allFavorite ? "取消收藏" : "收藏") {
                store.toggleFavorite(ids: actionIDs)
            }
            if photo.isVideo {
                Divider()
                cinemaMenu
            }
            Button("添加关键词…") {
                selectTargets()
                store.showKeywordManager = true
            }
            if store.isCurrentCloudWritable {
                Button("重命名…") {
                    store.requestCloudRename(photo.id)
                }
            }
            if actionIDs.count > 1 {
                Button("导出所选到文件夹…") {
                    selectTargets()
                    store.presentBatchExport()
                }
            } else {
                Button("导出…") {
                    store.export(photo.id)
                }
            }
            Button("幻灯片播放") {
                selectTargets()
                store.presentSlideshow()
            }
            if !photo.isVideo {
                Button("设为桌面背景") {
                    store.setAsDesktopBackground(photo.id)
                }
            }
            Button("打印…") {
                selectTargets()
                store.printCommand()
            }
            if store.isCurrentCloudSMB {
                Button("在访达中显示") {
                    store.revealInFinder(photo.id)
                }
            }
            Divider()
            Button("复制文件地址") {
                Task {
                    guard let url = await store.cloudStream(for: photo)?.url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            if store.isCurrentCloudWritable {
                Divider()
                Button("从云端删除…", role: .destructive) {
                    store.confirmDeleteCloud(actionIDs)
                }
            }
        } else if photo.isDeleted {
            Button("恢复") {
                store.restore(actionIDs)
            }
            Button("永久删除…", role: .destructive) {
                store.confirmPermanentDelete(actionIDs)
            }
        } else {
            Button("打开") {
                store.openViewer(photo.id)
            }
            if !photo.isVideo {
                Button("查找相似照片") {
                    store.findSimilarPhotos(to: photo.id)
                }
            }
            Button(flags.allFavorite ? "取消收藏" : "收藏") {
                store.toggleFavorite(ids: actionIDs)
            }
            if photo.isVideo {
                Divider()
                cinemaMenu
            }
            Menu("添加到相簿") {
                // 与侧边栏一致：文件夹 → 子文件夹 → 相簿，名称按本地排序。
                LocalAlbumMenuItems(parentFolderID: nil, ids: actionIDs)
                if store.albums.isEmpty, store.folders.isEmpty {
                    Text("暂无相簿")
                } else {
                    Divider()
                }
                Button("新建相簿…") {
                    store.showNewAlbumSheet = true
                }
            }
            if let albumID = store.currentAlbumID {
                if store.currentAlbumCoverID == photo.id {
                    Button("恢复自动封面") {
                        store.setAlbumCover(nil, for: albumID)
                    }
                } else {
                    Button("设为相册封面") {
                        store.setAlbumCover(photo.id, for: albumID)
                    }
                }
            }
            Button(flags.allHidden ? "取消隐藏" : "隐藏") {
                store.setHidden(actionIDs, hidden: !flags.allHidden)
            }
            Button("添加关键词…") {
                selectTargets()
                store.showKeywordManager = true
            }
            if store.canEditMetadataWorkflow {
                PhotoMetadataMenu(photo: photo, actionIDs: actionIDs)
            }
            if !photo.isVideo {
                Button("压缩…") {
                    store.presentCompression(for: actionIDs)
                }
                if PhotoCompressor.hasBackup(for: photo) {
                    Button("还原压缩前的原图") {
                        store.revertCompression(photo.id)
                    }
                }
            }
            if actionIDs.count > 1 {
                Button("导出所选到文件夹…") {
                    selectTargets()
                    store.presentBatchExport()
                }
            }
            if !photo.isReadOnly {
                Button("批量更改…") {
                    selectTargets()
                    store.presentBatchChange()
                }
            }
            Divider()
            if !photo.isVideo {
                Button("编辑…") {
                    store.openEditor(photo.id)
                }
                if photo.hasEdits {
                    Button("复制编辑点") {
                        store.copyEdits(photo.id)
                    }
                }
                if store.copiedEditRecipe != nil {
                    Button("粘贴编辑点") {
                        store.pasteEdits(photo.id)
                    }
                }
                Menu("旋转") {
                    Button("向右旋转") {
                        selectTargets()
                        store.rotateCommand(clockwise: true)
                    }
                    Button("向左旋转") {
                        selectTargets()
                        store.rotateCommand(clockwise: false)
                    }
                }
            }
            Button("复制照片") {
                selectTargets()
                store.duplicateCommand()
            }
            Button("打印…") {
                selectTargets()
                store.printCommand()
            }
            Button("幻灯片播放") {
                selectTargets()
                store.presentSlideshow()
            }
            if actionIDs.count == 1 {
                Button("导出…") {
                    store.export(photo.id)
                }
            }
            Button("在访达中显示") {
                store.revealInFinder(ids: actionIDs)
            }
            if !photo.isVideo {
                Button("设为桌面背景") {
                    store.setAsDesktopBackground(photo.id)
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                store.confirmDelete(actionIDs)
            }
        }
    }

    /// 相簿 / 网格里的影院操作：手动匹配、刮削、收藏与加入清单。
    @ViewBuilder
    private var cinemaMenu: some View {
        let targets = actionIDs.compactMap { store.anyPhoto(id: $0) }.filter { $0.isVideo }
        if !targets.isEmpty {
            let entries = targets.compactMap { store.cinemaEntry(for: $0) }
            let allFavorite = targets.allSatisfy { store.cinemaUserState(for: $0.id).favorite }
            Menu("影院") {
                Button(targets.count == 1 ? "手动匹配…" : "手动匹配所选…（\(targets.count)）") {
                    store.cinemaQuickMatch = CinemaQuickMatchRequest(photos: targets)
                }
                Button(entries.isEmpty ? "刮削所选（\(targets.count)）"
                                       : "重新刮削所选（\(targets.count)）") {
                    Task { await store.scrapeCinemaPhotos(targets) }
                }
                Divider()
                Button(allFavorite ? "取消影院收藏" : "加入影院收藏") {
                    store.setCinemaFavorite(!allFavorite, ids: Set(targets.map(\.id)))
                }
                if store.cinemaLists.isEmpty {
                    Text("还没有影院清单")
                } else {
                    Menu("加入影院清单") {
                        ForEach(store.cinemaLists) { list in
                            Button(list.name) {
                                for photo in targets {
                                    store.addToCinemaList(list.id, entryID: photo.id)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("在影院中查看") {
                    if let mountID = photo.cloudMountID {
                        store.navigate(to: .cloudCinema(mountID))
                    } else {
                        store.navigate(to: .cinema)
                    }
                }
            }
        }
    }
}

/// 评分 / 旗标 / 色标的右键子菜单。系统图库作为当前图库时写入拾光叠加数据。
struct PhotoMetadataMenu: View {
    @EnvironmentObject private var store: LibraryStore
    let photo: PhotoItem
    let actionIDs: Set<UUID>

    var body: some View {
        Menu("评分") {
            Button {
                store.setRating(0, ids: actionIDs)
            } label: {
                if photo.starRating == 0 {
                    Label("无评分", systemImage: "checkmark")
                } else {
                    Text("无评分")
                }
            }
            Divider()
            ForEach(1...5, id: \.self) { value in
                Button {
                    store.setRating(value, ids: actionIDs)
                } label: {
                    if photo.starRating == value {
                        Label("\(value) 星", systemImage: "checkmark")
                    } else {
                        Label("\(value) 星", systemImage: "star.fill")
                    }
                }
            }
        }

        Menu("旗标") {
            ForEach(PhotoFlag.allCases) { flag in
                Button {
                    store.setFlag(flag, ids: actionIDs)
                } label: {
                    if photo.pickFlag == flag {
                        Label(flag.title, systemImage: "checkmark")
                    } else {
                        Label(flag.title, systemImage: flag.icon)
                    }
                }
            }
        }

        Menu("色标") {
            ForEach(PhotoColorLabel.allCases) { label in
                Button {
                    store.setColorLabel(label, ids: actionIDs)
                } label: {
                    if photo.labelColor == label {
                        Label(label.title, systemImage: "checkmark")
                    } else {
                        Label(label.title, systemImage: "circle.fill")
                            .foregroundStyle(label.color)
                    }
                }
            }
        }
    }
}

/// 网格中只在选中时添加强调阴影；瀑布流卡片（`elevated`）常驻一层轻投影，
/// 让卡片从背景里浮起来，可见数量由 Lazy 容器限制，不会整库离屏合成。
/// 悬停不改变缩放 / 阴影，避免网格里鼠标划过时卡片跳动。
private struct PhotoCellShadow: ViewModifier {
    let selected: Bool
    var elevated: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if selected || elevated {
            content
                .shadow(color: .black.opacity(elevated ? 0.12 : 0), radius: 6, y: 2)
                .shadow(color: selected ? Color.accentColor.opacity(0.40) : .clear, radius: 11, y: 2)
        } else {
            content
        }
    }
}

struct PhotoMetadataChip: Identifiable {
    let id: String
    let icon: String?
    let text: String
}

/// 收集网格中每个单元格的位置，用于框选命中判断。
struct PhotoFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 框选用的单元格位置缓存。用引用类型保存，更新时不触发视图重排。
final class PhotoFrameCache {
    var frames: [UUID: CGRect] = [:]
}

// MARK: - 单击 / 双击

/// 单击立即回调、双击额外回调的点击处理。
///
/// SwiftUI 同时挂 `onTapGesture(count: 2)` 与单击手势时，单击要等双击判定超时才回调，
/// 网格里表现为「点一下要等一下才选中」。这里只保留一个单击手势，双击靠系统的点击计数
/// （拿不到事件时退回双击间隔判断）识别：第一下点击立刻选中，双击再打开查看器。
private struct PhotoClickModifier: ViewModifier {
    let single: () -> Void
    let double: () -> Void

    @State private var lastClickTime: TimeInterval = 0

    func body(content: Content) -> some View {
        content.onTapGesture {
            if isDoubleClick() {
                self.double()
            } else {
                self.single()
            }
        }
    }

    private func isDoubleClick() -> Bool {
        if let clickCount = NSApp.currentEvent?.clickCount, clickCount >= 2 {
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        let isDouble = now - lastClickTime <= NSEvent.doubleClickInterval
        lastClickTime = isDouble ? 0 : now
        return isDouble
    }
}

extension View {
    /// 单击立即生效（无双击判定延迟）；双击时在单击之外再触发 `double`。
    func photoClickActions(single: @escaping () -> Void,
                           double: @escaping () -> Void) -> some View {
        modifier(PhotoClickModifier(single: single, double: double))
    }
}

// MARK: - 「加入相簿」的层级菜单

/// 系统图库的「加入相簿」子菜单：与侧边栏同一棵树、同一排序（文件夹与相簿按图库原始顺序混排）。
/// 空文件夹不展示，避免菜单里出现点不进去的分支。
private struct SystemAlbumMenuItems: View {
    @EnvironmentObject private var store: LibraryStore

    let parent: Int64?
    let ids: Set<UUID>
    /// 非空时表示「移动到相簿」：从该相簿移出再加到所选相簿。
    var movingFrom: Int64? = nil

    var body: some View {
        let entries = store.systemChildren(of: parent).filter { entry in
            guard case .folder(let folder) = entry else { return true }
            return !store.systemChildren(of: folder.id).isEmpty
        }
        if entries.isEmpty {
            Text("没有可用的相簿").disabled(true)
        } else {
            ForEach(entries) { entry in
                switch entry {
                case .folder(let folder):
                    Menu {
                        SystemAlbumMenuItems(parent: folder.id, ids: ids, movingFrom: movingFrom)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                case .album(let album):
                    if let source = movingFrom {
                        Button(album.name) {
                            store.moveSystemPhotos(ids, fromSystemAlbum: source, toSystemAlbum: album.id)
                        }
                        .disabled(album.id == source)
                    } else {
                        Button(album.name) {
                            store.addSystemPhotos(ids, toSystemAlbum: album.id)
                        }
                    }
                }
            }
        }
    }
}

/// 本地图库的「添加到相簿」子菜单：文件夹先于相簿，名称按本地排序，与侧边栏一致。
private struct LocalAlbumMenuItems: View {
    @EnvironmentObject private var store: LibraryStore

    let parentFolderID: UUID?
    let ids: Set<UUID>

    var body: some View {
        let folders = store.childFolders(of: parentFolderID)
        let albums = store.albums(in: parentFolderID)
        ForEach(folders) { folder in
            Menu {
                LocalAlbumMenuItems(parentFolderID: folder.id, ids: ids)
            } label: {
                Label(folder.name, systemImage: "folder")
            }
        }
        ForEach(albums) { album in
            Button(album.name) {
                store.addToAlbum(album.id, photoIDs: ids)
            }
        }
        if folders.isEmpty, albums.isEmpty {
            Text("这个文件夹里还没有相簿").disabled(true)
        }
    }
}
