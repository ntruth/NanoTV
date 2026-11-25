import SwiftUI
import AppKit

/// 智能助手面板：问答、图片理解、检索建议与图库工具操作。
struct AIAssistantView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @FocusState private var inputFocused: Bool
    @State private var showClearConfirm = false
    @State private var hoveredID: String?
    @State private var appeared = false
    /// 鼠标所在的对话消息：显示复制按钮等轻量操作。
    @State private var hoveredMessageID: UUID?
    /// 刚复制的消息：复制按钮短暂变成「已复制」。
    @State private var copiedMessageID: UUID?
    /// 折叠起来的执行轨迹分组。
    @State private var collapsedActionGroups: Set<String> = []
    /// 手动展开的执行轨迹：默认超过 4 步先折叠，点开才展开。
    @State private var expandedActionGroups: Set<String> = []
    /// 本轮开始的时刻：运行状态里显示已用时。
    @State private var thinkingStartedAt = Date()
    /// 面板尺寸：默认更大，支持拖右下角缩放，并随图库/设备记住上次大小。
    @AppStorage("ai.panel.width") private var panelWidth = 960.0
    @AppStorage("ai.panel.height") private var panelHeight = 820.0
    /// 拖动缩放时的起始尺寸，保证跟手。
    @State private var resizeBase: CGSize?

    /// 能力分区：与工具体系一一对应，点示例即可直接提问。
    private struct Capability: Identifiable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String
        let examples: [String]
    }

    /// 首页主推案例：直接对应真实可执行的操作。
    private struct CaseCard: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let prompt: String
    }

    private let libraryCases: [CaseCard] = [
        CaseCard(id: "album", icon: "calendar.badge.clock",
                 title: "按时间地点建相簿",
                 detail: "从拍摄时间与地点里找出去年在上海的照片，一次归组。",
                 prompt: "把去年在上海拍的照片按月份整理成相簿"),
        CaseCard(id: "rate", icon: "star.leadinghalf.filled",
                 title: "批量评级与标记",
                 detail: "给一组照片打星级、留用旗标与色标，方便后续筛选。",
                 prompt: "把选中的照片设为 4 星，标记留用，并加绿色色标")
    ]

    private let cinemaCases: [CaseCard] = [
        CaseCard(id: "cinema-match", icon: "wand.and.stars",
                 title: "整理未识别影片",
                 detail: "读取目录树、按文件名分组，再批量搜索候选并写回。",
                 prompt: "整理当前影院里未识别的影片，先按季集分组再匹配"),
        CaseCard(id: "cinema-resume", icon: "play.circle",
                 title: "继续上次没看完的",
                 detail: "从观看记录里挑最近一条，自动接上进度播放。",
                 prompt: "继续播放上次没看完的")
    ]

    private let catalogCases: [CaseCard] = [
        CaseCard(id: "catalog-update", icon: "sparkles.tv",
                 title: "今天的更新",
                 detail: "读取更新日历里今天新增的条目，直接播放或加入稍后看。",
                 prompt: "今天网络资源有什么更新？把前三个加入稍后看"),
        CaseCard(id: "catalog-search", icon: "magnifyingglass",
                 title: "跨源搜索",
                 detail: "在全部已启用站点里搜番号、标题或演员。",
                 prompt: "在所有已启用的源里搜一下「沙丘」")
    ]

    private let networkCinemaCases: [CaseCard] = [
        CaseCard(id: "ncinema-resume", icon: "play.circle",
                 title: "继续上次没看完的",
                 detail: "聚合各源的续看记录，接着上次的进度播放。",
                 prompt: "播放网络影院里上次没看完的那部"),
        CaseCard(id: "ncinema-search", icon: "film.stack",
                 title: "找一部电影",
                 detail: "跨影视源搜索，同名会聚合成多个来源。",
                 prompt: "搜索并播放《流浪地球 2》")
    ]

    private let tvCases: [CaseCard] = [
        CaseCard(id: "tv-tonight", icon: "moon.stars.fill",
                 title: "今晚看什么",
                 detail: "按节目单挑今晚的频道与黄金时段节目。",
                 prompt: "今晚有什么好看的？帮我挑几个频道"),
        CaseCard(id: "tv-play", icon: "tv",
                 title: "直接播放频道",
                 detail: "说出频道名即可开播，也可以查节目单或回看。",
                 prompt: "播放 CCTV-1，并看看今晚的节目单")
    ]

    /// 首页主推案例跟随当前模块，避免在影院页还推荐「压缩照片」。
    private var cases: [CaseCard] {
        if isTVContext { return tvCases }
        if isCinemaContext { return cinemaCases }
        if isNetworkCinemaContext { return networkCinemaCases }
        if isCatalogContext { return catalogCases }
        return libraryCases
    }

    private let browseCapability = Capability(
        id: "browse", icon: "magnifyingglass",
        title: "检索与浏览",
        subtitle: "关键词 · 时间 · 地点 · 人物",
        examples: ["找去年海边的照片", "把 4 星以上照片列出来", "切换到视频"])
    private let albumCapability = Capability(
        id: "album", icon: "rectangle.stack",
        title: "相簿与文件夹",
        subtitle: "建相簿 · 归组 · 改封面",
        examples: ["按主题建 4 个相簿", "新建「2025」文件夹"])
    private let photoCapability = Capability(
        id: "photo", icon: "photo.on.rectangle.angled",
        title: "图片与标记",
        subtitle: "收藏 · 星级 · 色标 · 压缩",
        examples: ["收藏这 3 张", "把这些标成 5 星", "无损压缩这些照片"])
    private let videoCapability = Capability(
        id: "video", icon: "video",
        title: "视频",
        subtitle: "找视频 · 收藏 · 归组",
        examples: ["有哪些视频", "把视频放进「旅行」"])
    private let cinemaCapability = Capability(
        id: "cinema", icon: "film.stack",
        title: "影院",
        subtitle: "匹配 · 收藏 · 续看 · 跳过片头",
        examples: ["我收藏了哪些电影", "继续播放上次没看完的", "把这部剧设为跳过片头 90 秒"])
    private let catalogCapability = Capability(
        id: "catalog", icon: "play.rectangle.on.rectangle",
        title: "网络资源",
        subtitle: "跨源搜索 · 播放 · 稍后看",
        examples: ["搜一下并播放第一条", "把今天新片加入稍后看"])
    private let tvCapability = Capability(
        id: "tv", icon: "tv",
        title: "网络电视",
        subtitle: "直播 · 节目单 · 回看 · 收藏",
        examples: ["今晚有什么好看的", "播放 CCTV-1", "看看湖南卫视节目单"])

    private var capabilities: [Capability] {
        if isTVContext {
            return [tvCapability, browseCapability, videoCapability, photoCapability]
        }
        if isCinemaContext {
            return [cinemaCapability, browseCapability, photoCapability, videoCapability]
        }
        if isNetworkCinemaContext {
            return [networkCinemaCapabilities, browseCapability, cinemaCapability, photoCapability]
        }
        if isCatalogContext {
            return [catalogCapability, browseCapability, photoCapability, videoCapability]
        }
        return [browseCapability, albumCapability, photoCapability, videoCapability]
    }

    private var networkCinemaCapabilities: Capability {
        Capability(id: "ncinema", icon: "film.stack",
                   title: "网络影院",
                   subtitle: "聚合搜索 · 续看 · 播放",
                   examples: ["播放上次没看完的", "搜一下《沙丘》", "最近更新的电影"])
    }

    private var quickExamples: [String] {
        if isTVContext {
            return ["今晚有什么好看的", "播放 CCTV-1", "看看湖南卫视节目单", "收藏这个频道"]
        }
        if isCinemaContext {
            return ["继续播放上次没看完的", "整理未识别的影片",
                    "我收藏了哪些电影", "把这部剧设为跳过片头 90 秒"]
        }
        if isNetworkCinemaContext {
            return ["播放上次没看完的", "搜一下《沙丘》", "最近更新的电影"]
        }
        if isCatalogContext {
            return ["搜一下今天的更新", "播放第一条结果", "把今天新片加入稍后看"]
        }
        return ["把 4 星以上照片建成相簿", "给这组照片打关键词",
                "找去年在上海的照片", "整理影院未识别的影片"]
    }

    private var isCinemaContext: Bool {
        switch store.sidebarItem {
        case .cinema, .cloudCinema: return true
        default: return false
        }
    }

    private var isCatalogContext: Bool {
        switch store.sidebarItem {
        case .catalogSources, .catalogSource: return true
        default: return false
        }
    }

    private var isNetworkCinemaContext: Bool {
        store.sidebarItem == .networkCinema
    }

    private var isTVContext: Bool {
        store.sidebarItem == .iptv
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                header
                divider
                messageList
                divider
                composer
            }
        }
        .frame(width: CGFloat(panelWidth), height: CGFloat(panelHeight))
        .overlay(alignment: .bottomTrailing) {
            resizeHandle
                .padding(5)
        }
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
        .confirmationDialog("开始新对话？", isPresented: $showClearConfirm) {
            Button("新对话", role: .destructive) {
                store.clearAIConversation()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前对话会从图库中清除，清空后无法恢复。")
        }
        .onAppear {
            inputFocused = true
            let size = clampedPanelSize(CGSize(width: panelWidth, height: panelHeight))
            if size.width != CGFloat(panelWidth) { panelWidth = Double(size.width) }
            if size.height != CGFloat(panelHeight) { panelHeight = Double(size.height) }
            withAnimation(settings.motion.overlay) { appeared = true }
        }
        .onChange(of: store.aiIsResponding) { _, responding in
            if responding { thinkingStartedAt = Date() }
        }
    }

    // MARK: - 背景

    private var backdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                           startPoint: .topLeading, endPoint: .center)
            RadialGradient(colors: [Color.accentColor.opacity(0.07), .clear],
                           center: .topTrailing, startRadius: 8, endRadius: 460)
        }
        .ignoresSafeArea()
    }

    private var divider: some View {
        Divider().opacity(0.55)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color.accentColor,
                                                Color.accentColor.opacity(0.62)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 40, height: 40)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 9, y: 3)
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("智能助手")
                        .font(.system(size: 15, weight: .semibold))
                    if panelWidth >= 780 {
                        badge(store.aiConfig.provider.title)
                        badge(store.aiConfig.mode.title, icon: store.aiConfig.mode.symbol)
                            .help("当前模式：\(store.aiConfig.mode.detail)；可在输入框左侧切换")
                    }
                    badge("\(AILibraryTools.count) 项能力", accent: true)
                        .help("共 \(AILibraryTools.count) 项本地工具：照片检索与整理、影院刮削、网络资源、网络影院与网络电视；修改前会弹窗确认")
                    if store.aiConfig.approval == .automatic {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.badge.automatic.fill")
                                .font(.system(size: 9, weight: .medium))
                            Text("自动应用")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .help("当前为自动应用：AI 写操作不再弹窗，可在设置或 ⋯ 菜单调整")
                    }
                    if store.aiConfig.includeImages {
                        badge("图片理解", icon: "photo")
                    }
                }
                HStack(spacing: 6) {
                    Text(store.sidebarTitle)
                    Text("·")
                    Text("\(store.visibleCount.formatted()) 项")
                    Text("·")
                    Text("选中 \(store.selection.count)")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                showClearConfirm = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(store.aiMessages.isEmpty)
            .help("新对话（清空当前对话）")

            Menu {
                Text("模型：\(store.aiConfig.provider.title) / \(store.aiConfig.model)")
                Divider()
                Menu {
                    ForEach(AIApprovalMode.allCases) { mode in
                        Button {
                            store.aiConfig.approval = mode
                            store.saveAIConfig()
                        } label: {
                            Label("\(mode.title) · \(mode.detail)",
                                  systemImage: store.aiConfig.approval == mode
                                      ? "checkmark" : mode.symbol)
                        }
                    }
                } label: {
                    Label("写操作审批：\(store.aiConfig.approval.title)",
                          systemImage: "checkmark.shield")
                }
                Divider()
                Button("新对话（清空）…", role: .destructive) {
                    showClearConfirm = true
                }
                .disabled(store.aiMessages.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("更多")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private func badge(_ text: String, icon: String? = nil, accent: Bool = false) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .medium))
            }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(accent ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(accent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06),
                    in: Capsule())
    }

    // MARK: - 消息

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.aiMessages.isEmpty {
                        welcome
                    }
                    ForEach(chatItems) { item in
                        switch item {
                        case .message(let message):
                            messageRow(message)
                                .id(message.id)
                        case .actionGroup(let key, let items):
                            actionGroupRow(key: key, items: items)
                                .id(key)
                        }
                    }
                    if store.aiIsResponding {
                        thinkingRow
                    }
                    // 滚到底用的锚点：执行轨迹与回复交错时也能稳定滚到最新内容。
                    Color.clear.frame(height: 1).id("ai.bottom")
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.aiMessages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: store.aiIsResponding) { _, responding in
                if responding { scrollToBottom(proxy) }
            }
            .onChange(of: store.aiActivity) { _, _ in
                if store.aiIsResponding { scrollToBottom(proxy) }
            }
        }
    }

    /// 对话流里的单元：连续的工具回执合并成一张「执行轨迹」卡。
    private enum ChatItem: Identifiable {
        case message(AIChatMessage)
        case actionGroup(key: String, items: [AIChatMessage])

        var id: String {
            switch self {
            case .message(let message): return message.id.uuidString
            case .actionGroup(let key, _): return key
            }
        }
    }

    private var chatItems: [ChatItem] {
        var result: [ChatItem] = []
        var pending: [AIChatMessage] = []
        func flush() {
            guard let first = pending.first else { return }
            result.append(.actionGroup(key: "actions-" + first.id.uuidString, items: pending))
            pending.removeAll()
        }
        for message in store.aiMessages {
            if message.role == .action {
                pending.append(message)
            } else {
                flush()
                result.append(.message(message))
            }
        }
        flush()
        return result
    }

    // MARK: - 欢迎页

    private var welcome: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(colors: [Color.accentColor,
                                                Color.accentColor.opacity(0.48)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 58, height: 58)
                    .shadow(color: Color.accentColor.opacity(0.32), radius: 14, y: 5)
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.top, 12)

            VStack(spacing: 7) {
                Text("把想法说出来，剩下的交给我。")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.primary, Color.accentColor],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                Text("检索、整理相簿与文件夹、收藏与关键词、压缩与美化图片，以及跨源搜索和播放网络资源，都能直接执行；修改前会弹窗确认。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 10) {
                ForEach(cases) { item in
                    caseCard(item)
                }
            }
            .padding(.top, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                     count: panelWidth < 780 ? 1 : 2),
                      alignment: .leading,
                      spacing: 10) {
                ForEach(capabilities) { capability in
                    capabilityCard(capability)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("默认只发送元数据与端侧标签，不包含原图；Key 保存在钥匙串。")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                Image(systemName: store.aiConfig.mode.symbol)
                Text("当前模式：\(store.aiConfig.mode.title) · \(store.aiConfig.mode.detail)")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)

            if !store.aiHasAPIKey {
                HStack(spacing: 10) {
                    Image(systemName: "key")
                        .foregroundStyle(Color.accentColor)
                    Text("还没有填写 \(store.aiConfig.provider.title) 的 API Key。")
                        .font(.system(size: 11.5))
                    Spacer(minLength: 8)
                    SettingsLink {
                        Text("打开设置")
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
    }

    private func caseCard(_ item: CaseCard) -> some View {
        let hovered = hoveredID == item.id
        return Button {
            insert(item.prompt)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(hovered ? 0.22 : 0.14))
                            .frame(width: 28, height: 28)
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovered ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                Text(item.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 8))
                    Text(item.prompt)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.08), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovered ? 0.075 : 0.04),
                        in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(hovered ? 0.30 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredID = inside ? item.id : nil
            }
        }
        .help("填入输入框")
    }

    private func capabilityCard(_ capability: Capability) -> some View {
        let hovered = hoveredID == capability.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(hovered ? 0.20 : 0.13))
                        .frame(width: 26, height: 26)
                    Image(systemName: capability.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(capability.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(capability.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            FlexibleTagLayout(spacing: 5) {
                ForEach(capability.examples, id: \.self) { example in
                    Button {
                        insert(example)
                    } label: {
                        Text(example)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("填入输入框")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(hovered ? 0.075 : 0.045),
                    in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(hovered ? 0.25 : 0), lineWidth: 1)
        )
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredID = inside ? capability.id : nil
            }
        }
    }

    // MARK: - 消息行

    @ViewBuilder
    private func messageRow(_ message: AIChatMessage) -> some View {
        switch message.role {
        case .user:
            userRow(message)
        case .action:
            actionRow(message)
        case .assistant:
            assistantRow(message)
        }
    }

    private func userRow(_ message: AIChatMessage) -> some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 5) {
                Text(message.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(colors: [Color.accentColor.opacity(0.24),
                                                Color.accentColor.opacity(0.13)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                    )
                copyButton(message)
                    .opacity(hoveredMessageID == message.id ? 1 : 0)
                    .allowsHitTesting(hoveredMessageID == message.id)
            }
            .frame(maxWidth: 520, alignment: .trailing)
        }
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredMessageID = inside ? message.id
                    : (hoveredMessageID == message.id ? nil : hoveredMessageID)
            }
        }
    }

    private func assistantRow(_ message: AIChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            miniAvatar(tint: message.isError ? .red : Color.accentColor,
                       icon: message.isError ? "exclamationmark" : "sparkles")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("智能助手")
                        .font(.system(size: 11, weight: .semibold))
                    Text(assistantMeta(message))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if message.id == lastAssistantID, !store.aiIsResponding {
                        regenerateButton(message)
                            .opacity(hoveredMessageID == message.id ? 1 : 0)
                            .allowsHitTesting(hoveredMessageID == message.id)
                    }
                    copyButton(message)
                        .opacity(hoveredMessageID == message.id ? 1 : 0)
                        .allowsHitTesting(hoveredMessageID == message.id)
                }

                VStack(alignment: .leading, spacing: 9) {
                    AIMarkdownText(text: message.text,
                                   tint: message.isError ? Color.red : Color.primary)

                    if !message.photoIDs.isEmpty {
                        photoStrip(message.photoIDs)
                    }

                    if let suggestion = message.suggestion,
                       (suggestion.keywords?.isEmpty == false) || (suggestion.filter?.isEmpty == false) {
                        suggestionCard(suggestion)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(message.isError
                              ? Color.red.opacity(0.07)
                              : Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(message.isError
                                ? Color.red.opacity(0.22)
                                : Color.primary.opacity(0.07),
                                lineWidth: 1)
                )
            }
        }
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredMessageID = inside ? message.id
                    : (hoveredMessageID == message.id ? nil : hoveredMessageID)
            }
        }
    }

    /// 执行轨迹里的合并项：相同文字只显示一次并计数。
    private struct TraceItem: Identifiable {
        let text: String
        let count: Int
        var id: String { text }
    }

    private func condensedTrace(_ items: [AIChatMessage]) -> [TraceItem] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for message in items {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if counts[text] == nil { order.append(text) }
            counts[text, default: 0] += 1
        }
        return order.map { TraceItem(text: $0, count: counts[$0] ?? 1) }
    }

    private func traceIcon(_ text: String) -> String {
        if text.hasPrefix("查看") { return "folder" }
        if text.hasPrefix("读取") { return "list.bullet" }
        if text.hasPrefix("搜索") { return "magnifyingglass" }
        if text.hasPrefix("写回") || text.contains("匹配") { return "arrow.triangle.merge" }
        if text.hasPrefix("播放") { return "play.fill" }
        if text.hasPrefix("选中") { return "cursorarrow" }
        if text.hasPrefix("压缩") || text.hasPrefix("美化") { return "wand.and.rays" }
        if text.hasPrefix("已") { return "checkmark" }
        return "circle"
    }

    private func traceSummary(_ items: [TraceItem]) -> String {
        items.prefix(3)
            .map { $0.count > 1 ? "\($0.text) ×\($0.count)" : $0.text }
            .joined(separator: "  ·  ")
    }

    /// 一段连续的工具回执：合并重复步骤、默认折叠，只展示可读摘要。
    private func actionGroupRow(key: String, items: [AIChatMessage]) -> some View {
        let trace = condensedTrace(items)
        let collapsed = collapsedActionGroups.contains(key)
            || (items.count > 4 && !expandedActionGroups.contains(key))
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 24, height: 24)
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.green)
            }

            VStack(alignment: .leading, spacing: 7) {
                Button {
                    withAnimation(settings.motion.layout) {
                        if collapsed {
                            collapsedActionGroups.remove(key)
                            expandedActionGroups.insert(key)
                        } else {
                            expandedActionGroups.remove(key)
                            collapsedActionGroups.insert(key)
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text("执行轨迹")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("\(items.count) 步")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                        if trace.count < items.count {
                            Text("\(trace.count) 类")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .help(collapsed ? "展开执行步骤" : "收起执行步骤")

                if collapsed {
                    if !trace.isEmpty {
                        Text(traceSummary(trace))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(trace.map(\.text).joined(separator: "\n"))
                            .padding(.leading, 1)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(trace.prefix(30).enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Divider()
                                    .opacity(0.35)
                                    .padding(.leading, 20)
                            }
                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: traceIcon(item.text))
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 12)
                                Text(item.text)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .help(item.text)
                                if item.count > 1 {
                                    Text("×\(item.count)")
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.05), in: Capsule())
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                        }
                        if trace.count > 30 {
                            Text("还有 \(trace.count - 30) 类操作…")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.leading, 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .padding(.leading, 32)
    }

    /// 单条回执的兜底渲染（连续回执会走 actionGroupRow）。
    private func actionRow(_ message: AIChatMessage) -> some View {
        actionGroupRow(key: "actions-" + message.id.uuidString, items: [message])
    }

    private var thinkingRow: some View {
        HStack(alignment: .top, spacing: 10) {
            miniAvatar(tint: Color.accentColor, icon: "sparkles")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("智能助手")
                        .font(.system(size: 11, weight: .semibold))
                    Text(store.aiActivity ?? "正在思考")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    elapsedLabel
                }

                HStack(spacing: 9) {
                    ThinkingDots()
                    Text("正在为你执行，稍候…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
            }
        }
    }

    /// 运行中已用时：让长任务有进度感。
    private var elapsedLabel: some View {
        TimelineView(.periodic(from: thinkingStartedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(thinkingStartedAt)))
            Text(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m\(seconds % 60)s")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var lastAssistantID: UUID? {
        store.aiMessages.last(where: { $0.role == .assistant })?.id
    }

    /// 助手消息页脚：时间 · 用时 · 执行步数。
    private func assistantMeta(_ message: AIChatMessage) -> String {
        var parts = [Self.timeFormatter.string(from: message.createdAt)]
        if let elapsed = message.elapsed, elapsed >= 0.1 {
            parts.append(String(format: "%.1fs", elapsed))
        }
        if let steps = message.toolSteps, steps > 0 {
            parts.append("\(steps) 步")
        }
        return parts.joined(separator: " · ")
    }

    private func regenerateButton(_ message: AIChatMessage) -> some View {
        Button {
            store.regenerateAIResponse()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(message.isError ? "重试" : "重新生成")
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(message.isError ? "重试上一条请求" : "重新生成这条回复")
    }

    private func copyButton(_ message: AIChatMessage) -> some View {
        Button {
            copy(message)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copiedMessageID == message.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(copiedMessageID == message.id ? "已复制" : "复制")
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(copiedMessageID == message.id ? Color.green : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("复制这条消息")
    }

    private func copy(_ message: AIChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        withAnimation(settings.motion.hover) { copiedMessageID = message.id }
        store.showToast("已复制")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedMessageID == message.id {
                withAnimation(settings.motion.hover) { copiedMessageID = nil }
            }
        }
    }

    private func miniAvatar(tint: Color, icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 24, height: 24)
                .shadow(color: tint.opacity(0.22), radius: 4, y: 1)
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func photoStrip(_ ids: [UUID]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    if let photo = store.anyPhoto(id: id) {
                        VStack(alignment: .leading, spacing: 3) {
                            PhotoThumbnailView(photo: photo, purpose: .cover(72))
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(photo.originalName)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 72, alignment: .leading)
                        }
                        .onTapGesture {
                            store.openViewer(id)
                        }
                    }
                }
            }
        }
    }

    private func suggestionCard(_ suggestion: AISearchSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let keywords = suggestion.keywords, !keywords.isEmpty {
                    Text("搜索：\(keywords)")
                        .font(.system(size: 11.5, weight: .medium))
                }
                if let raw = suggestion.filter,
                   let filter = PhotoFilter(rawValue: raw) {
                    Text("筛选：\(filter.title)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("应用到当前网格") {
                store.applyAISuggestion(suggestion)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 输入

    private var composer: some View {
        VStack(spacing: 9) {
            if let error = store.aiError {
                errorBanner(error)
            }

            if !store.aiMessages.isEmpty, !store.aiIsResponding {
                quickCommands
            }

            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if store.aiInput.isEmpty {
                        Text(inputPlaceholder)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $store.aiInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .lineLimit(1...6)
                        .focused($inputFocused)
                        .onSubmit {
                            store.sendAIMessage()
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                }

                HStack(spacing: 8) {
                    imageToggleButton
                    modeMenu
                    modelChip
                    Spacer(minLength: 0)
                    Text("↩ 发送")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    sendButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(inputFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                            lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 12, y: 4)
            .animation(settings.motion.hover, value: inputFocused)

            HStack(spacing: 6) {
                Circle()
                    .fill(store.aiHasAPIKey ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                Text("\(store.aiConfig.provider.title) · \(store.aiConfig.model)")
                Text("·")
                Text(store.aiHasAPIKey ? "Key 已保存在钥匙串" : "未配置 Key")
                if store.aiConfig.includeImages {
                    Text("· 图片理解已开启")
                }
                Spacer(minLength: 0)
                Text("\(store.aiConfig.mode.title) · 记忆 \(store.aiConfig.historyRounds) 轮")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.trailing, 16)
        }
        .frame(maxWidth: 860)
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
            Text(error)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var imageToggleButton: some View {
        Button {
            store.aiConfig.includeImages.toggle()
            store.saveAIConfig()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: store.aiConfig.includeImages ? "photo.fill" : "photo")
                    .font(.system(size: 11))
                Text("图片")
                    .font(.system(size: 10))
            }
            .foregroundStyle(store.aiConfig.includeImages ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(store.aiConfig.includeImages
                        ? Color.accentColor.opacity(0.10)
                        : Color.primary.opacity(0.05),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .help(store.aiConfig.includeImages
              ? "已开启图片理解：会发送压缩缩略图，点击关闭"
              : "开启图片理解：把选中/候选照片压成长边 1024 的 JPEG 发送")
    }

    private var modelChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "cpu")
                .font(.system(size: 8.5))
            Text(store.aiConfig.model)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .frame(maxWidth: 190)
        .help("当前模型：\(store.aiConfig.provider.title) / \(store.aiConfig.model)")
    }

    /// 会话模式：快速 / 标准 / 深度，切换后立即持久化。
    private var modeMenu: some View {
        Menu {
            ForEach(AIMode.allCases) { mode in
                Button {
                    store.aiConfig.mode = mode
                    store.saveAIConfig()
                } label: {
                    Label("\(mode.title) · \(mode.detail)",
                          systemImage: store.aiConfig.mode == mode ? "checkmark" : mode.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.aiConfig.mode.symbol)
                    .font(.system(size: 8.5))
                Text(store.aiConfig.mode.title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.10), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("会话模式：\(store.aiConfig.mode.detail)")
    }

    private var sendButton: some View {
        Button {
            if store.aiIsResponding {
                store.stopAIResponse()
            } else {
                store.sendAIMessage()
            }
        } label: {
            Image(systemName: store.aiIsResponding ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    LinearGradient(colors: [Color.accentColor,
                                            Color.accentColor.opacity(0.72)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .shadow(color: Color.accentColor.opacity(canSend || store.aiIsResponding ? 0.32 : 0),
                        radius: 7, y: 2)
                .opacity(canSend || store.aiIsResponding ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !store.aiIsResponding)
        .help(store.aiIsResponding ? "停止生成" : "发送")
    }

    /// 对话开始后保留一条轻量示例条，方便继续操作。
    private var quickCommands: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                ForEach(quickExamples, id: \.self) { example in
                    Button {
                        insert(example)
                    } label: {
                        Text(example)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var canSend: Bool {
        !store.aiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.aiIsResponding
    }

    /// 输入框占位文案跟随当前模块，示例更贴近用户正在看的页面。
    private var inputPlaceholder: String {
        if isTVContext { return "问点什么，例如：今晚有什么好看的" }
        if isCinemaContext { return "问点什么，例如：整理未识别的影片" }
        if isCatalogContext { return "问点什么，例如：今天网络资源有什么更新" }
        if isNetworkCinemaContext { return "问点什么，例如：播放上次没看完的" }
        return "问点什么，例如：把去年在上海的照片整理成相簿"
    }

    private func insert(_ text: String) {
        store.aiInput = text
        inputFocused = true
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(settings.motion.layout) {
            proxy.scrollTo("ai.bottom", anchor: .bottom)
        }
    }

    // MARK: - 尺寸

    /// 右下角的缩放把手：拖动改变面板大小，双击恢复默认。
    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 18)
            .background(Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let base = resizeBase ?? CGSize(width: panelWidth, height: panelHeight)
                        if resizeBase == nil { resizeBase = base }
                        let size = clampedPanelSize(CGSize(
                            width: base.width + value.translation.width,
                            height: base.height + value.translation.height))
                        panelWidth = Double(size.width)
                        panelHeight = Double(size.height)
                    }
                    .onEnded { _ in resizeBase = nil }
            )
            .onTapGesture(count: 2) { resetPanelSize() }
            .help("拖动调整面板大小，双击恢复默认")
    }

    /// 限制在屏幕可用区域内，避免拖出屏幕后下次打开看不见。
    private func clampedPanelSize(_ size: CGSize) -> CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let minWidth = 680.0
        let minHeight = 560.0
        let maxWidth = max(minWidth, visible.width - 96)
        let maxHeight = max(minHeight, visible.height - 140)
        return CGSize(width: min(maxWidth, max(minWidth, size.width)),
                      height: min(maxHeight, max(minHeight, size.height)))
    }

    private func resetPanelSize() {
        let size = clampedPanelSize(CGSize(width: 960, height: 820))
        withAnimation(settings.motion.layout) {
            panelWidth = Double(size.width)
            panelHeight = Double(size.height)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// 简单的流式标签布局，用于推荐问题。
private struct FlexibleTagLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 460
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 运行中的三点脉冲：比转圈更轻，贴近主流助手的「正在输入」。
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = (sin(time * 4 - Double(index) * 0.8) + 1) / 2
                    Circle()
                        .fill(Color.accentColor.opacity(0.35 + 0.55 * wave))
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.85 + 0.3 * wave)
                }
            }
        }
        .frame(width: 28, height: 12)
    }
}

/// 轻量 Markdown：标题、列表、引用、代码块与行内强调。
/// 只用于助手回复，避免把模型输出原样当成纯文本。
private struct AIMarkdownText: View {
    let text: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullet(String)
        case numbered(String, String)
        case quote(String)
        case code(String)
        case rule
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                if inCode {
                    result.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                    inCode = false
                } else {
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(rawLine)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                result.append(.rule)
                continue
            }
            if trimmed.hasPrefix("#") {
                let marks = trimmed.prefix(while: { $0 == "#" }).count
                let content = String(trimmed.drop(while: { $0 == "#" }))
                    .trimmingCharacters(in: .whitespaces)
                if !content.isEmpty {
                    flushParagraph()
                    result.append(.heading(level: min(3, max(1, marks)), text: content))
                    continue
                }
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                result.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            if let (index, content) = Self.numberedPrefix(trimmed) {
                flushParagraph()
                result.append(.numbered(index, content))
                continue
            }
            paragraph.append(trimmed)
        }

        flushParagraph()
        if inCode, !code.isEmpty { result.append(.code(code.joined(separator: "\n"))) }
        return result
    }

    private static func numberedPrefix(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        let content: String
        if rest.hasPrefix(". ") {
            content = String(rest.dropFirst(2))
        } else if rest.hasPrefix("、") {
            content = String(rest.dropFirst(1))
        } else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (String(digits), trimmed)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let content):
            Text(inline(content))
                .font(.system(size: 12.5))
                .lineSpacing(3.5)
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let content):
            Text(inline(content))
                .font(.system(size: level == 1 ? 15 : (level == 2 ? 13.5 : 12.5),
                              weight: .semibold))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .padding(.top, level == 1 ? 5 : 3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let content):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.55))
                Text(inline(content))
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        case .numbered(let index, let content):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(index).")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint.opacity(0.55))
                Text(inline(content))
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        case .quote(let content):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint.opacity(0.28))
                    .frame(width: 2.5)
                Text(inline(content))
                    .font(.system(size: 12))
                    .lineSpacing(2.5)
                    .foregroundStyle(tint.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .code(let content):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        case .rule:
            Divider()
                .opacity(0.5)
                .padding(.vertical, 2)
        }
    }

    private func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: string, options: options))
            ?? AttributedString(string)
    }
}
