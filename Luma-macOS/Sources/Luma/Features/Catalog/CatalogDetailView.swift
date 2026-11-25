import AppKit
import SwiftUI
import LumaContentCore

/// 资源详情：剧集是第一信息，进入后直接能选某一集播放。
///
/// 版式参考流媒体的「详情页」：封面模糊成背景，前景是海报 + 标题 + 主操作，
/// 下方是分集选集区；长剧按每 50 集分段，避免一屏铺开几百个数字。
struct CatalogDetailView: View {
    let item: CatalogItem
    /// 非空表示嵌在频道页里显示（不再弹窗）：点返回就回到频道列表。
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var catalog: CatalogBrowserModel
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private var isEmbedded: Bool { onClose != nil }

    /// 每段展示多少集。
    @State private var rangeIndex = 0
    @State private var didAlignRange = false
    /// 图集大图预览的当前序号。
    @State private var previewIndex: Int?
    /// 新建片单：先让用户取名，再创建并加入当前作品。
    @State private var showsNewPlaylistPrompt = false
    @State private var newPlaylistName = ""
    /// 封面主色：详情页底图会带一点作品本身的色调。
    @State private var heroTint: Color?
    /// 点详情里的女优 / 片商名字：打开跨源档案。
    /// 状态放在模型里：工具栏返回按钮要先退回详情页。
    private var personTarget: CatalogDetailPersonTarget? { catalog.detailPersonTarget }

    private func openPerson(_ name: String, role: String) {
        catalog.detailPersonTarget = CatalogDetailPersonTarget(name: name, role: role)
    }

    private func closePerson() {
        withAnimation(.easeOut(duration: 0.18)) {
            catalog.detailPersonTarget = nil
        }
    }

    private static let rangeSize = 50
    /// 滚动到正文的锚点。
    private static let articleAnchor = "catalog-article"
    private static let factsAnchor = "catalog-facts"
    private static let episodeAnchor = "catalog-episodes"

