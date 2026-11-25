import SwiftUI
import AppKit

// MARK: - 整理维度

extension OrganizeDimension {
    /// 维度图标与结果网格的强调色。
    var brandColors: [Color] {
        switch self {
        case .rating: return [LumaBrand.amber, LumaBrand.coral]
        case .flag: return [LumaBrand.mint, LumaBrand.cyan]
        case .colorLabel: return [LumaBrand.violet, LumaBrand.pink]
        case .keyword: return [LumaBrand.cyan, LumaBrand.violet]
        }
    }
}

// MARK: - 整理工作室

/// 评分 / 旗标 / 色标的分布与筛选：可交互的统计条与结果网格。
/// 与「人物」「位置」「图库体检」保持一致：先看分布，再下钻到照片。
/// 标题与维度切换在统一工具栏里（见 `GalleryView`），页面本身只留分布条与结果。
struct OrganizeStudioView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var selectionModel: SelectionModel

    /// nil 表示未筛选；评分 0 表示「未评分」；旗标 / 色标用枚举里的 `.none` 表示「未标记」。
    @State private var ratingPick: Int?
    @State private var flagPick: PhotoFlag?
    @State private var colorPick: PhotoColorLabel?
    @State private var keywordPick: KeywordFilter?

    @State private var keywordOptions: [KeywordOption] = []
    @State private var untaggedKeywordCount = 0
    @State private var showAllKeywords = false
    @State private var results: [PhotoItem] = []
    @State private var resultTotal = 0
    @State private var hoveredKey: String?
    @State private var hoveredPhotoID: UUID?

    // 网格交互：多选、框选、触控板缩放与快捷键
    @State private var lastTappedID: UUID?
    @State private var cellMin: CGFloat = 96
    @State private var pinchStartCell: CGFloat?
    @State private var keyMonitor: Any?
    @State private var hostWindow: NSWindow?

    // 新建关键词
    @State private var keywordPromptTargets: Set<UUID> = []
    @State private var showKeywordPrompt = false
    @State private var keywordDraft = ""

    private let resultLimit = 180

    /// 当前维度由「整理工作室」侧边栏页共享，工具栏切换后页面跟着换分布面板。
    private var dimension: OrganizeDimension { store.organizeDimension }
    private var stats: OrganizeStudioStats { store.organizeStudioStats }

    /// 关键词筛选：具体标签 / 无关键词；nil 表示不筛选。
    private enum KeywordFilter: Hashable {
        case keyword(String)
        case untagged

        var title: String {
            switch self {
            case .keyword(let name): return name
            case .untagged: return "无关键词"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterStrip
            resultsHeader
            resultsGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowAccessor { window in
            if hostWindow !== window { hostWindow = window }
        })
        .overlay(alignment: .bottom) { selectionBar }
        .task(id: refreshToken) { recompute() }
        .onAppear { installKeyMonitor() }
        .onDisappear {
            removeKeyMonitor()
            selectionModel.ids.removeAll()
        }
        .animation(settings.motion.overlay, value: selectionModel.ids.isEmpty)
        .alert("新建关键词", isPresented: $showKeywordPrompt) {
            TextField("关键词", text: $keywordDraft)
            Button("添加") { commitKeywordPrompt() }
            Button("取消", role: .cancel) { keywordDraft = "" }
        } message: {
            Text(keywordPromptTargets.count > 1
                 ? "将添加到已选的 \(keywordPromptTargets.count) 张照片。"
                 : "将添加到这张照片。")
        }
    }

    // MARK: - 分布（紧凑条）

    /// 分布条压缩成一行，只占 60–90pt；照片网格拿到几乎整个窗口高度。
    /// 固定高度：切换评分 / 旗标 / 色标 / 关键词时面板高度不变，结果网格不跟着上下跳。
    private var filterStrip: some View {
        panel
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 92, alignment: .leading)
            .background(panelBackground)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private var panel: some View {
        switch dimension {
        case .rating: ratingPanel
        case .flag: flagPanel
        case .colorLabel: colorPanel
        case .keyword: keywordPanel
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
            .fill(Color.primary.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }

    private var ratingPanel: some View {
        let peak = max(1, stats.ratingCounts.max() ?? 1)
        return HStack(spacing: 6) {
            ForEach((1...5).reversed(), id: \.self) { value in
                ratingBar(value, peak: peak)
            }
            ratingBar(0, peak: peak)
        }
    }

    private func ratingBar(_ value: Int, peak: Int) -> some View {
        let count = ratingCount(value)
        let fraction = min(1, CGFloat(count) / CGFloat(peak))
        let selected = ratingPick == value
        let hovered = hoveredKey == "rating-\(value)"

        return Button {
            ratingPick = (ratingPick == value) ? nil : value
        } label: {
            VStack(spacing: 5) {
                Text(count.formatted())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(selected ? Color.primary : Color.secondary)

                GeometryReader { proxy in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(LinearGradient(colors: [LumaBrand.amber, LumaBrand.coral],
                                                 startPoint: .bottom, endPoint: .top))
                            .frame(height: max(4, proxy.size.height * fraction))
                            .opacity(selected ? 1 : (hovered ? 0.9 : 0.7))
                    }
                }
                .frame(height: 30)

                Text(value == 0 ? "未评分" : "\(value)★")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.yellow.opacity(0.12)
                          : (hovered ? Color.primary.opacity(0.05) : Color.clear))
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.42), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredKey = hovering ? "rating-\(value)" : (hoveredKey == "rating-\(value)" ? nil : hoveredKey)
        }
        .help(value == 0 ? "筛选未评分的照片" : "筛选 \(value) 星的照片")
    }

    private var flagPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach([PhotoFlag.pick, PhotoFlag.none, PhotoFlag.reject]) { flag in
                    flagPill(flag)
                }
            }
            Text("与 Lightroom / Camera Raw 一致的三态旗标；需要更细的取舍时，再叠加评分与色标。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)
        }
    }

    private func flagPill(_ flag: PhotoFlag) -> some View {
        let count = flagCount(flag)
        let selected = flagPick == flag
        let hovered = hoveredKey == "flag-\(flag.rawValue)"
        let tint: Color = flag == .none ? .secondary : flag.color

        return Button {
            flagPick = selected ? nil : flag
        } label: {
            HStack(spacing: 7) {
                Image(systemName: flag.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(flag.title)
                    .font(.system(size: 11, weight: .medium))
                Text(count.formatted())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? tint.opacity(0.13)
                          : Color.primary.opacity(hovered ? 0.06 : 0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.50) : Color.primary.opacity(0.05),
                                  lineWidth: selected ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hovered)
        .onHover { hovering in
            hoveredKey = hovering ? "flag-\(flag.rawValue)" : (hoveredKey == "flag-\(flag.rawValue)" ? nil : hoveredKey)
        }
        .help(flagHint(flag))
    }

    private func flagHint(_ flag: PhotoFlag) -> String {
        switch flag {
        case .pick: return "优先保留、准备使用"
        case .none: return "还没做过取舍"
        case .reject: return "待删除或不再需要"
        }
    }

    private var colorPanel: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(PhotoColorLabel.allCases) { label in
                    colorChip(label)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    private func colorChip(_ label: PhotoColorLabel) -> some View {
        let count = colorCount(label)
        let selected = colorPick == label
        let hovered = hoveredKey == "color-\(label.rawValue)"
        let tint: Color = label == .none ? .secondary : label.color

        return Button {
            colorPick = selected ? nil : label
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    if label == .none {
                        Circle()
                            .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.1)
                            .frame(width: 11, height: 11)
                    } else {
                        Circle()
                            .fill(label.color)
                            .frame(width: 11, height: 11)
                            .overlay {
                                Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.6)
                            }
                    }
                }

                Text(label.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(count.formatted())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? tint.opacity(0.14)
                          : Color.primary.opacity(hovered ? 0.06 : 0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.55) : Color.primary.opacity(0.05),
                                  lineWidth: selected ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hovered)
        .onHover { hovering in
            hoveredKey = hovering ? "color-\(label.rawValue)" : (hoveredKey == "color-\(label.rawValue)" ? nil : hoveredKey)
        }
        .help(label == .none ? "筛选未加色标的照片" : "筛选\(label.title)色标的照片")
    }

    // MARK: - 关键词

    private var keywordPanel: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                untaggedKeywordChip

                if !keywordOptions.isEmpty {
                    Divider()
                        .frame(height: 14)
                        .overlay(Color.primary.opacity(0.10))
                        .padding(.horizontal, 2)

                    ForEach(keywordOptions) { option in
                        keywordChip(option)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "tag")
                            .font(.system(size: 10, weight: .semibold))
                        Text("还没有关键词，可在信息面板或右键菜单里添加")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    private var untaggedKeywordChip: some View {
        let selected = keywordPick == .untagged
        let hovered = hoveredKey == "keyword-untagged"
        let tint = LumaBrand.cyan

        return Button {
            keywordPick = selected ? nil : .untagged
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag.slash")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(selected ? tint : Color.secondary.opacity(0.7))
                Text("无关键词")
                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                Text(untaggedKeywordCount.formatted())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? tint.opacity(0.16)
                          : Color.primary.opacity(hovered ? 0.06 : 0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.55) : Color.primary.opacity(0.05),
                                  lineWidth: selected ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hovered)
        .onHover { hovering in
            hoveredKey = hovering ? "keyword-untagged"
                : (hoveredKey == "keyword-untagged" ? nil : hoveredKey)
        }
        .help("筛选没有任何关键词的照片")
    }

    private func keywordChip(_ option: KeywordOption) -> some View {
        let filter = KeywordFilter.keyword(option.name)
        let selected = keywordPick == filter
        let hovered = hoveredKey == "keyword-\(option.name)"
        let tint = LumaBrand.cyan

        return Button {
            keywordPick = selected ? nil : filter
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(selected ? tint : Color.secondary.opacity(0.7))

                Text(option.name)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)

                Text(option.count.formatted())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? tint.opacity(0.16)
                          : Color.primary.opacity(hovered ? 0.06 : 0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.55) : Color.primary.opacity(0.05),
                                  lineWidth: selected ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hovered)
        .onHover { hovering in
            hoveredKey = hovering ? "keyword-\(option.name)"
                : (hoveredKey == "keyword-\(option.name)" ? nil : hoveredKey)
        }
        .help("筛选关键词「\(option.name)」下的照片")
    }

    // MARK: - 结果

    private var resultsHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(hasPick ? "\(dimension.title) · \(pickTitle)" : "最近整理")
                .font(.system(size: 13, weight: .semibold))
            Text("\(resultTotal.formatted()) 张")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            // 始终占位，筛选切换时标题区高度不变，照片网格不会上下跳。
            Button {
                clearPick()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                    Text("清除筛选")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .opacity(hasPick ? 1 : 0)
            .disabled(!hasPick)
            .help("回到全部整理结果")
        }
        .frame(height: 24)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    /// 只有照片网格滚动：顶部工具条与分布条固定，照片区域始终占满剩余高度。
    private var resultsGrid: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if results.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cellMin,
                                                               maximum: cellMin + 72),
                                                      spacing: 6)],
                                  alignment: .leading,
                                  spacing: 6) {
                            ForEach(results) { photo in
                                photoCell(photo)
                            }
                        }

                        if resultTotal > results.count {
                            Text("仅展示前 \(results.count) 张，缩小筛选范围可以看更多。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                    }
                    Color.clear.frame(height: selectionModel.ids.isEmpty ? 24 : 84)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 空白处拖动框选；从照片上按下时让位给拖拽与点选。
                .photoMarqueeSelection(fillHeight: proxy.size.height)
            }
            .simultaneousGesture(gridPinch)
        }
        .frame(maxHeight: .infinity)
    }

    /// 触控板捏合调节缩略图密度；⌘+ / ⌘- 同步支持。
    private var gridPinch: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if pinchStartCell == nil { pinchStartCell = cellMin }
                guard let start = pinchStartCell else { return }
                cellMin = min(190, max(72, start * value.magnification))
            }
            .onEnded { _ in pinchStartCell = nil }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: hasPick ? "line.3.horizontal.decrease.circle" : dimension.icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(hasPick ? Color.secondary : Color.yellow)
                Text(hasPick ? "没有匹配的照片" : "还没有整理过的照片")
                    .font(.system(size: 13, weight: .semibold))
            }
            if !hasPick {
                Text("评分、旗标、色标与关键词会自动汇总到这里。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    hintRow("1", "在照片网格里右键任意照片，选择「评分 / 旗标 / 色标」。")
                    hintRow("2", "或在查看器的信息面板「整理」区块里逐项设置。")
                    hintRow("3", "设置完成后回到这里，分布与结果会实时更新。")
                }
            } else {
                Text(dimension == .keyword ? "换一个关键词试试。" : "换一个星级、旗标或颜色试试。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground)
    }

    private func hintRow(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func photoCell(_ photo: PhotoItem) -> some View {
        let hovered = hoveredPhotoID == photo.id
        let selected = selectionModel.ids.contains(photo.id)
        let cell = ZStack(alignment: .bottomLeading) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PhotoThumbnailView(photo: photo, purpose: .cover(360))
                }

            LinearGradient(colors: [.clear, .black.opacity(0.46)],
                           startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)

            metadataBadges(photo)
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: selected ? 2 : 0.5)
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(6)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
        }
        .scaleEffect(hovered && settings.hoverLift ? settings.motion.hoverScale : 1)
        .shadow(color: .black.opacity(hovered ? 0.18 : 0), radius: 12, y: 5)
        .animation(settings.motion.hover, value: hovered)
        .animation(settings.motion.hover, value: selected)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        // 单元格位置：供空白处拖动框选命中。
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: PhotoFramePreferenceKey.self,
                    value: [photo.id: geo.frame(in: .named(PhotoMarqueeSpace.name))]
                )
            }
        }
        .photoClickActions(
            single: {
                handlePhotoTap(photo)
            },
            double: {
                store.openViewer(photo.id)
            }
        )
        .onHover { hovering in
            hoveredPhotoID = hovering ? photo.id : (hoveredPhotoID == photo.id ? nil : hoveredPhotoID)
        }
        .help("\(photo.displayTitle)\n单击选择 · 双击打开 · ⌘/⇧ 多选 · 空白处拖动框选")

        if store.canEditMetadataWorkflow {
            cell.contextMenu {
                let targets = contextTargets(for: photo)
                if targets.count > 1 {
                    Text("已选 \(targets.count) 张，以下操作会应用到全部")
                }
                Menu("评分") {
                    ForEach((0...5).reversed(), id: \.self) { value in
                        Button(value == 0 ? "清除评分" : "\(value) 星") {
                            store.setRating(value, ids: targets)
                        }
                    }
                }
                Menu("旗标") {
                    ForEach(PhotoFlag.allCases) { flag in
                        Button(flag.title) { store.setFlag(flag, ids: targets) }
                    }
                }
                Menu("色标") {
                    ForEach(PhotoColorLabel.allCases) { label in
                        Button(label.title) { store.setColorLabel(label, ids: targets) }
                    }
                }
                keywordMenu(targets: targets)
                Divider()
                Button("在查看器中打开") { store.openViewer(photo.id) }
            }
        } else {
            cell
        }
    }

    /// 右键作用于当前多选；点在未选中的照片上时只作用于这一张。
    private func contextTargets(for photo: PhotoItem) -> Set<UUID> {
        if selectionModel.ids.contains(photo.id), selectionModel.ids.count > 1 {
            return selectionModel.ids
        }
        return [photo.id]
    }

    /// 右键菜单里的关键词：添加已有标签、移除、或直接新建。
    @ViewBuilder
    private func keywordMenu(targets: Set<UUID>) -> some View {
        let options = store.keywordOptions
        let targetPhotos = results.filter { targets.contains($0.id) }
        let presentKeywords = Set(targetPhotos.flatMap(\.tags))

        Menu("关键词") {
            Button("新建关键词…") { presentKeywordPrompt(for: targets) }

            if !options.isEmpty {
                Divider()
                let addable = options.filter { option in
                    targetPhotos.contains { !$0.tags.contains(option.name) }
                }
                if !addable.isEmpty {
                    Menu("添加已有关键词") {
                        ForEach(addable.prefix(30)) { option in
                            Button(option.name) {
                                store.addKeyword(option.name, to: targets)
                            }
                        }
                    }
                }

                if !presentKeywords.isEmpty {
                    Divider()
                    Menu("移除关键词") {
                        ForEach(options.filter { presentKeywords.contains($0.name) }.prefix(30)) { option in
                            Button("移除「\(option.name)」") {
                                store.removeKeyword(option.name, from: targets)
                            }
                        }
                    }
                }
            }
        }
    }

    private func presentKeywordPrompt(for targets: Set<UUID>) {
        keywordPromptTargets = targets
        keywordDraft = ""
        showKeywordPrompt = true
    }

    private func commitKeywordPrompt() {
        let name = keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !keywordPromptTargets.isEmpty else { return }
        store.addKeyword(name, to: keywordPromptTargets)
        keywordDraft = ""
        keywordPromptTargets = []
    }

    private func metadataBadges(_ photo: PhotoItem) -> some View {
        HStack(spacing: 4) {
            if photo.starRating > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7.5, weight: .semibold))
                    Text("\(photo.starRating)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(Color.black.opacity(0.36), in: Capsule())
            }

            if photo.pickFlag != .none {
                Image(systemName: photo.pickFlag.icon)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(3.5)
                    .background(photo.pickFlag.color.opacity(0.85), in: Circle())
            }

            if photo.labelColor != .none {
                Circle()
                    .fill(photo.labelColor.color)
                    .frame(width: 7, height: 7)
                    .padding(3.5)
                    .background(Color.black.opacity(0.36), in: Capsule())
            }

            if !photo.tags.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 7.5, weight: .semibold))
                    Text("\(photo.tags.count)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(Color.black.opacity(0.36), in: Capsule())
            }
        }
    }

    // MARK: - 选择与批量操作

    private var selectedIDs: Set<UUID> { selectionModel.ids }

    /// 与照片网格一致：单击选择，⌘ 切换，⇧ 连续选择，双击打开。
    private func handlePhotoTap(_ photo: PhotoItem) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var ids = selectionModel.ids

        if flags.contains(.command) {
            if ids.contains(photo.id) {
                ids.remove(photo.id)
            } else {
                ids.insert(photo.id)
            }
        } else if flags.contains(.shift),
                  let anchor = lastTappedID,
                  let start = results.firstIndex(where: { $0.id == anchor }),
                  let end = results.firstIndex(where: { $0.id == photo.id }) {
            let range = start <= end ? start...end : end...start
            ids.formUnion(results[range].map(\.id))
        } else {
            ids = [photo.id]
        }

        selectionModel.ids = ids
        lastTappedID = photo.id
    }

    @ViewBuilder
    private var selectionBar: some View {
        if !selectedIDs.isEmpty {
            HStack(spacing: 10) {
                Text("已选 \(selectedIDs.count) 张")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()

                Divider().frame(height: 16)

                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { value in
                        Button {
                            store.setRating(value, ids: selectedIDs)
                        } label: {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.yellow.opacity(0.9))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("给所选照片评 \(value) 星")
                    }
                }

                Divider().frame(height: 16)

                HStack(spacing: 3) {
                    flagButton(.pick, icon: "flag.fill", color: .green, help: "留用 (P)")
                    flagButton(.none, icon: "flag", color: .secondary, help: "清除旗标 (U)")
                    flagButton(.reject, icon: "xmark.circle.fill", color: .red, help: "排除 (X)")
                }

                Divider().frame(height: 16)

                HStack(spacing: 4) {
                    ForEach(PhotoColorLabel.allCases.filter { $0 != .none }) { label in
                        Button {
                            store.setColorLabel(label, ids: selectedIDs)
                        } label: {
                            Circle()
                                .fill(label.color)
                                .frame(width: 11, height: 11)
                                .overlay {
                                    Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.6)
                                }
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("标记为\(label.title)")
                    }
                }

                Divider().frame(height: 16)
                Menu {
                    Button("新建关键词…") { presentKeywordPrompt(for: selectedIDs) }
                    if !keywordOptions.isEmpty {
                        Divider()
                        ForEach(keywordOptions.prefix(24)) { option in
                            Button(option.name) {
                                store.addKeyword(option.name, to: selectedIDs)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tag")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("关键词")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("给所选照片添加或新建关键词")

                Spacer(minLength: 6)

                Button {
                    if let id = openCandidateID {
                        store.openViewer(id)
                    }
                } label: {
                    Text("打开")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(openCandidateID == nil)

                Button {
                    withAnimation(settings.motion.overlay) { selectionModel.ids.removeAll() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("取消选择 (Esc)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func flagButton(_ flag: PhotoFlag, icon: String, color: Color, help: String) -> some View {
        Button {
            store.setFlag(flag, ids: selectedIDs)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var openCandidateID: UUID? {
        results.first(where: { selectedIDs.contains($0.id) })?.id ?? results.first?.id
    }

    // MARK: - 快捷键

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private var isEditingText: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        return responder is NSTextView || responder is NSTextField
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = hostWindow ?? event.window else { return false }
        guard event.window === window else { return false }
        guard window.attachedSheet == nil else { return false }
        guard store.viewerID == nil, store.editorID == nil, !store.showSlideshow,
              store.activeMemory == nil, store.activeTrip == nil,
              !store.hasPendingConfirmation else { return false }
        guard !isEditingText else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags.contains(.command) {
            switch chars {
            case "a":
                guard !results.isEmpty else { return false }
                withAnimation(settings.motion.overlay) {
                    selectionModel.ids = Set(results.map(\.id))
                }
                return true
            case "1":
                setDimension(.rating)
                return true
            case "2":
                setDimension(.flag)
                return true
            case "3":
                setDimension(.colorLabel)
                return true
            case "4":
                setDimension(.keyword)
                return true
            case "=", "+":
                withAnimation(settings.motion.layout) { cellMin = min(190, cellMin * 1.15) }
                return true
            case "-", "_":
                withAnimation(settings.motion.layout) { cellMin = max(72, cellMin / 1.15) }
                return true
            default:
                return false
            }
        }

        // Esc：先取消选择，再清除筛选。
        if event.keyCode == 53 {
            if !selectedIDs.isEmpty {
                withAnimation(settings.motion.overlay) { selectionModel.ids.removeAll() }
                return true
            }
            if hasPick {
                clearPick()
                return true
            }
            return false
        }

        // 空格 / 回车：打开所选（或第一张）照片。
        if event.keyCode == 49 || event.keyCode == 36 {
            guard let id = openCandidateID else { return false }
            store.openViewer(id)
            return true
        }

        // ← / →：在结果里移动单选。
        if event.keyCode == 123 || event.keyCode == 124 {
            return moveSelection(by: event.keyCode == 123 ? -1 : 1)
        }

        guard !selectedIDs.isEmpty, !flags.contains(.option), !flags.contains(.control) else {
            return false
        }

        switch chars {
        case "0", "1", "2", "3", "4", "5":
            if let value = Int(chars) {
                store.setRating(value, ids: selectedIDs)
                return true
            }
        case "p":
            store.setFlag(.pick, ids: selectedIDs)
            return true
        case "x":
            store.setFlag(.reject, ids: selectedIDs)
            return true
        case "u":
            store.setFlag(.none, ids: selectedIDs)
            return true
        case "6":
            store.setColorLabel(.red, ids: selectedIDs)
            return true
        case "7":
            store.setColorLabel(.yellow, ids: selectedIDs)
            return true
        case "8":
            store.setColorLabel(.green, ids: selectedIDs)
            return true
        case "9":
            store.setColorLabel(.blue, ids: selectedIDs)
            return true
        default:
            return false
        }
        return false
    }

    private func setDimension(_ value: OrganizeDimension) {
        store.organizeDimension = value
        selectionModel.ids.removeAll()
    }

    private func moveSelection(by delta: Int) -> Bool {
        guard !results.isEmpty else { return false }
        let current = results.firstIndex { selectedIDs.contains($0.id) }
            ?? (delta > 0 ? -1 : results.count)
        let next = min(results.count - 1, max(0, current + delta))
        withAnimation(settings.motion.hover) {
            selectionModel.ids = [results[next].id]
        }
        lastTappedID = results[next].id
        return true
    }

    // MARK: - 取数

    private var refreshToken: String {
        [
            String(store.contentRevision),
            store.isCloudScope
                ? "cloud#\(store.cloudModel.revision)#\(store.cloudModel.metadataRevision)"
                : (store.isSystemScope ? "system" : "local"),
            dimension.rawValue,
            ratingPick.map(String.init) ?? "-",
            flagPick?.rawValue ?? "-",
            colorPick?.rawValue ?? "-",
            keywordPick?.title ?? "-"
        ].joined(separator: "|")
    }

    private var libraryTotal: Int {
        if store.isCloudScope {
            return store.cloudPhotos.filter { !$0.isHidden }.count
        }
        if store.isSystemScope {
            if store.systemTotalAssetCount > 0 { return store.systemTotalAssetCount }
            return store.systemPhotos.isEmpty ? store.systemWindowTotal : store.systemPhotos.count
        }
        return store.totalLibraryCount
    }

    private var hasPick: Bool {
        switch dimension {
        case .rating: return ratingPick != nil
        case .flag: return flagPick != nil
        case .colorLabel: return colorPick != nil
        case .keyword: return keywordPick != nil
        }
    }

    private var pickTitle: String {
        switch dimension {
        case .rating:
            guard let ratingPick else { return "全部" }
            return ratingPick == 0 ? "未评分" : "\(ratingPick) 星"
        case .flag:
            return flagPick?.title ?? "全部"
        case .colorLabel:
            return colorPick?.title ?? "全部"
        case .keyword:
            return keywordPick?.title ?? "全部"
        }
    }

    private func clearPick() {
        ratingPick = nil
        flagPick = nil
        colorPick = nil
        keywordPick = nil
    }

    private func ratingCount(_ value: Int) -> Int {
        if value > 0 { return stats.ratingCounts[value] }
        if store.isSystemScope {
            return max(0, libraryTotal - stats.rated)
        }
        return stats.ratingCounts[0]
    }

    private func flagCount(_ flag: PhotoFlag) -> Int {
        switch flag {
        case .pick: return stats.pick
        case .reject: return stats.reject
        case .none:
            if store.isSystemScope {
                return max(0, libraryTotal - stats.flagged)
            }
            return stats.unflagged
        }
    }

    private func colorCount(_ label: PhotoColorLabel) -> Int {
        if label == .none {
            if store.isSystemScope {
                return max(0, libraryTotal - stats.labeled)
            }
            return max(0, stats.total - stats.labeled)
        }
        return stats.colorCounts[label.rawValue] ?? 0
    }

    private func recompute() {
        var next = OrganizeStudioStats()
        var collected: [PhotoItem] = []
        var total = 0
        let system = store.isSystemScope
        let keywordMode = dimension == .keyword

        if system {
            for overlay in store.systemOverlays.values {
                guard overlay.isHidden != true else { continue }
                accumulate(overlay, into: &next)
            }

            if !keywordMode || keywordPick == nil {
                let matchingIDs = store.systemOverlays.compactMap { id, overlay -> UUID? in
                    guard overlay.isHidden != true else { return nil }
                    let hit = hasPick ? matches(overlay) : overlayHasMetadata(overlay)
                    return hit ? id : nil
                }
                total = matchingIDs.count

                for id in matchingIDs {
                    guard collected.count < resultLimit else { break }
                    if let photo = store.systemPhoto(id: id),
                       photo.deletedAt == nil, !photo.isHidden {
                        collected.append(photo)
                    }
                }
            }
        } else {
            // 网盘与本地图库共用同一套统计：网盘用当前目录的照片，标记只在本机。
            let pool = store.isCloudScope
                ? store.cloudPhotos.filter { !$0.isHidden }
                : store.photos.filter { $0.deletedAt == nil && !$0.isHidden }
            for photo in pool {
                next.total += 1

                let rating = photo.starRating
                next.ratingCounts[rating] += 1
                if rating > 0 { next.rated += 1 }

                switch photo.pickFlag {
                case .pick: next.pick += 1
                case .reject: next.reject += 1
                case .none: next.unflagged += 1
                }
                if photo.pickFlag != .none { next.flagged += 1 }

                let label = photo.labelColor
                next.colorCounts[label.rawValue, default: 0] += 1
                if label != .none { next.labeled += 1 }
                if !photo.tags.isEmpty { next.keyworded += 1 }

                if !keywordMode || keywordPick == nil {
                    let hit = hasPick ? matches(photo) : photoHasMetadata(photo)
                    if hit {
                        total += 1
                        if collected.count < resultLimit { collected.append(photo) }
                    }
                }
            }
        }

        if keywordMode {
            keywordOptions = store.keywordOptions.sorted {
                $0.count != $1.count
                    ? $0.count > $1.count
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

            if system {
                // 官方关键词与拾光补充关键词合并后的照片集合，用于算「无关键词」。
                var tagged = Set<UUID>()
                for (id, tags) in store.systemNativeKeywordIDMap where !tags.isEmpty {
                    tagged.insert(id)
                }
                for (id, overlay) in store.systemOverlays where !(overlay.keywords?.isEmpty ?? true) {
                    tagged.insert(id)
                }
                untaggedKeywordCount = max(0, libraryTotal - tagged.count)

                if let keywordPick {
                    switch keywordPick {
                    case .keyword(let name):
                        let matched = store.keywordPhotos(name)
                            .filter { $0.deletedAt == nil && !$0.isHidden }
                        total = matched.count
                        collected = Array(matched.prefix(resultLimit))
                    case .untagged:
                        let pool = store.systemPhotos.isEmpty ? store.systemWindowPhotos : store.systemPhotos
                        for photo in pool
                        where photo.deletedAt == nil && !photo.isHidden && !tagged.contains(photo.id) {
                            guard collected.count < resultLimit else { break }
                            collected.append(photo)
                        }
                        total = untaggedKeywordCount
                    }
                }
            } else {
                untaggedKeywordCount = max(0, next.total - next.keyworded)

                if let keywordPick {
                    switch keywordPick {
                    case .keyword(let name):
                        let matched = store.keywordPhotos(name)
                            .filter { $0.deletedAt == nil && !$0.isHidden }
                        total = matched.count
                        collected = Array(matched.prefix(resultLimit))
                    case .untagged:
                        var count = 0
                        let untaggedPool = store.isCloudScope
                            ? store.cloudPhotos.filter { !$0.isHidden }
                            : store.photos.filter { $0.deletedAt == nil && !$0.isHidden }
                        for photo in untaggedPool where photo.tags.isEmpty {
                            count += 1
                            if collected.count < resultLimit { collected.append(photo) }
                        }
                        total = count
                    }
                }
            }
        } else {
            keywordOptions = []
            untaggedKeywordCount = 0
        }

        if store.organizeStudioStats != next {
            store.organizeStudioStats = next
        }
        resultTotal = total
        results = collected.sorted { $0.capturedAt > $1.capturedAt }

        // 结果变化后，选区里已经不存在的照片一并清掉。
        if !selectionModel.ids.isEmpty {
            let visible = Set(results.map(\.id))
            if !visible.isSuperset(of: selectionModel.ids) {
                selectionModel.ids.formIntersection(visible)
            }
        }
    }

    private func accumulate(_ overlay: MetadataStore.AssetOverlay, into next: inout OrganizeStudioStats) {
        let rating = min(5, max(0, overlay.rating ?? 0))
        next.ratingCounts[rating] += 1
        if rating > 0 { next.rated += 1 }

        switch overlay.flag ?? .none {
        case .pick: next.pick += 1
        case .reject: next.reject += 1
        case .none: next.unflagged += 1
        }
        if (overlay.flag ?? .none) != .none { next.flagged += 1 }

        let label = overlay.colorLabel ?? .none
        next.colorCounts[label.rawValue, default: 0] += 1
        if label != .none { next.labeled += 1 }
    }

    private func matches(_ photo: PhotoItem) -> Bool {
        switch dimension {
        case .rating:
            guard let ratingPick else { return false }
            return photo.starRating == ratingPick
        case .flag:
            guard let flagPick else { return false }
            return photo.pickFlag == flagPick
        case .colorLabel:
            guard let colorPick else { return false }
            return photo.labelColor == colorPick
        case .keyword:
            guard let keywordPick else { return false }
            switch keywordPick {
            case .keyword(let name): return photo.tags.contains(name)
            case .untagged: return photo.tags.isEmpty
            }
        }
    }

    private func matches(_ overlay: MetadataStore.AssetOverlay) -> Bool {
        switch dimension {
        case .rating:
            guard let ratingPick else { return false }
            return min(5, max(0, overlay.rating ?? 0)) == ratingPick
        case .flag:
            guard let flagPick else { return false }
            return (overlay.flag ?? .none) == flagPick
        case .colorLabel:
            guard let colorPick else { return false }
            return (overlay.colorLabel ?? .none) == colorPick
        case .keyword:
            guard let keywordPick else { return false }
            switch keywordPick {
            case .keyword(let name): return overlay.keywords?.contains(name) ?? false
            case .untagged: return (overlay.keywords?.isEmpty ?? true)
            }
        }
    }

    private func photoHasMetadata(_ photo: PhotoItem) -> Bool {
        photo.starRating > 0
            || photo.pickFlag != .none
            || photo.labelColor != .none
            || !photo.tags.isEmpty
    }

    private func overlayHasMetadata(_ overlay: MetadataStore.AssetOverlay) -> Bool {
        (overlay.rating ?? 0) > 0
            || (overlay.flag ?? .none) != .none
            || (overlay.colorLabel ?? .none) != .none
            || !(overlay.keywords?.isEmpty ?? true)
    }
}
