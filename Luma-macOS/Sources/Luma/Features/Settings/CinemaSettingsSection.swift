import SwiftUI
import AppKit

private enum CinemaSettingsTab: String, CaseIterable, Identifiable {
    case scrape
    case subtitle
    case display
    case playback
    case parental
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scrape: return "刮削"
        case .subtitle: return "字幕"
        case .display: return "显示"
        case .playback: return "播放"
        case .parental: return "家长"
        case .advanced: return "高级"
        }
    }
}

private enum CinemaClearAction: String, Identifiable {
    case index
    case progress
    case lists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .index: return "清除刮削结果？"
        case .progress: return "清除观看记录？"
        case .lists: return "清除自定义清单？"
        }
    }

    var message: String {
        switch self {
        case .index: return "会删除这个影院的海报、评分、简介与未识别列表；影片文件不受影响。"
        case .progress: return "会清空继续观看、观看历史与详情页进度；影片与刮削结果不受影响。"
        case .lists: return "会删除所有自定义清单；收藏、想看与影片文件不受影响。"
        }
    }
}

/// 设置 › 影院：刮削、显示、播放与高级维护。
struct CinemaSettingsSection: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var revealKey = false
    @State private var revealCookie = false
    @State private var revealAssrt = false
    /// 显示页：每行数量 / 背景同人画 / 减弱动效 / 界面语言。
    @AppStorage("cinema_wall_columns") private var wallColumnsTarget = 8
    @AppStorage("cinema_ambient_backdrop") private var ambientBackdrop = true
    @AppStorage("cinema_reduce_motion") private var reduceMotion = false
    @AppStorage("cinema_ui_language") private var uiLanguage = "system"
    @State private var tab: CinemaSettingsTab = .scrape
    @State private var pendingClear: CinemaClearAction?
    @State private var pinInput = ""
    @State private var pinUnlockInput = ""
    @State private var pinConfigured = false
    @State private var pinMessage: String?
    /// 当前展开配置的数据源；没配置的源打开页面时自动展开。
    @State private var expandedProvider: CinemaProvider?
    /// 每个源单独的连通性结果，互不影响。
    @State private var providerChecks: [CinemaProvider: CinemaConnectionResult] = [:]
    @State private var testingProviders: Set<CinemaProvider> = []
    /// 在线字幕来源的连通性结果，与刮削源分开存。
    @State private var subtitleChecks: [SubtitleProviderKind: CinemaConnectionResult] = [:]
    @State private var testingSubtitleProviders: Set<SubtitleProviderKind> = []

    @AppStorage("cinema_show_rating_badge") private var showRatingBadge = true
    @AppStorage("cinema_show_format_badge") private var showFormatBadge = true
    @AppStorage("cinema_resume_playback") private var resumePlayback = true
    @AppStorage("cinema_wall_density") private var wallDensity: CinemaWallDensity = .normal

    private let languages: [(id: String, title: String)] = [
        ("zh-CN", "简体中文"),
        ("zh-TW", "繁體中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어")
    ]

    private var tmdbConfigured: Bool {
        !settings.cinemaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tvdbConfigured: Bool {
        !settings.cinemaTVDBKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .scrape:
                        scrapeContent
                    case .subtitle:
                        subtitleContent
                    case .display:
                        displayContent
                    case .playback:
                        playbackContent
                    case .parental:
                        parentalContent
                    case .advanced:
                        advancedContent
                    }
                }
                .padding(18)
            }
        }
        // 敏感项在 AppSettings 初始化时已从统一保险库取过一次；这里只读内存。
        .task(id: tab) {
            switch tab {
            case .scrape:
                // 没填 Key 的源直接展开配置，省得用户自己找。
                if expandedProvider == nil {
                    expandedProvider = settings.cinemaSourceOrder.first { !isProviderConfigured($0) }
                }
            case .parental:
                pinConfigured = CinemaKeychain.has(.parentalPIN)
            default:
                break
            }
        }
        .confirmationDialog(pendingClear?.title ?? "确认清除",
                            isPresented: Binding(
                                get: { pendingClear != nil },
                                set: { if !$0 { pendingClear = nil } }
                            ),
                            presenting: pendingClear) { action in
            Button("清除", role: .destructive) {
                performClear(action)
                pendingClear = nil
            }
            Button("取消", role: .cancel) {
                pendingClear = nil
            }
        } message: { action in
            Text(action.message)
        }
    }

    /// 二级 tab：等宽铺满，视觉上像一级图标 tab 的下一层。
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(CinemaSettingsTab.allCases) { item in
                let selected = tab == item
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { tab = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.10))
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule()
                                    .fill(LumaBrand.violet)
                                    .frame(height: 2)
                                    .padding(.horizontal, 9)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: 刮削

    private var scrapeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            sourceListCard
            behaviorCard
            footer
        }
    }

    /// 三个源独立成行：左边名称，右边配置状态与连通性；顺序就是刮削顺序。
    private var sourceListCard: some View {
        card {
            HStack(spacing: 8) {
                Text("数据源")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("从上到下依次尝试，第一位是首选")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("拖动调整顺序")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }

            VStack(spacing: 0) {
                let order = settings.cinemaSourceOrder
                ForEach(Array(order.enumerated()), id: \.element) { index, provider in
                    providerRow(provider, index: index)
                    if index < order.count - 1 {
                        Divider()
                            .opacity(0.45)
                            .padding(.leading, 62)
                    }
                }
            }
        }
    }

    private func providerRow(_ provider: CinemaProvider, index: Int) -> some View {
        let configured = isProviderConfigured(provider)
        let expanded = expandedProvider == provider
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // 拖动把手 + 序号：序号就是刮削尝试顺序。
                VStack(spacing: 1) {
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(index == 0 ? LumaBrand.violet : Color.secondary)
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 24)
                .contentShape(Rectangle())
                .draggable(provider.rawValue) {
                    Label(provider.title, systemImage: providerIcon(provider))
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(providerAccent(provider).opacity(0.2)))
                }
                .help("拖动调整刮削顺序")

                Button {
                    toggleProvider(provider)
                } label: {
                    HStack(spacing: 9) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(providerAccent(provider).opacity(0.14))
                            Image(systemName: providerIcon(provider))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(providerAccent(provider))
                        }
                        .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(provider.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                if index == 0 {
                                    Text("首选")
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(LumaBrand.violet)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(LumaBrand.violet.opacity(0.13)))
                                }
                            }
                            Text(provider.tagline)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                providerStatusPill(provider, configured: configured)

                Button {
                    testProvider(provider)
                } label: {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(testingProviders.contains(provider) || (!configured && provider != .douban))
                .help("测试 \(provider.title) 连通性")

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleProvider(provider) }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first,
                      let dragged = CinemaProvider(rawValue: raw),
                      dragged != provider else { return false }
                moveProvider(dragged, before: provider)
                return true
            }
            .contextMenu {
                Button("测试连接") { testProvider(provider) }
                if index > 0 {
                    Button("上移") { swapProvider(provider, by: -1) }
                }
                if index < settings.cinemaSourceOrder.count - 1 {
                    Button("下移") { swapProvider(provider, by: 1) }
                }
            }

            if expanded {
                providerFields(provider)
                    .padding(.leading, 34)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: expanded)
    }

    /// 右侧状态：连通结果优先，其次是「已配置 / 未配置」。
    @ViewBuilder
    private func providerStatusPill(_ provider: CinemaProvider, configured: Bool) -> some View {
        if testingProviders.contains(provider) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("测试中")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
        } else if let check = providerChecks[provider] {
            let color = check.ok ? Color.green : Color.orange
            HStack(spacing: 4) {
                Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                Text(check.ok ? "连通" : "不通")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .help(check.message)
        } else if !configured {
            Text("未配置")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
        } else {
            Text(provider == .douban ? "免 Key" : "已配置")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.12)))
        }
    }

    /// 展开后的配置：每个源只出现自己的输入项，互不混在一起。
    @ViewBuilder
    private func providerFields(_ provider: CinemaProvider) -> some View {
        switch provider {
        case .tmdb:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Group {
                        if revealKey {
                            TextField("API Key（v3）或 Read Access Token（v4）", text: $settings.cinemaAPIKey)
                        } else {
                            SecureField("API Key（v3）或 Read Access Token（v4）", text: $settings.cinemaAPIKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    Button(revealKey ? "隐藏" : "显示") { revealKey.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                HStack(spacing: 8) {
                    Text("刮削语言")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settings.cinemaLanguage) {
                        ForEach(languages, id: \.id) { item in
                            Text(item.title).tag(item.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 116)
                    Spacer(minLength: 0)
                    Button("粘贴") { paste(into: $settings.cinemaAPIKey) }
                    Button("申请 API Key") { open("https://www.themoviedb.org/settings/api") }
                }
                .controlSize(.small)
                Text("没填 Key 时自动跳过，继续用下面的源。国内网络可在「高级」里换 TMDB 镜像。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .tvdb:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Group {
                        if revealKey {
                            TextField("TheTVDB API Key（v4）", text: $settings.cinemaTVDBKey)
                        } else {
                            SecureField("TheTVDB API Key（v4）", text: $settings.cinemaTVDBKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    Button("粘贴") { paste(into: $settings.cinemaTVDBKey) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                HStack(spacing: 8) {
                    Text("订阅 PIN")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    SecureField("普通 Key 留空", text: $settings.cinemaTVDBPin)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                        .frame(maxWidth: 180)
                    Spacer(minLength: 0)
                    Button("申请 Key") { open("https://thetvdb.com/api-information") }
                }
                .controlSize(.small)
                Text("TVDB 只补基础资料与分集；演职员 / 预告仍由 TMDB 提供，建议两个都配。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .douban:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("接口")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    TextField("https://movie.douban.com", text: $settings.cinemaDoubanBase)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                }
                HStack(spacing: 6) {
                    Text("Cookie")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    Group {
                        if revealCookie {
                            TextField("可选：被限流时填", text: $settings.cinemaDoubanCookie)
                        } else {
                            SecureField("可选：被限流时填", text: $settings.cinemaDoubanCookie)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    Button(revealCookie ? "隐藏" : "显示") { revealCookie.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                Text("免 Key。被限流（403 / 418）时换镜像地址或填 Cookie 再试。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isProviderConfigured(_ provider: CinemaProvider) -> Bool {
        switch provider {
        case .tmdb: return tmdbConfigured
        case .tvdb: return tvdbConfigured
        case .douban: return true
        }
    }

    private func providerAccent(_ provider: CinemaProvider) -> Color {
        switch provider {
        case .tmdb: return LumaBrand.violet
        case .douban: return LumaBrand.mint
        case .tvdb: return LumaBrand.amber
        }
    }

    private func toggleProvider(_ provider: CinemaProvider) {
        withAnimation(.easeOut(duration: 0.14)) {
            expandedProvider = expandedProvider == provider ? nil : provider
        }
    }

    private func testProvider(_ provider: CinemaProvider) {
        guard !testingProviders.contains(provider) else { return }
        testingProviders.insert(provider)
        providerChecks[provider] = nil
        Task { @MainActor in
            let result = await store.testCinemaProvider(provider)
            providerChecks[provider] = result
            testingProviders.remove(provider)
        }
    }

    // MARK: 在线字幕源连通性

    /// 标题右侧状态：测试结果优先，其次是「已配置 / 未配置」。
    private func subtitleStatus(_ kind: SubtitleProviderKind,
                                configured: Bool) -> (text: String, ok: Bool) {
        if testingSubtitleProviders.contains(kind) { return ("测试中", true) }
        if let check = subtitleChecks[kind] { return (check.ok ? "连通" : "不通", check.ok) }
        return configured ? ("已配置", true) : ("未配置", false)
    }

    @ViewBuilder
    private func subtitleCheckLine(_ kind: SubtitleProviderKind) -> some View {
        if let check = subtitleChecks[kind] {
            HStack(spacing: 5) {
                Image(systemName: check.ok
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                Text(check.message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(check.ok ? Color.green : Color.orange)
            .padding(.top, 2)
        }
    }

    private func testSubtitleProvider(_ kind: SubtitleProviderKind) {
        guard !testingSubtitleProviders.contains(kind) else { return }
        testingSubtitleProviders.insert(kind)
        subtitleChecks[kind] = nil
        let credentials = OpenSubtitlesClient.Credentials(
            apiKey: settings.cinemaSubtitleAPIKey,
            username: settings.cinemaSubtitleUsername,
            password: settings.cinemaSubtitlePassword
        )
        let assrtToken = settings.assrtSubtitleToken
        Task { @MainActor in
            let result: CinemaConnectionResult
            switch kind {
            case .openSubtitles:
                result = await OpenSubtitlesClient.testConnection(credentials: credentials)
            case .assrt:
                result = await AssrtSubtitleClient.testConnection(token: assrtToken)
            }
            subtitleChecks[kind] = result
            testingSubtitleProviders.remove(kind)
        }
    }

    /// 拖动到某一行上：插到它前面。
    private func moveProvider(_ dragged: CinemaProvider, before target: CinemaProvider) {
        var order = settings.cinemaSourceOrder
        guard order.contains(dragged), dragged != target else { return }
        order.removeAll { $0 == dragged }
        let index = order.firstIndex(of: target) ?? order.count
        order.insert(dragged, at: index)
        withAnimation(.easeOut(duration: 0.16)) { settings.cinemaSourceOrder = order }
    }

    private func swapProvider(_ provider: CinemaProvider, by delta: Int) {
        var order = settings.cinemaSourceOrder
        guard let index = order.firstIndex(of: provider) else { return }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            order.swapAt(index, target)
            settings.cinemaSourceOrder = order
        }
    }

    // MARK: 显示

    private var displayContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("浏览", icon: "rectangle.grid.2x2.fill", note: "改动即时生效") {
                settingRow("默认视图", detail: "进入影院时先看到的布局") {
                    Picker("", selection: $store.cinemaViewMode) {
                        ForEach(CinemaViewMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                settingRow("默认排序") {
                    Picker("", selection: $store.cinemaSort) {
                        ForEach(CinemaSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                settingRow("海报墙密度",
                           detail: "紧凑模式同屏更多海报，大图模式看得更清") {
                    Picker("", selection: $wallDensity) {
                        ForEach(CinemaWallDensity.allCases) { density in
                            Text(density.title).tag(density)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                settingToggle("显示评分角标",
                              detail: "卡片右上角的星级与分数",
                              isOn: $showRatingBadge)
                settingToggle("显示规格角标",
                              detail: "只保留最重要的 1–2 个音画标记",
                              isOn: $showFormatBadge)
                settingRow("每行数量", detail: "海报墙每行显示几张；窗口变窄时自动缩小海报") {
                    Picker("", selection: $wallColumnsTarget) {
                        ForEach([6, 8, 10], id: \.self) { value in
                            Text("\(value) 张").tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                settingRow("海报比例", detail: "海报墙 2:3、书架 16:9，固定不提供自定义") {
                    Text("2:3 / 16:9")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                settingToggle("背景同人画",
                              detail: "海报墙用当前影片背景图压暗铺底，切分类时交叉淡入",
                              isOn: $ambientBackdrop)
                settingToggle("减弱动效",
                              detail: "关闭背景淡入、Hero 交叉淡入与卡片上浮，减少视觉干扰",
                              isOn: $reduceMotion)
                settingRow("界面语言", detail: "目前仅提供简体中文，跟随系统时同样显示中文") {
                    Picker("", selection: $uiLanguage) {
                        Text("跟随系统").tag("system")
                        Text("简体中文").tag("zh-Hans")
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                settingNote("海报墙固定 2:3，书架固定 16:9；卡片只放关键规格，完整资料在详情页。")
            }

        }
    }

    // MARK: 字幕

    private var subtitleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("自动挂载", icon: "captions.bubble", note: "三项均默认关闭") {
                settingToggle("同目录外挂字幕",
                              detail: "视频所在文件夹里有同名 .srt / .ass 时自动载入",
                              isOn: $settings.autoSiblingSubtitles)
                settingToggle("内嵌字幕轨",
                              detail: "本地 / SMB 视频自动提取中文字幕轨；云端仍在播放器里手动选",
                              isOn: $settings.autoEmbeddedSubtitles)
                settingToggle("在线字幕匹配",
                              detail: "播放后按片名在已启用的来源里搜一条中文字幕；失败时静默",
                              isOn: $settings.autoOnlineSubtitles,
                              divider: false)
                settingNote("优先级：同目录外挂 › 内嵌字幕轨 › 在线匹配。已有字幕时不会重复下载；手动选字幕不受影响。")
            }

            settingsGroup("字幕来源 · OpenSubtitles",
                          icon: "captions.bubble.fill",
                          status: subtitleStatus(.openSubtitles,
                                                 configured: !settings.cinemaSubtitleAPIKey
                                                     .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) {
                settingToggle("启用",
                              detail: "国际字幕库；未填 API Key 时不参与搜索",
                              isOn: $settings.subtitleProviderOpenSubtitlesEnabled)
                settingField("API Key",
                             detail: "用于搜索字幕",
                             placeholder: "OpenSubtitles API Key",
                             text: $settings.cinemaSubtitleAPIKey,
                             secure: true,
                             reveal: $revealKey)
                settingField("账号",
                             detail: "下载字幕时登录",
                             placeholder: "OpenSubtitles 用户名",
                             text: $settings.cinemaSubtitleUsername)
                settingField("密码",
                             detail: "只存 macOS 钥匙串",
                             placeholder: "OpenSubtitles 密码",
                             text: $settings.cinemaSubtitlePassword,
                             secure: true,
                             divider: false)
                settingActions {
                    Button("测试连接") {
                        testSubtitleProvider(.openSubtitles)
                    }
                    .disabled(testingSubtitleProviders.contains(.openSubtitles)
                              || settings.cinemaSubtitleAPIKey
                                  .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("注册账号") {
                        open("https://www.opensubtitles.com/en/users/sign_up")
                    }
                    Button("申请 API Key") {
                        open("https://www.opensubtitles.com/en/consumers")
                    }
                }
                .controlSize(.small)
                subtitleCheckLine(.openSubtitles)
                settingNote("下载需要填账号与密码；搜索与下载结果都会缓存到本机。")
            }

            settingsGroup("字幕来源 · 伪射手（Assrt）",
                          icon: "character.book.closed.fill",
                          status: subtitleStatus(.assrt,
                                                 configured: !settings.assrtSubtitleToken
                                                     .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) {
                settingToggle("启用",
                              detail: "国内中文字幕为主；搜索免费，下载需要访问令牌",
                              isOn: $settings.subtitleProviderAssrtEnabled)
                settingField("访问令牌",
                             detail: "assrt.net 用户中心获取",
                             placeholder: "32 位 Token",
                             text: $settings.assrtSubtitleToken,
                             secure: true,
                             reveal: $revealAssrt,
                             divider: false)
                settingActions {
                    Button("测试连接") {
                        testSubtitleProvider(.assrt)
                    }
                    .disabled(testingSubtitleProviders.contains(.assrt)
                              || settings.assrtSubtitleToken
                                  .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("获取 Token") {
                        open("https://assrt.net/user/api")
                    }
                    Button("打开伪射手") {
                        open("https://assrt.net")
                    }
                }
                .controlSize(.small)
                subtitleCheckLine(.assrt)
                settingNote("多个来源会并发搜索，结果按「中文优先、下载量」排序；压缩包只自动解压 zip。")
            }

            settingsGroup("字幕样式", icon: "textformat.size", note: "所有视频默认值") {
                settingRow("字号") {
                    Picker("", selection: $settings.subtitleFontSize) {
                        ForEach([13.0, 15.0, 18.0, 21.0], id: \.self) { value in
                            Text("\(Int(value)) pt").tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                settingRow("颜色") {
                    Picker("", selection: $settings.subtitleColor) {
                        Text("白色").tag("white")
                        Text("黄色").tag("yellow")
                        Text("青色").tag("cyan")
                        Text("绿色").tag("green")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }
                settingRow("位置") {
                    Picker("", selection: $settings.subtitlePosition) {
                        Text("底部").tag("bottom")
                        Text("偏上").tag("lower")
                        Text("中间").tag("middle")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }
                settingToggle("半透明底色",
                              detail: "深色底让字幕在亮画面上更清楚",
                              isOn: $settings.subtitleBackground,
                              divider: false)
                settingNote("播放器里还能临时调时间轴偏移；这里改的是所有视频的默认样式。")
            }
        }
    }

    // MARK: 播放

    private var playbackContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("起播", icon: "play.circle.fill", note: "对影院内所有视频生效") {
                settingToggle("从上次位置继续",
                              detail: "点开有观看记录的影片时接着播",
                              isOn: $resumePlayback)
                settingToggle("播完自动连播",
                              detail: "按当前列表顺序播下一集",
                              isOn: $settings.autoPlayNextVideo)
                settingToggle("默认循环播放",
                              detail: "单个视频结束后从头继续",
                              isOn: $settings.loopVideoByDefault)
                settingToggle("打开时静音",
                              detail: "播放中仍可用 M 键取消静音",
                              isOn: $settings.muteVideoByDefault,
                              divider: false)
                settingNote("进度每 10 秒保存一次，关闭播放器时强制保存。")
            }

            settingsGroup("画面与控制", icon: "rectangle.on.rectangle") {
                settingToggle("按片源帧率切刷新率",
                              detail: "24p 片源切到 24Hz，减少 3:2 抖动；退出播放自动恢复",
                              isOn: $settings.matchDisplayFrameRate)
                settingRow("HDR 视频",
                           detail: settings.videoHDRMode.detail + " · 杜比视界 P5 "
                               + (VideoSupport.supportsLibplacebo ? "已就绪" : "未安装 libplacebo")) {
                    Picker("", selection: $settings.videoHDRMode) {
                        ForEach(VideoHDRMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                settingRow("快进 / 快退步长", detail: "网络资源里 ← / → 与 J / L 的跳转距离，连按或按住会加速") {
                    Picker("", selection: $settings.videoSeekStep) {
                        ForEach([1.0, 2.0, 3.0, 5.0, 10.0, 15.0, 30.0], id: \.self) { value in
                            Text("\(Int(value)) 秒").tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                settingRow("播放控制条", detail: settings.videoControlPlacement.detail) {
                    Picker("", selection: $settings.videoControlPlacement) {
                        ForEach(VideoControlPlacement.allCases) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                settingToggle("进度条悬停预览",
                              detail: "鼠标移到进度条上显示该时间点画面；关掉后只看时间",
                              isOn: $settings.scrubPreviewEnabled,
                              divider: false)
            }

            settingsGroup("播放增强", icon: "slider.horizontal.3", note: "对播放器内所有视频生效") {
                settingToggle("高倍速保持音调",
                              detail: "变速播放时用频谱算法保持人声；关闭后 2 倍速以上会明显快放",
                              isOn: $settings.preservePitchAtSpeed)
                settingToggle("音轨切换优化",
                              detail: "多条音轨装进同一会话，普通片源切换不重启转码；"
                                  + "HDR / 杜比视界为兼容播放会重建一次（约 1 秒）",
                              isOn: $settings.instantAudioSwitch)
                settingRow("音质与声道", detail: settings.audioDownmix.detail) {
                    Picker("", selection: $settings.audioDownmix) {
                        ForEach(AudioDownmixMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                settingRow("转码编码", detail: settings.videoTranscodeMode.detail) {
                    Picker("", selection: $settings.videoTranscodeMode) {
                        ForEach(VideoTranscodeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                settingRow("网络缓冲", detail: settings.videoBufferMode.detail) {
                    Picker("", selection: $settings.videoBufferMode) {
                        ForEach(VideoBufferMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
                settingRow("默认音轨", detail: "打开多音轨影片时先选哪条；原声 = 源文件默认轨") {
                    Picker("", selection: $settings.videoPreferredAudio) {
                        Text("原声优先").tag("original")
                        Text("国语优先").tag("zh")
                        Text("英语优先").tag("en")
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                settingRow("默认字幕", detail: "自动 = 按内嵌中文轨挂载；关闭 = 不自动挂任何字幕") {
                    Picker("", selection: $settings.videoPreferredSubtitle) {
                        Text("自动匹配").tag("auto")
                        Text("不自动挂载").tag("off")
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                settingRow("跳过片头", detail: "剧集没有单独设置时用它兜底；0 = 不跳过") {
                    HStack(spacing: 6) {
                        Stepper("", value: $settings.cinemaSkipIntroSeconds, in: 0...300, step: 15)
                            .labelsHidden()
                        Text("\(settings.cinemaSkipIntroSeconds) 秒")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                settingRow("跳过片尾", detail: "片尾自动标记已看并跳到下一集") {
                    HStack(spacing: 6) {
                        Stepper("", value: $settings.cinemaSkipOutroSeconds, in: 0...300, step: 15)
                            .labelsHidden()
                        Text("\(settings.cinemaSkipOutroSeconds) 秒")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                settingToggle("记忆倍速",
                              detail: "退出播放器时记住当前倍速，下次打开沿用",
                              isOn: $settings.videoRememberSpeed)
                settingToggle("优先系统硬解",
                              detail: "关闭后强制走转封装 / 软解，个别显卡花屏时使用",
                              isOn: $settings.videoPreferHardwareDecoding)
                settingToggle("允许画中画",
                              detail: "关闭后播放器里隐藏画中画按钮",
                              isOn: $settings.videoPiPEnabled)
                settingToggle("系统媒体集成",
                              detail: "控制中心与键盘 / 耳机媒体键控制当前视频",
                              isOn: $settings.systemMediaIntegration,
                              divider: false)
                settingNote("音频延迟、内嵌字幕切换仍在播放器的「速度 / 字幕」菜单里临时调整。")
                settingNote("网络缓冲只作用于云端 / WebDAV 等远端片源；本地盘与 SMB 不受影响。")
            }

            settingsGroup("转码缓存", icon: "internaldrive", note: "本机临时分片") {
                settingRow("缓存上限", detail: "超过上限先清理最旧的分片") {
                    Picker("", selection: $settings.videoCacheLimitGB) {
                        ForEach([0, 5, 10, 20, 50, 100], id: \.self) { value in
                            Text(value == 0 ? "不限制" : "\(value) GB").tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                settingNote("云盘边下边播与拖拽产生的临时分片，只影响本机磁盘占用。")
            }
        }
    }

    // MARK: 家长控制

    private var parentalContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("分级限制",
                          icon: "hand.raised.fill",
                          status: settings.cinemaParentalLevel == .off ? ("已关闭", true) : ("已启用", true)) {
                settingRow("允许的最高分级", detail: settings.cinemaParentalLevel.detail) {
                    Picker("", selection: $settings.cinemaParentalLevel) {
                        ForEach(CinemaParentalLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
                if store.cinemaParentalEnabled {
                    settingRow("本次会话", detail: "退出应用或切换分级后自动重新上锁") {
                        HStack(spacing: 8) {
                            Text(store.cinemaParentalUnlocked ? "已解锁" : "已上锁")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(store.cinemaParentalUnlocked ? Color.green : LumaBrand.coral)
                            if store.cinemaParentalUnlocked {
                                Button("重新上锁") { store.lockCinemaParental() }
                                    .controlSize(.small)
                            } else {
                                SecureField("PIN", text: $pinUnlockInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                    .frame(width: 96)
                                Button("解锁") {
                                    if store.unlockCinemaParental(pin: pinUnlockInput) {
                                        pinUnlockInput = ""
                                        pinMessage = nil
                                    } else {
                                        pinMessage = "PIN 不正确，请重试。"
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    settingRow("当前来源受限", divider: false) {
                        Text("\(store.cinemaRestrictedCount(for: store.cinemaActiveScope)) 个条目")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                settingNote("分级来自 TMDB 详情，打开详情页或重新刮削后才会补全；无法识别分级的条目默认放行。")
            }
            .onChange(of: settings.cinemaParentalLevel) { _, _ in
                store.lockCinemaParental()
            }

            settingsGroup("PIN",
                          icon: "lock.fill",
                          status: pinConfigured ? ("已设置", true) : ("未设置", false)) {
                settingRow("解锁 PIN", detail: "至少 4 位数字；只保存在 macOS 钥匙串") {
                    HStack(spacing: 8) {
                        SecureField("PIN", text: $pinInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                            .frame(width: 120)
                        Button("保存") { savePIN() }
                            .controlSize(.small)
                            .disabled(pinInput.trimmingCharacters(in: .whitespaces).count < 4)
                        if pinConfigured {
                            Button("清除") { clearPIN() }
                                .controlSize(.small)
                        }
                    }
                }
                if let pinMessage {
                    Text(pinMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                settingNote("忘记 PIN 时清除后重新设置即可；不会写入图库数据库。")
            }
        }
    }

    private func savePIN() {
        let trimmed = pinInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else {
            pinMessage = "PIN 至少 4 位。"
            return
        }
        CinemaKeychain.set(trimmed, for: .parentalPIN)
        pinInput = ""
        pinConfigured = true
        pinMessage = "PIN 已保存。"
        store.lockCinemaParental()
    }

    private func clearPIN() {
        CinemaKeychain.remove(.parentalPIN)
        pinConfigured = false
        pinMessage = "已清除 PIN；解锁时不再校验。"
        store.cinemaParentalUnlocked = true
    }

    // MARK: 高级

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("当前影院", icon: "film.stack", note: scopeTitle) {
                settingRow("条目") {
                    Text("\(scopeEntries.count) 个 · 已识别 \(matchedCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                settingRow("观看记录") {
                    Text("\(store.cinemaProgress.count) 条")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                settingRow("自定义清单", divider: false) {
                    Text("\(store.cinemaLists.count) 个")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            settingsGroup("接口与镜像", icon: "network") {
                settingField("TMDB 接口",
                             placeholder: "https://api.themoviedb.org/3",
                             text: $settings.cinemaAPIBase)
                settingField("图片地址",
                             placeholder: "https://image.tmdb.org/t/p",
                             text: $settings.cinemaImageBase)
                settingField("豆瓣镜像",
                             detail: "豆瓣被限流时换成自建反代前缀",
                             placeholder: "https://api.douban.com",
                             text: $settings.cinemaDoubanBase)
                settingRow("请求超时", detail: "豆瓣 / TMDB 搜索与详情的单次请求上限") {
                    HStack(spacing: 6) {
                        Stepper("", value: $settings.cinemaRequestTimeout, in: 5...60, step: 5)
                            .labelsHidden()
                        Text("\(Int(settings.cinemaRequestTimeout)) 秒")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                settingRow("日志等级", detail: "诊断日志详细程度，用于排查播放问题") {
                    Picker("", selection: $settings.cinemaLogLevel) {
                        Text("精简").tag("important")
                        Text("标准").tag("standard")
                        Text("详细").tag("verbose")
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                settingNote("访问不了 TMDB 时填自建反代或镜像前缀；只影响之后的请求。")
            }

            settingsGroup("缓存与索引", icon: "externaldrive") {
                settingRow("海报缓存", detail: "磁盘缓存上限 6 GB，超出按最久未用淘汰") {
                    Button("清理缓存") {
                        CinemaArtworkCache.clearDiskCache()
                        store.showToast("已清理影院海报缓存")
                    }
                    .controlSize(.small)
                }
                settingRow("重建索引", detail: "重新从数据库读取当前影院的刮削结果") {
                    Button("重建") {
                        store.rebuildCinemaIndexCache()
                    }
                    .controlSize(.small)
                }
                settingToggle("导出 NFO",
                              detail: "刮削完成后把结果写到本地视频同目录，供 Jellyfin / Emby 读取",
                              isOn: $settings.cinemaExportNFO)
                settingRow("立即导出", detail: "只处理本地 / SMB 文件，网盘跳过") {
                    Button("导出当前影院") {
                        let count = store.exportCinemaNFOIfEnabled(for: store.cinemaActiveScope)
                        if count == 0 { store.showToast("没有可导出的本地影片，或导出未开启") }
                    }
                    .controlSize(.small)
                    .disabled(!settings.cinemaExportNFO)
                }
            }

            settingsGroup("维护", icon: "wrench.and.screwdriver") {
                settingRow("重新刮削全部", detail: "覆盖当前影院已识别的结果") {
                    Button {
                        store.startCinemaScrape(for: store.cinemaActiveScope, force: true)
                    } label: {
                        Label("重新刮削", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                }
                settingRow("清除刮削结果", detail: "只删本机索引，影片文件不受影响") {
                    Button("清除…") { pendingClear = .index }
                        .controlSize(.small)
                }
                settingRow("清除观看记录", detail: "清空继续观看与全部进度") {
                    Button("清除…") { pendingClear = .progress }
                        .controlSize(.small)
                }
                settingRow("清除自定义清单", detail: "收藏与想看不受影响") {
                    Button("清除…") { pendingClear = .lists }
                        .controlSize(.small)
                }
                settingRow("已忽略的视频", detail: "恢复后下次刮削会重新处理") {
                    Button("恢复（\(ignoredCount)）") {
                        store.restoreCinemaIgnored(for: store.cinemaActiveScope)
                    }
                    .controlSize(.small)
                    .disabled(ignoredCount == 0)
                }
                settingNote("危险操作都会二次确认；只删除本机索引 / 进度 / 清单，不删除影片文件。")
            }
        }
    }

    private var scopeTitle: String {
        switch store.cinemaActiveScope {
        case .local:
            return "本地图库影院"
        case .mount(let id):
            return store.cloudMounts.first(where: { $0.id == id })?.name ?? "网盘影院"
        }
    }

    private var scopeEntries: [CinemaEntry] {
        Array(store.cinemaEntries(for: store.cinemaActiveScope).values)
    }

    private var matchedCount: Int {
        scopeEntries.filter { $0.matched }.count
    }

    private var ignoredCount: Int {
        store.cinemaIgnoredIDs[store.cinemaActiveScope]?.count ?? 0
    }

    private func performClear(_ action: CinemaClearAction) {
        switch action {
        case .index:
            store.clearCinemaIndex(for: store.cinemaActiveScope)
        case .progress:
            store.clearCinemaProgress()
        case .lists:
            store.clearCinemaLists()
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LumaBrand.violet.opacity(0.16))
                Image(systemName: "film.stack")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LumaBrand.violet)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text("影院刮削")
                    .font(.system(size: 15, weight: .semibold))
                Text("按文件名匹配电影与剧集，补全海报、评分和简介。所有网盘共用同一套结果。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 数据源

    private func providerIcon(_ provider: CinemaProvider) -> String {
        switch provider {
        case .tmdb: return "globe.americas.fill"
        case .douban: return "text.book.closed.fill"
        case .tvdb: return "tv.fill"
        }
    }

    // MARK: 行为

    private var behaviorCard: some View {
        settingsGroup("行为", icon: "bolt.fill") {
            settingToggle("扫描完自动刮削",
                          detail: "网盘扫描结束后自动处理这个网盘的新视频",
                          isOn: $settings.cinemaAutoScrape)
            settingRow("刮削并发",
                       detail: "同时请求多个视频；网络较差时调低更稳") {
                Picker("", selection: $settings.cinemaScrapeConcurrency) {
                    ForEach(1...6, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            settingNote("刮削与播放入口在每个网盘的侧边栏「影院」里；结果和海报只属于那个网盘，互不影响。")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("只读取文件名，不会读取或上传视频内容；结果只保存在本机图库。",
                  systemImage: "lock.shield")
            Label("命名越规范越容易命中：电影名.2024.2160p.mkv、剧名.S01E02.1080p.mp4。",
                  systemImage: "textformat")
            Label("换数据源后旧结果不会自动变，点「重新刮削全部」覆盖即可。",
                  systemImage: "arrow.triangle.2.circlepath")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 组件

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }

    // MARK: 设置行（对齐「通用 / 外观」页的分组表单）

    /// 分组卡：小图标 + 标题（可带状态胶囊 / 右侧说明），下面是若干设置行。
    private func settingsGroup<Content: View>(_ title: String,
                                              icon: String,
                                              note: String? = nil,
                                              status: (text: String, ok: Bool)? = nil,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LumaBrand.violet)
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let status {
                    let color = status.ok ? Color.green : Color.orange
                    Text(status.text)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(color.opacity(0.12)))
                }
                Spacer(minLength: 0)
                if let note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 3)

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .frame(height: 0.6)
    }

    /// 一行设置：左侧标题与说明，右侧放控件（开关 / 选择器 / 按钮）。
    private func settingRow<Control: View>(_ title: String,
                                           detail: String? = nil,
                                           divider: Bool = true,
                                           @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.vertical, 7)
            if divider { rowDivider }
        }
    }

    private func settingToggle(_ title: String,
                               detail: String? = nil,
                               isOn: Binding<Bool>,
                               divider: Bool = true) -> some View {
        settingRow(title, detail: detail, divider: divider) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    /// 输入行：标题在上，整行输入框在下，和系统设置里的账号 / Key 项一致。
    private func settingField(_ title: String,
                              detail: String? = nil,
                              placeholder: String,
                              text: Binding<String>,
                              secure: Bool = false,
                              reveal: Binding<Bool>? = nil,
                              divider: Bool = true) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let reveal {
                        Button(reveal.wrappedValue ? "隐藏" : "显示") { reveal.wrappedValue.toggle() }
                            .buttonStyle(.link)
                            .font(.system(size: 10.5))
                    }
                }
                Group {
                    if secure, !(reveal?.wrappedValue ?? false) {
                        SecureField(placeholder, text: text)
                    } else {
                        TextField(placeholder, text: text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
            }
            .padding(.vertical, 7)
            if divider { rowDivider }
        }
    }

    /// 分组末尾的一行浅色说明。
    private func settingNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    private func settingActions<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private func open(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func paste(into binding: Binding<String>) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        binding.wrappedValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