    private var source: CatalogSource? { catalog.selectedSource }
    private var progress: CatalogProgress? {
        guard let source else { return nil }
        return catalog.progress(sourceID: source.id, itemID: item.id)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LumaAmbientBackground(intensity: 0.9)

            Group {
                if let detail = catalog.detail {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                hero(detail) {
                                    withAnimation(.easeInOut(duration: 0.32)) {
                                        proxy.scrollTo(Self.articleAnchor, anchor: .top)
                                    }
                                }
                                chapterBar(proxy: proxy, detail: detail)
                                    .padding(.top, -8)
                                // 女优 / 片商已经由下面的「人物与机构」统一展示，
                                // 详情里不再重复铺一遍同样的名字。
                                if !infoFacts(detail).isEmpty {
                                    factsSection(detail)
                                        .id(Self.factsAnchor)
                                }
                                let people = personMatches(detail)
                                if !people.isEmpty {
                                    peopleSection(people,
                                                  code: CatalogNameParser.parse(title: detail.item.title).code)
                                }
                                if detail.isCollection, !detail.episodes.isEmpty {
                                    collectionSection(detail)
                                        .id(Self.episodeAnchor)
                                } else if !detail.episodes.isEmpty {
                                    episodeSection(detail)
                                        .id(Self.episodeAnchor)
                                }
                                if hasArticleBody(detail) {
                                    articleSection(detail)
                                        .id(Self.articleAnchor)
                                }
                                if detail.episodes.isEmpty, !detail.hasArticle {
                                    emptyContentNote
                                }
                            }
                            .padding(.bottom, 44)
                        }
                        .scrollIndicators(.automatic)
                    }
                } else if let error = catalog.detailError {
                    errorState(error)
                } else {
                    loadingState
                }
            }

            if !isEmbedded {
                closeButton
                    .padding(18)
            }

            if let detail = catalog.detail, let index = previewIndex,
               detail.articleImages.indices.contains(index) {
                galleryPreview(detail.articleImages, index: index)
            }
        }
        // 女优 / 片商档案不再弹窗：直接盖在详情上；返回统一走窗口工具栏最左侧。
        .overlay {
            if let target = personTarget, let source {
                CatalogPersonProfileView(name: target.name,
                                         role: target.role,
                                         sourceID: source.id,
                                         onClose: closePerson,
                                         backTitle: "返回详情",
                                         showsInlineBack: false)
                    .environmentObject(catalog)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: personTarget?.id)
        .frame(width: isEmbedded ? nil : 980, height: isEmbedded ? nil : 800)
        .onAppear {
            catalog.loadDetail(item: item)
            // 详情可能来自缓存，此时 onChange 不会触发，这里补一次定位。
            alignRangeToProgress()
        }
        .onChange(of: catalog.detail?.item.id) { _, _ in
            alignRangeToProgress()
        }
        // 离开详情时把叠加的档案一起收起，下次打开别的条目不会残留上一页。
        .onDisappear {
            catalog.detailPersonTarget = nil
        }
        .alert("新建片单", isPresented: $showsNewPlaylistPrompt) {
            TextField("片单名称", text: $newPlaylistName)
            Button("创建并加入") { createPlaylistAndAdd() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("给新片单取个名字，创建后会把当前作品加进去。")
        }
    }

    /// 按用户输入的名字创建片单，并把当前作品加进去。
    private func createPlaylistAndAdd() {
        guard let source else { return }
        let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "片单 \(catalog.playlists.count + 1)" : trimmed
        let id = catalog.createPlaylist(name: name)
        catalog.addToPlaylist(id, source: source, item: item)
        newPlaylistName = ""
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.32), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .help("关闭")
        .accessibilityLabel("关闭")
    }

    // MARK: - 头部

    private func hero(_ detail: CatalogDetail,
                      onReadArticle: @escaping () -> Void) -> some View {
        // 用 background 铺模糊封面：内容尺寸完全由海报与文字决定，
        // 不会被无限伸展的背景撑高、把正文挤出可视区域。
        HStack(alignment: .bottom, spacing: 22) {
            if showsPoster {
                poster(detail)
            }
            info(detail, onReadArticle: onReadArticle)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { backdrop(detail) }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.24), radius: 22, y: 10)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    /// 章节导航：长剧集和长文不用一路滚，像翻目录一样跳过去。
    private func chapterBar(proxy: ScrollViewProxy, detail: CatalogDetail) -> some View {
        let blocks = articleBlocks(detail)
        let articleCount = detail.articleImages.isEmpty
            ? blocks.filter { $0.kind == .paragraph }.count
            : detail.articleImages.count
        return HStack(spacing: 8) {
            if !infoFacts(detail).isEmpty {
                chapterButton("详情", symbol: "list.bullet.rectangle",
                              count: infoFacts(detail).count) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(Self.factsAnchor, anchor: .top)
                    }
                }
            }
            if !detail.episodes.isEmpty {
                chapterButton(detail.isCollection ? "合集" : "选集",
                              symbol: "rectangle.stack",
                              count: detail.episodes.count) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(Self.episodeAnchor, anchor: .top)
                    }
                }
            }
            if hasArticleBody(detail) {
                chapterButton("正文", symbol: "text.alignleft", count: articleCount) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(Self.articleAnchor, anchor: .top)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
    }

    private func chapterButton(_ title: String, symbol: String, count: Int,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
    }

    /// 横版封面（网页源）没有再摆一张竖海报的必要：模糊底图已经是封面本身。
    private var showsPoster: Bool {
        (source?.posterRatio ?? 2.0 / 3.0) <= 1.2
    }

    /// 模糊封面 + 暗色渐变：只做底，不参与布局；文字始终落在深色底上。
    /// 再叠一层从封面提取的主色，让每部作品的详情页都有自己的氛围。
    private func backdrop(_ detail: CatalogDetail) -> some View {
        ZStack {
            if let source {
                CatalogArtworkImage(source: source, urlString: coverURL(detail), cornerRadius: 0,
                                    quality: .full)
                    .scaleEffect(1.08)
                    .blur(radius: 30)
            }
            if let heroTint {
                LinearGradient(colors: [heroTint.opacity(0.55),
                                        heroTint.opacity(0.20),
                                        .black.opacity(0.72),
                                        .black.opacity(0.86)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                LinearGradient(colors: [.black.opacity(0.52),
                                        .black.opacity(0.66),
                                        .black.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
        .task(id: coverURL(detail)) {
            guard let source else { return }
            heroTint = await CatalogPalette.color(source: source, urlString: coverURL(detail))
        }
    }

    private func poster(_ detail: CatalogDetail) -> some View {
        Group {
            if let source {
                CatalogArtworkImage(source: source, urlString: coverURL(detail), cornerRadius: 14,
                                    quality: .full)
                    .frame(width: 158, height: 237)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.24), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                    .contextMenu {
                        Button {
                            saveArticleImage(coverURL(detail))
                        } label: {
                            Label("保存封面到图库", systemImage: "square.and.arrow.down")
                        }
                    }
            }
        }
    }

    private func info(_ detail: CatalogDetail,
                      onReadArticle: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(displayTitle(detail))
                .font(.system(size: 27, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 2)

            HStack(spacing: 7) {
                if detail.isCollection {
                    metaChip("合集 · \(detail.collectionTotal ?? detail.episodes.count) 部")
                } else if detail.episodes.isEmpty, detail.hasArticle {
                    metaChip("图文 · \(detail.articleImages.count) 张图")
                } else {
                    metaChip("共 \(detail.episodes.count) 集")
                }
                if !item.remark.isEmpty, !detail.isCollection {
                    metaChip(item.remark)
                }
                if let source {
                    metaChip(source.host, monospaced: true)
                }
            }

            // 一段「引子」：有正文时先把故事的第一句摆出来，详情页不再是干巴巴的字段。
            // 正文只有这一段的条目（常见于纯介绍页）直接在这里展开，下面不再重复一遍。
            if let lead = heroLead(detail) {
                Text(lead)
                    .font(.system(size: 11.5))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(hasArticleBody(detail) ? 2 : 8)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress {
                progressRow(progress, detail: detail)
            }

            Spacer(minLength: 6)

            HStack(spacing: 10) {
                if detail.episodes.isEmpty {
                    Button(action: onReadArticle) {
                        HStack(spacing: 7) {
                            Image(systemName: "text.below.photo")
                                .font(.system(size: 11, weight: .bold))
                            Text(hasArticleBody(detail) ? "阅读全文" : "暂无正文")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.black.opacity(0.86))
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(.white.opacity(hasArticleBody(detail) ? 1 : 0.55),
                                    in: Capsule(style: .continuous))
                        .shadow(color: .black.opacity(hasArticleBody(detail) ? 0.35 : 0),
                                radius: 14, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasArticleBody(detail))
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        play(resumeEpisode(detail), detail: detail)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(resumeTitle(detail))
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.black.opacity(0.86))
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(.white, in: Capsule(style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }

                heroButton(isFavorite ? "已在稍后看" : "稍后看",
                           icon: isFavorite ? "bookmark.fill" : "bookmark",
                           active: isFavorite) {
                    toggleFavorite(detail)
                }

                // 视频条目也可能带图文介绍：单独给一个入口，不用滚到底才知道。
                if !detail.episodes.isEmpty, hasArticleBody(detail) {
                    heroButton("读正文", icon: "text.alignleft", active: false) {
                        onReadArticle()
                    }
                }

                // 跨源片单：直接在这里把当前作品收进任意一份片单。
                Menu {
                    ForEach(catalog.playlists) { playlist in
                        Button {
                            guard let source else { return }
                            catalog.addToPlaylist(playlist.id, source: source, item: detail.item)
                        } label: {
                            if let source,
                               catalog.isInPlaylist(playlist.id, sourceID: source.id,
                                                    itemID: detail.item.id) {
                                Label(playlist.name, systemImage: "checkmark")
                            } else {
                                Text(playlist.name)
                            }
                        }
                    }
                    if !catalog.playlists.isEmpty { Divider() }
                    Button("新建片单并加入…") {
                        guard source != nil else { return }
                        newPlaylistName = "片单 \(catalog.playlists.count + 1)"
                        showsNewPlaylistPrompt = true
                    }
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 34)
                .help("加入片单")

                heroIconButton("arrow.up.right.square") {
                    guard let source, let url = URL(string: source.baseURL) else { return }
                    NSWorkspace.shared.open(url)
                }
                .help("打开源页面")

                heroIconButton("arrow.clockwise") {
                    catalog.loadDetail(item: item, force: true)
                }
                .help("重新解析分集")

                if catalog.isLoadingDetail {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressRow(_ progress: CatalogProgress, detail: CatalogDetail) -> some View {
        let label: String = {
            if let name = detail.episodes.first(where: { $0.index == progress.episode })?.name,
               !name.isEmpty {
                return name
            }
            return detail.isCollection ? "第 \(progress.episode) 部" : "第 \(progress.episode) 集"
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("上次看到：\(label) · \(catalogTimeText(progress.seconds))")
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.82))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(LumaBrand.amber)
                        .frame(width: max(2, proxy.size.width * progress.fraction))
                }
            }
            .frame(width: 190, height: 3)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.6)
        }
    }

    private func metaChip(_ text: String, monospaced: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium,
                          design: monospaced ? .monospaced : .default))
            .foregroundStyle(.white.opacity(0.86))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.white.opacity(0.14), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
    }

    private func heroButton(_ title: String, icon: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(active ? LumaBrand.amber : .white.opacity(0.92))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.white.opacity(active ? 0.18 : 0.12), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(active ? LumaBrand.amber.opacity(0.55) : .white.opacity(0.14),
                                  lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
    }

    private func heroIconButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 详情信息

    /// 哪些字段可以点进人物档案。
    private func personRole(for label: String) -> String? {
        let lower = label.lowercased()
        if lower.contains("女优") || lower.contains("女優") || lower.contains("演员")
            || lower.contains("演員") || lower.contains("actress") || lower.contains("cast") {
            return "女优"
        }
        if lower.contains("片商") || lower.contains("厂商") || lower.contains("廠商")
            || lower.contains("出品") || lower.contains("制作") || lower.contains("製作")
            || lower.contains("studio") || lower.contains("maker") || lower.contains("メーカー") {
            return "片商"
        }
        if lower.contains("模特") || lower.contains("model") || lower.contains("福利姬")
            || lower.contains("秀人") {
            return "模特"
        }
        return nil
    }

    /// 一个字段里可能有多个名字（「甲、乙」），拆开各自成按钮。
    private func personNames(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: "、,，/|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 30 }
    }

    // MARK: - 人物与机构（资料库匹配）

    /// 一条匹配结果：资料库命中时带完整档案，没命中就只保留名字与入口。
    private struct PersonMatch: Identifiable {
        var name: String
        var role: String
        /// 模糊命中的原始写法（与库里的标准名不同时才显示）。
        var matchedFrom: String?
        var info: CatalogPersonInfo?
        /// 资料库标签：单独做成可点击的彩色胶囊，点一下看跨源聚合。
        var tags: [String] = []
        var id: String

        var hasRecord: Bool { info != nil }
    }

    /// 把标题、详情字段和正文合并成一段文本，统一做资料库模糊匹配：
    /// 站点写「冲宫奈美」、库里叫「沖宮奈々美」也能落到同一条记录。
    private func personMatches(_ detail: CatalogDetail) -> [PersonMatch] {
        var results: [PersonMatch] = []
        var seen = Set<String>()

        func add(_ raw: String, role: String) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2 else { return }
            let isStudio = role == "片商"
            let actress = isStudio ? nil : CatalogNameDictionary.actress(matching: name)
            let studio = isStudio ? CatalogNameDictionary.studio(matching: name) : nil

            let key: String
            if let actress {
                key = "actress-\(actress.id)"
            } else if let studio {
                key = "studio-\(studio.id)"
            } else {
                key = "name-\(role)-\(CatalogNameParser.normalize(name))"
            }
            guard seen.insert(key).inserted else { return }

            let effectiveRole = actress?.isModel == true ? "模特" : role
            let info = (actress != nil || studio != nil)
                ? CatalogPersonInfoService.shared.cached(name: name, role: effectiveRole)?.info
                : nil
            let canonical = info?.name ?? name
            let matchedFrom = CatalogNameParser.normalize(canonical)
                == CatalogNameParser.normalize(name) ? nil : name
            results.append(PersonMatch(name: canonical,
                                       role: effectiveRole,
                                       matchedFrom: matchedFrom,
                                       info: info,
                                       tags: Array((actress?.tags ?? []).prefix(8)),
                                       id: key))
        }

        // 1. 详情字段里明确标了「女优 / 片商」的，最先采用。
        for fact in detail.facts {
            guard let role = personRole(for: fact.label) else { continue }
            for name in personNames(fact.value) {
                add(name, role: role)
            }
        }

        // 2. 标题不给字段时，把详情字段值与正文一起再识别一遍。
        var haystack = detail.item.title
        for fact in detail.facts { haystack += "\n\(fact.value)" }
        for block in detail.blocks where block.kind != .image { haystack += "\n\(block.text)" }
        let parsed = CatalogNameParser.parse(title: haystack)
        for name in parsed.actresses { add(name, role: "女优") }
        for maker in parsed.makers { add(maker, role: "片商") }
        if let label = parsed.label, let maker = CatalogNameDictionary.codeMakers[label] {
            add(maker, role: "片商")
        }
        return results
    }

    /// 人物与机构合成一栏：命中资料库的展示完整字段，没命中的保留入口。
    private func peopleSection(_ matches: [PersonMatch], code: String?) -> some View {
        let matched = matches.filter(\.hasRecord).count
        let detailText = code.map { "资料库命中 \(matched)/\(matches.count) · \($0)" }
            ?? "资料库命中 \(matched)/\(matches.count)"
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("人物与机构", detail: detailText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 292), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(matches) { match in
                    personMatchCard(match)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
            }
        }
        .padding(.horizontal, 26)
    }

    /// 匹配卡片：命中资料库时展示完整档案，标签单独做成可点击的彩色胶囊。
    private func personMatchCard(_ match: PersonMatch) -> some View {
        PersonMatchCard(match: match,
                        onOpen: { openPerson(match.name, role: match.role) },
                        onTag: { openTagSearch($0) })
    }

    /// 点标签去资源页看跨源聚合结果。
    private func openTagSearch(_ tag: String) {
        let keyword = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        catalog.globalQuery = keyword
        catalog.setHubTab(.browse)
        store.navigate(to: .catalogSources)
    }

    /// 人物 / 机构卡片：资料库字段 + 彩色标签，整卡可点进档案，标签可点看聚合。
    private struct PersonMatchCard: View {
        let match: PersonMatch
        var onOpen: () -> Void
        var onTag: (String) -> Void

        @State private var hovering = false

        private var accent: Color {
            match.role == "片商" ? LumaBrand.cyan : LumaBrand.coral
        }

        private var detailFacts: [CatalogPersonFact] {
            (match.info?.facts ?? []).filter { $0.label != "标签" }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                header
                if match.info != nil {
                    summaryText
                    factChips
                    tagRow
                    matchedNote
                } else {
                    missingNote
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { cardBackground }
            .overlay { cardBorder }
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.08),
                    radius: hovering ? 12 : 5, y: hovering ? 5 : 2)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .onHover { value in
                withAnimation(.easeOut(duration: 0.16)) { hovering = value }
            }
            .help(match.hasRecord
                  ? "查看 \(match.name) 的内置资料与跨源作品"
                  : "查看 \(match.name) 的跨源作品")
        }

        @ViewBuilder
        private var summaryText: some View {
            if let info = match.info {
                Text(info.summary)
                    .font(.system(size: 11.5))
                    .lineSpacing(2.5)
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        @ViewBuilder
        private var factChips: some View {
            if !detailFacts.isEmpty {
                CatalogFlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(detailFacts) { fact in
                        HStack(spacing: 3) {
                            Text(fact.label)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(fact.value)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.78))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.055),
                                    in: Capsule(style: .continuous))
                    }
                }
            }
        }

        @ViewBuilder
        private var tagRow: some View {
            if !match.tags.isEmpty {
                CatalogFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(match.tags, id: \.self) { tag in
                        CatalogDatabaseTagPill(text: tag, tint: tagTint(tag)) {
                            onTag(tag)
                        }
                    }
                }
            }
        }

        @ViewBuilder
        private var matchedNote: some View {
            if let from = match.matchedFrom {
                Text("匹配自「\(from)」")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }

        private var missingNote: some View {
            Text("内置资料库暂未收录，点击查看跨源作品。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }

        private var header: some View {
            HStack(spacing: 8) {
                CatalogAvatarView(name: match.name,
                                  base64: match.info?.avatarBase64,
                                  size: 30,
                                  ringColor: accent.opacity(0.34))
                    .shadow(color: accent.opacity(hovering ? 0.35 : 0.16), radius: 6, y: 2)

                Text(match.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(match.role)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule(style: .continuous))

                Spacer(minLength: 0)

                if match.hasRecord {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 8.5))
                        Text("资料库")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.12), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule().strokeBorder(accent.opacity(0.24), lineWidth: 0.6)
                    }
                }
            }
        }

        private var cardBackground: some View {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AnyShapeStyle(
                    match.hasRecord
                    ? LinearGradient(colors: [accent.opacity(hovering ? 0.17 : 0.11),
                                              Color.primary.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Color.primary.opacity(0.05),
                                              Color.primary.opacity(0.025)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
                ))
        }

        private var cardBorder: some View {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(match.hasRecord
                              ? accent.opacity(hovering ? 0.55 : 0.28)
                              : Color.primary.opacity(0.07),
                              lineWidth: hovering ? 1 : 0.7)
        }

        private func tagTint(_ tag: String) -> Color {
            let palette: [Color] = [LumaBrand.coral, LumaBrand.amber, LumaBrand.mint,
                                    LumaBrand.cyan, LumaBrand.violet, LumaBrand.pink]
            let sum = tag.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return palette[sum % palette.count]
        }
    }

    /// 详情里除人物 / 机构以外的结构化信息：上线日期、时长、番号等。
    /// 女优与片商统一放进「人物与机构」，避免同一批名字在两栏重复出现。
    private func infoFacts(_ detail: CatalogDetail) -> [CatalogDetailFact] {
        var facts = detail.facts.filter { personRole(for: $0.label) == nil }
        // 站点没给时长、但这部片已经播放过：用本地进度里的真实片长回填。
        if !facts.contains(where: { $0.label == "时长" }),
           let source,
           let progress = catalog.progress(sourceID: source.id, itemID: detail.item.id),
           progress.duration.isFinite, progress.duration > 20 {
            facts.append(CatalogDetailFact(label: "时长", value: Self.durationText(progress.duration)))
        }
        return facts
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, total % 60)
        }
        return "\(minutes):" + String(format: "%02d", total % 60)
    }

    /// 结构化信息（上线日期 / 更新状态 / 出品 / 播放量…）按自适应列排版。
    private func factsSection(_ detail: CatalogDetail) -> some View {
        let facts = infoFacts(detail)
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("详情", detail: "\(facts.count) 项")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 22)],
                      alignment: .leading, spacing: 16) {
                ForEach(facts) { fact in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(LinearGradient(colors: [Color.accentColor,
                                                          Color.accentColor.opacity(0.22)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 2.5, height: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(fact.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(fact.value)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
            }
        }
        .padding(.horizontal, 26)
    }

    // MARK: - 合集

    /// 合集是一组彼此独立的视频（如「台湾A片」52 部），不是连续剧集。
    /// 这里用视频卡片展示标题与封面，避免误标成「第 N 集」；看过的部数直接标在卡片上。
    private func collectionSection(_ detail: CatalogDetail) -> some View {
        let total = detail.collectionTotal ?? detail.episodes.count
        let watched = max(0, (progress?.episode ?? 1) - 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("合集视频")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(total) 部")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                if watched > 0 {
                    Text("已看 \(min(watched, total)) 部")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let progress,
                   let name = detail.episodes.first(where: { $0.index == progress.episode })?.name {
                    Text("看到：\(name)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if progress != nil, let first = detail.episodes.first {
                    Button {
                        play(first, detail: detail)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text("从头播放")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06),
                                    in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("从合集的第 1 部开始播放")
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 232), spacing: 14)],
                      alignment: .leading, spacing: 18) {
                ForEach(detail.episodes) { episode in
                    CatalogCollectionTile(source: source,
                                          episode: episode,
                                          fallbackCover: detail.item.coverURL,
                                          active: progress?.episode == episode.index,
                                          watched: watched >= episode.index) {
                        play(episode, detail: detail)
                    }
                }
            }

            if detail.episodes.count < total {
                HStack(spacing: 8) {
                    Text("已加载 \(detail.episodes.count) / \(total) 部")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Button("重新解析") {
                        catalog.loadDetail(item: item, force: true)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 26)
    }

    private func episodeSection(_ detail: CatalogDetail) -> some View {
        let episodes = visibleEpisodes(detail)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("选集")
                    .font(.system(size: 15, weight: .semibold))
                Text("共 \(detail.episodes.count) 集")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("悬停可静默预览")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                if rangeCount(detail) > 1 {
                    Picker("分段", selection: $rangeIndex) {
                        ForEach(0..<rangeCount(detail), id: \.self) { index in
                            Text(rangeTitle(index, total: detail.episodes.count)).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                if let progress {
                    Text("看到第 \(progress.episode) 集")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 216), spacing: 12)],
                      spacing: 14) {
                ForEach(episodes) { episode in
                    CatalogEpisodeCard(
                        source: source,
                        episode: episode,
                        coverURL: episode.coverURL.isEmpty ? detail.item.coverURL : episode.coverURL,
                        active: progress?.episode == episode.index,
                        watched: (progress?.episode ?? 0) > episode.index,
                        previewTarget: {
                            guard let source else { return nil }
                            return await catalog.previewTarget(sourceID: source.id,
                                                               itemID: detail.item.id,
                                                               episode: episode)
                        }
                    ) {
                        play(episode, detail: detail)
                    }
                }
            }
        }
        .padding(.horizontal, 26)
    }

    private func visibleEpisodes(_ detail: CatalogDetail) -> [CatalogEpisode] {
        let start = rangeIndex * Self.rangeSize
        guard start < detail.episodes.count else { return detail.episodes }
        let end = min(detail.episodes.count, start + Self.rangeSize)
        return Array(detail.episodes[start..<end])
    }

    private func rangeCount(_ detail: CatalogDetail) -> Int {
        max(1, Int(ceil(Double(detail.episodes.count) / Double(Self.rangeSize))))
    }

    private func rangeTitle(_ index: Int, total: Int) -> String {
        let start = index * Self.rangeSize + 1
        let end = min(total, (index + 1) * Self.rangeSize)
        return "\(start)–\(end)"
    }

    /// 打开详情后定位到「上次看到的那一集」所在分段，避免还要自己翻。
    private func alignRangeToProgress() {
        guard !didAlignRange, let detail = catalog.detail else { return }
        didAlignRange = true
        guard let progress, progress.episode > 0 else { return }
        let index = (progress.episode - 1) / Self.rangeSize
        let total = rangeCount(detail)
        rangeIndex = min(max(0, index), total - 1)
    }

    // MARK: - 正文去重

    /// 顶部展示的引子：正文里的第一段。
    private func heroLead(_ detail: CatalogDetail) -> String? {
        guard let text = detail.blocks.first(where: { $0.kind == .paragraph })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// 正文区块：去掉与顶部引子完全相同的第一段。
    /// 站点常把同一段简介同时塞进概要与正文，两处都显示就是重复。
    private func articleBlocks(_ detail: CatalogDetail) -> [CatalogContentBlock] {
        let lead = heroLead(detail)
        var skippedLead = false
        return detail.blocks.filter { block in
            guard block.kind == .paragraph, !skippedLead, let lead else { return true }
            if block.text.trimmingCharacters(in: .whitespacesAndNewlines) == lead {
                skippedLead = true
                return false
            }
            return true
        }
    }

    /// 正文是否还有「上面没展示过」的内容：没有就不渲染正文区。
    private func hasArticleBody(_ detail: CatalogDetail) -> Bool {
        !articleBlocks(detail).isEmpty
    }

    // MARK: - 图文内容

    /// 正文：像杂志内页一样排长文——阅读卡片、引子段、章节标题、配图与收尾。
    /// 每张图各占一整行，宽度与正文列一致，不做并排缩略图。
    private func articleSection(_ detail: CatalogDetail) -> some View {
        // 顶部引子已经展示过同一段，这里从第二段开始，避免正文开头重复一遍。
        let blocks = articleBlocks(detail)
        let leadIndex = blocks.firstIndex(where: { $0.kind == .paragraph })
        let imageCount = detail.articleImages.count

        let card = VStack(alignment: .leading, spacing: 24) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block.kind {
                case .heading:
                    readingColumn { articleHeading(block.text) }
                case .paragraph:
                    readingColumn {
                        articleParagraph(block.text, isLead: index == leadIndex)
                    }
                case .image:
                    articleImage(block.text, detail: detail)
                }
            }
            readingColumn { endMark }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.028))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
        }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                sectionHeader("正文", detail: imageCount == 0 ? nil : "\(imageCount) 张图")
                Spacer(minLength: 10)
                Text("点击查看大图 · 右键保存到图库")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            card
        }
        .padding(.horizontal, 26)
    }

    /// 长文正文列：卡片跟着窗口变宽，文字列限制在 900 以内保持可读。
    private func readingColumn<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func articleHeading(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
            Text(text)
                .font(.system(size: 19, weight: .bold))
                .tracking(0.2)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func articleParagraph(_ text: String, isLead: Bool) -> some View {
        Text(text)
            .font(.system(size: isLead ? 16.5 : 15))
            .lineSpacing(isLead ? 11 : 9.5)
            .foregroundStyle(isLead ? Color.primary.opacity(0.95)
                                    : Color.primary.opacity(0.84))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, isLead ? 14 : 0)
            .overlay(alignment: .leading) {
                if isLead {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(LumaBrand.gradient)
                        .frame(width: 2.5)
                }
            }
    }

    /// 每张配图单独占一行，宽度铺满正文列，下方标注序号；悬停可保存，右键也有菜单。
    private func articleImage(_ url: String, detail: CatalogDetail) -> some View {
        let index = (detail.articleImages.firstIndex(of: url) ?? 0) + 1
        let total = max(1, detail.articleImages.count)
        return CatalogArticleImageCard(source: source,
                                       urlString: url,
                                       index: index,
                                       total: total,
                                       onOpen: {
                                           if let i = detail.articleImages.firstIndex(of: url) {
                                               previewIndex = i
                                           }
                                       },
                                       onSave: { saveArticleImage(url) })
    }

    /// 把正文配图存进当前图库：写入临时文件后走图库自己的导入流程。
    private func saveArticleImage(_ urlString: String) {
        guard let source else { return }
        Task { @MainActor in
            // 全尺寸优先，站点不给大图时退回缩略图，至少保证能存下来。
            var image = await CatalogArtworkCache.shared.image(source: source,
                                                               urlString: urlString,
                                                               quick: false)
            if image == nil {
                image = await CatalogArtworkCache.shared.image(source: source,
                                                               urlString: urlString,
                                                               quick: true)
            }
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else {
                store.showToast("图片保存失败")
                return
            }
            do {
                _ = try await store.ingestService.ingest(
                    IngestRequest(payload: .imageData(data, fileExtension: "png"),
                                  title: "网络资源图片",
                                  folderName: "网络资源图片")
                )
                store.showToast("已保存到图库 · 网络资源图片")
            } catch {
                store.showToast("图片保存失败：\(error.localizedDescription)")
            }
        }
    }

    /// 长文收尾：一条细线夹一枚小菱形，给阅读一个结束感。
    private var endMark: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            Image(systemName: "diamond.fill")
                .font(.system(size: 5))
                .foregroundStyle(Color.accentColor.opacity(0.55))
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.top, 4)
    }

    private func sectionHeader(_ title: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LumaBrand.gradient)
                .frame(width: 3, height: 14)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }

    private var emptyContentNote: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.below.photo")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("这个条目没有可直接播放的视频")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    /// 图集大图：黑底、左右翻页、右上角关闭。
    private func galleryPreview(_ images: [String], index: Int) -> some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture { previewIndex = nil }

            if let source {
                CatalogArtworkImage(source: source, urlString: images[index],
                                    cornerRadius: 12, fit: true, quality: .full)
                    .frame(maxWidth: 820, maxHeight: 620)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                    .padding(.horizontal, 70)
                    .padding(.vertical, 60)
                    .contextMenu {
                        Button {
                            saveArticleImage(images[index])
                        } label: {
                            Label("保存到图库", systemImage: "square.and.arrow.down")
                        }
                    }
            }

            VStack {
                HStack {
                    Text("\(index + 1) / \(images.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.12), in: Capsule(style: .continuous))
                    Spacer()
                    Button {
                        previewIndex = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("关闭预览")
                }
                Spacer()
                HStack {
                    previewArrow("chevron.left", enabled: index > 0) {
                        previewIndex = index - 1
                    }
                    Spacer()
                    previewArrow("chevron.right", enabled: index < images.count - 1) {
                        previewIndex = index + 1
                    }
                }
            }
            .padding(20)
        }
        .transition(.opacity)
    }

    private func previewArrow(_ icon: String, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? .white : .white.opacity(0.3))
                .frame(width: 34, height: 34)
                .background(.white.opacity(enabled ? 0.14 : 0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - 状态

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("正在解析分集…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("重试") {
                catalog.loadDetail(item: item, force: true)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 数据

    private func coverURL(_ detail: CatalogDetail) -> String {
        detail.item.coverURL.isEmpty ? item.coverURL : detail.item.coverURL
    }

    private func displayTitle(_ detail: CatalogDetail) -> String {
        detail.item.title.isEmpty ? item.title : detail.item.title
    }

    private func resumeEpisode(_ detail: CatalogDetail) -> CatalogEpisode {
        if let progress, let matched = detail.episodes.first(where: { $0.index == progress.episode }) {
            return matched
        }
        return detail.episodes.first ?? CatalogEpisode(index: 1, pageURL: "")
    }

    private func resumeTitle(_ detail: CatalogDetail) -> String {
        if detail.isCollection {
            return progress == nil ? "播放第一部" : "继续播放"
        }
        if let progress, progress.episode > 0 {
            return "从第 \(progress.episode) 集继续"
        }
        return "播放第 1 集"
    }

    private var isFavorite: Bool {
        guard let source else { return false }
        return catalog.isFavorite(sourceID: source.id, itemID: item.id)
    }

    private func toggleFavorite(_ detail: CatalogDetail) {
        guard let source else { return }
        var value = detail.item
        if value.coverURL.isEmpty { value.coverURL = item.coverURL }
        if value.title.isEmpty { value.title = item.title }
        catalog.toggleFavorite(source: source, item: value)
    }

    private func play(_ episode: CatalogEpisode, detail: CatalogDetail) {
        let seconds: Double = {
            guard let progress, progress.episode == episode.index else { return 0 }
            return progress.seconds
        }()
        // 内嵌详情不要调用 dismiss：它会关掉宿主窗口，而窗口一关应用就直接退出。
        if !isEmbedded { dismiss() }
        catalog.play(item: detail.item, detail: detail, episode: episode, seconds: seconds)
    }
}

/// 资料库标签胶囊：彩色、可点，点一下去资源页看跨源聚合。
private struct CatalogDatabaseTagPill: View {
    let text: String
    let tint: Color
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text)
                    .font(.system(size: 10.5, weight: .semibold))
                if hovering {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7.5, weight: .bold))
                }
            }
            .foregroundStyle(hovering ? Color.white : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule(style: .continuous)
                    .fill(hovering ? AnyShapeStyle(tint)
                                   : AnyShapeStyle(tint.opacity(0.16)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(hovering ? 0 : 0.36), lineWidth: 0.7)
            }
            .shadow(color: tint.opacity(hovering ? 0.32 : 0), radius: 6, y: 2)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { value in
            withAnimation(.easeOut(duration: 0.14)) { hovering = value }
        }
        .help("跨源聚合搜索「\(text)」")
    }
}

/// 合集里的一个视频：16:9 封面 + 标题 + 时长，悬停浮出播放键。
private struct CatalogCollectionTile: View {
    let source: CatalogSource?
    let episode: CatalogEpisode
    let fallbackCover: String
    let active: Bool
    /// 已经看过的部：封面压暗并打勾，一眼能看出进度。
    var watched: Bool = false
    var onPlay: () -> Void

    @State private var hovering = false

    private var cover: String {
        episode.coverURL.isEmpty ? fallbackCover : episode.coverURL
    }

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                artwork
                Text(episode.title)
                    .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Color.accentColor
                                            : Color.primary.opacity(watched ? 0.55 : 0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 34, alignment: .topLeading)
                    .help(episode.title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }

    private var artwork: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomTrailing) {
                    if let source {
                        CatalogArtworkImage(source: source, urlString: cover, cornerRadius: 12)
                            .opacity(watched && !active ? 0.62 : 1)
                    } else {
                        Color.primary.opacity(0.06)
                    }
                    if let duration = episode.duration, !duration.isEmpty {
                        Text(duration)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule(style: .continuous))
                            .padding(7)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if watched, !active {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7.5, weight: .bold))
                        Text("已看")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.52), in: Capsule(style: .continuous))
                    .padding(7)
                }
            }
            .overlay {
                if hovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.46), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.34), lineWidth: 0.6))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? Color.accentColor.opacity(0.85)
                                         : Color.primary.opacity(0.10),
                                  lineWidth: active ? 1.4 : 0.7)
            }
            .shadow(color: .black.opacity(hovering ? 0.24 : 0.10),
                    radius: hovering ? 12 : 6, y: hovering ? 6 : 2)
            .scaleEffect(hovering ? 1.012 : 1)
    }
}

/// 正文里的配图：独立成行、按图片自身比例铺满正文列，不裁切也不并排。
private struct CatalogArticleImage: View {
    let source: CatalogSource?
    let urlString: String

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Group {
            if let image {
                // Color.clear 先把这一行的高度按图片比例撑开，
                // 再把图片叠上去，避免 Button / VStack 给不出宽度时图片缩成小图标。
                Color.clear
                    .aspectRatio(image.size, contentMode: .fit)
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    }
            } else {
                Color.primary.opacity(0.05)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? LumaBrand.amber.opacity(0.55)
                                      : Color.primary.opacity(0.06),
                              lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.16), radius: hovering ? 18 : 8,
                y: hovering ? 8 : 4)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { inside in hovering = inside }
        .task(id: urlString) {
            guard image == nil, let source, !urlString.isEmpty else { return }
            // 阅读场景不要先上缩略图：直接等解密后的原图，避免正文里忽然变清晰。
            if let full = await CatalogArtworkCache.shared.image(source: source,
                                                                urlString: urlString,
                                                                quick: false) {
                image = full
            }
        }
    }
}

/// 正文配图：点击看大图，右键或悬停按钮保存到图库。
private struct CatalogArticleImageCard: View {
    let source: CatalogSource?
    let urlString: String
    let index: Int
    let total: Int
    let onOpen: () -> Void
    let onSave: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CatalogArticleImage(source: source, urlString: urlString)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(hovering ? 0.18 : 0.07),
                                      lineWidth: 0.6)
                }
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Button(action: onSave) {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 9, weight: .bold))
                                Text("保存到图库")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(.black.opacity(0.52), in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.6)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .transition(.opacity)
                    }
                }
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture(perform: onOpen)
                .contextMenu {
                    Button("查看大图", action: onOpen)
                    Button("保存到图库", action: onSave)
                }
                .help("点击查看大图 · 右键保存到图库")
                .onHover { inside in hovering = inside }
                .animation(.easeOut(duration: 0.15), value: hovering)

            Text("图 \(index) / \(total)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 选集卡

/// 选集卡：悬停 0.6 秒后静默播放这一集，移开立刻卸载解码器。
/// 正在看的用琥珀色标出，看过的右上角留一颗小点。
private struct CatalogEpisodeCard: View {
    let source: CatalogSource?
    let episode: CatalogEpisode
    let coverURL: String
    let active: Bool
    let watched: Bool
    var previewTarget: (() async -> CatalogPreviewTarget?)?
    let onOpen: () -> Void

    @State private var isHovering = false
    @State private var previewURL: URL?
    @State private var previewHeaders: [String: String] = [:]
    @State private var previewTask: Task<Void, Never>?
    @State private var previewHandle = VideoPreviewHandle()
    @State private var isPreparingPreview = false

    private let radius: CGFloat = 12

    var body: some View {
        Button(action: onOpen) {
            artwork
        }
        .buttonStyle(.plain)
        .help("第 \(episode.index) 集 · 悬停静默预览")
        .scaleEffect(isHovering ? 1.018 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { hovering in
            if hovering { startPreview() } else { stopPreview() }
        }
        .onDisappear { stopPreview() }
    }

    private var artwork: some View {
        // 封面放 background、文字放 overlay：集数始终压在画面之上。
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 118)
            .background {
                if let source {
                    CatalogArtworkImage(source: source, urlString: coverURL, cornerRadius: radius)
                } else {
                    Color.primary.opacity(0.06)
                }
            }
            .overlay {
                if let previewURL {
                    HoverVideoSurface(url: previewURL,
                                      headers: previewHeaders,
                                      handle: previewHandle) { _ in }
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.7)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) { caption }
            .overlay(alignment: .topLeading) { previewChip }
            .overlay(alignment: .topTrailing) { watchedDot }
            .overlay { hoverIndicator }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderStyle, lineWidth: active || isHovering ? 1.4 : 0.8)
            }
            .shadow(color: active ? LumaBrand.amber.opacity(0.3)
                                  : (isHovering ? .black.opacity(0.24) : .clear),
                    radius: isHovering ? 14 : 10,
                    y: isHovering ? 6 : 3)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var caption: some View {
        HStack(spacing: 6) {
            Text("第 \(episode.index) 集")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(active ? Color.black.opacity(0.9) : .white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule(style: .continuous)
                        .fill(active ? AnyShapeStyle(LumaBrand.amber)
                                     : AnyShapeStyle(Color.black.opacity(0.55)))
                }
            if active {
                Text("正在看")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.35), in: Capsule(style: .continuous))
            }
        }
        .padding(9)
    }

    @ViewBuilder
    private var previewChip: some View {
        if previewURL != nil {
            HStack(spacing: 3) {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 7, weight: .bold))
                Text("静默预览")
                    .font(.system(size: 8.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.5), in: Capsule(style: .continuous))
            .padding(9)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var watchedDot: some View {
        if watched, !active {
            Circle()
                .fill(LumaBrand.amber.opacity(0.85))
                .frame(width: 5, height: 5)
                .padding(9)
        }
    }

    /// 悬停时中央的播放提示：解析中先转圈，解析失败也还能点开播放。
    @ViewBuilder
    private var hoverIndicator: some View {
        if isHovering, previewURL == nil {
            if isPreparingPreview {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.6) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.92), in: Circle())
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    private var borderStyle: AnyShapeStyle {
        if active { return AnyShapeStyle(LumaBrand.amber.opacity(0.9)) }
        if isHovering { return AnyShapeStyle(LumaBrand.amber.opacity(0.55)) }
        return AnyShapeStyle(Color.primary.opacity(0.08))
    }

    private func startPreview() {
        guard previewURL == nil, let previewTarget else {
            withAnimation(.easeOut(duration: 0.12)) { isHovering = true }
            return
        }
        withAnimation(.easeOut(duration: 0.12)) { isHovering = true }
        previewTask?.cancel()
        isPreparingPreview = true
        previewTask = Task { @MainActor in
            // 停够 0.6 秒再解析：鼠标扫过选集不该每一格都发请求。
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            // 解析可能撞上并发排队或站点抖动：鼠标还停着就再试两次。
            for attempt in 0..<3 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    guard !Task.isCancelled else { return }
                }
                if let target = await previewTarget() {
                    guard !Task.isCancelled else { return }
                    isPreparingPreview = false
                    withAnimation(.easeOut(duration: 0.22)) {
                        previewHeaders = target.headers
                        previewURL = target.url
                    }
                    return
                }
                guard !Task.isCancelled else { return }
            }
            isPreparingPreview = false
        }
    }

    private func stopPreview() {
        withAnimation(.easeOut(duration: 0.12)) { isHovering = false }
        previewTask?.cancel()
        previewTask = nil
        isPreparingPreview = false
        guard previewURL != nil || !previewHeaders.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            previewURL = nil
            previewHeaders = [:]
        }
    }
}

private func catalogTimeText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let value = Int(seconds.rounded())
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let secs = value % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}
