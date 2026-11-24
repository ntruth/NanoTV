import NanoCore
import NanoDesignSystem
import NanoScraper
import NanoVFS
import SwiftUI

// MARK: - 1. 网络存储中心视图（集成 115 / 夸克 / 百度 原生二维码生成与后台扫码轮询 + 点击直达真实目录树）

public struct StorageHubView: View {
    @Bindable public var appVM: NanoAppViewModel
    @State private var showAddStorageModal = false

    // 添加存储与实时扫码状态
    @State private var newName = ""
    @State private var newType: StorageSourceType = .drive115
    @State private var newEndpoint = "https://115.com"
    @State private var newOpenAPIClientID = ""
    @State private var newOpenAPIClientSecret = ""
    @State private var newOpenAPIToken = ""
    @State private var newUsername = ""
    @State private var newCookieOrPassword = ""
    @State private var markPrivate = false

    @State private var qrSession: CloudQRAuthSession?
    @State private var qrPollMessage: String = ""
    @State private var qrPollingTask: Task<Void, Never>?

    public init(appVM: NanoAppViewModel) {
        self.appVM = appVM
    }

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: NanoPalette.electricBlue) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("网络存储")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(NanoPalette.textPrimary)
                            Text("\(appVM.visibleStorageSources.count) 个已接入存储 · 点击卡片直接浏览真实目录树，支持方案 A (OpenAPI) 与方案 B (扫码直链) 双轨切换")
                                .font(.system(size: 13))
                                .foregroundStyle(NanoPalette.textSecondary)
                        }
                        Spacer()
                        Button {
                            resetForm(for: .drive115)
                            showAddStorageModal = true
                        } label: {
                            Label("接入存储 / 网盘扫码", systemImage: "qrcode.viewfinder")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(NanoPalette.electricBlue))
                        }
                        .buttonStyle(.plain)
                    }

                    let columns = [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 18)]
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(appVM.visibleStorageSources) { source in
                            storageCard(source)
                        }
                    }
                }
                .padding(26)
            }
        }
        .sheet(isPresented: $showAddStorageModal, onDismiss: {
            qrPollingTask?.cancel()
        }) {
            addStorageWithQRSheet
        }
    }

    private func storageCard(_ source: StorageSource) -> some View {
        NanoGlassCard(cornerRadius: 16, padding: 18) {
            appVM.selectedSection = .storageDetail(source.id)
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(NanoPalette.electricBlue.opacity(0.22))
                            .frame(width: 46, height: 46)
                        Image(systemName: source.type.iconSystemName)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(NanoPalette.electricBlue)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(NanoPalette.textPrimary)
                            .lineLimit(1)
                        Text(trackDescription(for: source))
                            .font(.system(size: 12))
                            .foregroundStyle(NanoPalette.textSecondary)
                    }

                    Spacer()

                    Text("已接入")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NanoPalette.onlineGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(NanoPalette.onlineGreen.opacity(0.15)))
                }

                // 若有网盘容量数据，展示剩余容量条
                if let used = source.quotaUsedBytes, let total = source.quotaTotalBytes, total > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("容量 \(DiskCacheQuotaManager.formatBytes(used)) / \(DiskCacheQuotaManager.formatBytes(total))")
                                .font(.system(size: 11))
                                .foregroundStyle(NanoPalette.textMuted)
                            Spacer()
                        }
                        NanoSegmentedQuotaBar(ratio: Double(used) / Double(total), tint: NanoPalette.electricBlue, totalSegments: 14)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 11))
                        Text(source.endpointURL)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundStyle(NanoPalette.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                }

                HStack {
                    Text("浏览目录文件树 ↗")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NanoPalette.textPrimary)
                    Spacer()
                    if let ms = source.latencyMs {
                        Text("\(ms) ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NanoPalette.onlineGreen)
                    }
                }
            }
        }
    }

    private func trackDescription(for source: StorageSource) -> String {
        switch source.activeTrackInUse {
        case .openAPISchemeA: return "\(source.type.displayName) · 方案A (OpenAPI)"
        case .cookieSchemeB: return "\(source.type.displayName) · 方案B (扫码直链)"
        default: return source.type.displayName
        }
    }

    private var addStorageWithQRSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("接入云盘 / NAS / 小雅存储")
                .font(.title3.bold())

            Picker("存储类型", selection: $newType) {
                ForEach(StorageSourceType.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .onChange(of: newType) { _, updated in
                resetForm(for: updated)
            }

            TextField("显示名称（例如：我的 115 影库 / 家庭群晖）", text: $newName)
                .textFieldStyle(.roundedBorder)

            if newType.supportsCookieSchemeB {
                // 网盘专属：实时生成二维码扫码区 + OpenAPI 方案 A 参数可选填写
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 10) {
                        if let session = qrSession {
                            NanoQRCodeView(content: session.qrCodeContentOrURL, size: 156)
                            if let hint = session.userCodeHint {
                                Text(hint)
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(width: 180, height: 180)
                                .overlay(
                                    Button("点击生成登录二维码") {
                                        startQRLoginFlow()
                                    }
                                    .buttonStyle(.borderedProminent)
                                )
                        }

                        Text(qrPollMessage.isEmpty ? "支持手机端 App 扫码自动抓回凭证" : qrPollMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(width: 185)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if newType.supportsOpenAPISchemeA {
                            Text("双轨策略：填写 ClientID 则优先走方案 A (OpenAPI)，留空则自动启用方案 B (TV/Web 扫码原画直链)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("可选：开放平台 AppKey / ClientID (方案 A)", text: $newOpenAPIClientID)
                                .textFieldStyle(.roundedBorder)
                            if newType == .baidu {
                                SecureField("可选：百度开放平台 SecretKey (方案 A)", text: $newOpenAPIClientSecret)
                                    .textFieldStyle(.roundedBorder)
                            }
                        } else {
                            Text("\(newType.displayName) 无官方个人直链 OpenAPI，已自动锁定「方案 B 扫码直链 + 本地流代理」")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Button("刷新二维码并开始轮询") {
                            startQRLoginFlow()
                        }
                        .buttonStyle(.bordered)

                        Divider()
                        Text("或手动粘贴已有 Token / Cookie：")
                            .font(.caption)
                        TextField("AccessToken (方案A)", text: $newOpenAPIToken)
                            .textFieldStyle(.roundedBorder)
                        TextField("Cookie 字符串 (方案B)", text: $newCookieOrPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } else {
                TextField("服务地址（例如 smb://192.168.1.5/Movies 或 http://192.168.1.10:5678）", text: $newEndpoint)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("用户名（可选，小雅留空）", text: $newUsername)
                        .textFieldStyle(.roundedBorder)
                    SecureField("密码 或 小雅 API Token", text: $newCookieOrPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Toggle("设为隐私加密存储（未解锁隐私空间时彻底隐藏）", isOn: $markPrivate)

            HStack {
                Spacer()
                Button("取消") {
                    qrPollingTask?.cancel()
                    showAddStorageModal = false
                }
                Button("保存并挂载") {
                    qrPollingTask?.cancel()
                    appVM.addStorageSource(
                        name: newName.isEmpty ? newType.displayName : newName,
                        type: newType,
                        endpoint: newEndpoint,
                        username: newUsername,
                        openAPIToken: newOpenAPIToken,
                        cookieOrSecret: newCookieOrPassword,
                        isPrivate: markPrivate
                    )
                    showAddStorageModal = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 590)
    }

    private func resetForm(for type: StorageSourceType) {
        qrPollingTask?.cancel()
        qrSession = nil
        qrPollMessage = ""
        switch type {
        case .drive115: newEndpoint = "https://115.com"
        case .quark: newEndpoint = "https://pan.quark.cn"
        case .baidu: newEndpoint = "https://pan.baidu.com"
        case .aliyun: newEndpoint = "https://www.alipan.com"
        case .xiaoyaOpenList: newEndpoint = "http://127.0.0.1:5678"
        case .smb: newEndpoint = "smb://DiskStation/Video"
        case .webdav: newEndpoint = "http://127.0.0.1:5244/dav"
        default: newEndpoint = "http://127.0.0.1:8096"
        }
    }

    private func startQRLoginFlow() {
        qrPollingTask?.cancel()
        qrPollMessage = "正在请求二维码会话..."
        let targetType = newType
        let cid = newOpenAPIClientID
        let csec = newOpenAPIClientSecret

        qrPollingTask = Task {
            do {
                let session = try await CloudQRLoginService.shared.createQRSession(
                    for: targetType,
                    openAPIClientID: cid.isEmpty ? nil : cid,
                    openAPIClientSecret: csec.isEmpty ? nil : csec
                )
                await MainActor.run {
                    self.qrSession = session
                    let modeName = (session.resolvedTrack == .openAPISchemeA) ? "方案 A (OpenAPI)" : "方案 B (扫码 Cookie)"
                    self.qrPollMessage = "请使用手机 \(targetType.displayName) App 扫码 [\(modeName)]"
                }

                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_200_000_000)
                    let state = try await CloudQRLoginService.shared.pollQRStatus(sessionID: session.sessionID)
                    switch state {
                    case .waitingScan:
                        break
                    case .scannedPendingConfirm:
                        await MainActor.run {
                            self.qrPollMessage = "已扫码！请在手机屏幕上点击「确认登录」"
                        }
                    case .authorized(let payload, let track):
                        await MainActor.run {
                            if track == .openAPISchemeA {
                                self.newOpenAPIToken = payload
                            } else {
                                self.newCookieOrPassword = payload
                            }
                            self.qrPollMessage = "扫码授权成功！凭证已自动填入，点击右下角保存即可"
                        }
                        return
                    case .expiredOrFailed(let reason):
                        await MainActor.run {
                            self.qrPollMessage = reason
                        }
                        return
                    }
                }
            } catch {
                await MainActor.run {
                    self.qrPollMessage = "二维码获取失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 2. 整面影院海报墙网格页（支持电影/剧集/4K筛选 + TMDB Key 配置 + 点击直达详情页）

public enum CinemaWallFilter: String, CaseIterable, Hashable {
    case all = "全部"
    case movies = "电影"
    case series = "剧集"
    case hdr4K = "4K / HDR"
}

public struct CinemaPosterWallView: View {
    @Bindable public var appVM: NanoAppViewModel
    @State private var activeFilter: CinemaWallFilter = .all
    @State private var facetFilter = MediaCategoryFilterState()
    @State private var showMultiCategoryDrawer: Bool = true
    @State private var searchTitle: String = ""
    @State private var showTMDBSettings: Bool = false

    public init(appVM: NanoAppViewModel) {
        self.appVM = appVM
    }

    private var filteredMedia: [MediaItem] {
        let matched = appVM.visibleMediaItems.filter { item in
            if !searchTitle.isEmpty && !item.title.localizedCaseInsensitiveContains(searchTitle) {
                return false
            }
            switch activeFilter {
            case .all: break
            case .movies: if item.kind != .movie { return false }
            case .series: if item.kind != .tvSeries { return false }
            case .hdr4K: if item.spec.resolution != "4K" && item.spec.dynamicRange == "SDR" { return false }
            }
            return facetFilter.matches(item)
        }

        switch facetFilter.sortOrder {
        case .recentlyAdded:
            return matched
        case .highestRating:
            return matched.sorted { $0.rating > $1.rating }
        case .newestRelease:
            return matched.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .titleAZ:
            return matched.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    private var pillItems: [NanoPillTabItem<CinemaWallFilter>] {
        [
            NanoPillTabItem(id: .all, title: "全部", systemIcon: "film.stack", badgeCount: appVM.visibleMediaItems.count),
            NanoPillTabItem(id: .movies, title: "电影", systemIcon: "film"),
            NanoPillTabItem(id: .series, title: "剧集", systemIcon: "tv"),
            NanoPillTabItem(id: .hdr4K, title: "4K HDR", systemIcon: "sparkles.tv")
        ]
    }

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: NanoPalette.amberGold) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("影院海报墙")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(NanoPalette.textPrimary)
                            Text("支持按题材、国家地区、年份、画质规格与评分多维组合分类筛选")
                                .font(.system(size: 13))
                                .foregroundStyle(NanoPalette.textSecondary)
                        }
                        Spacer()
                        NanoFloatingPillBar(items: pillItems, selection: $activeFilter)
                    }

                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(NanoPalette.textMuted)
                            TextField("筛选海报墙片名...", text: $searchTitle)
                                .textFieldStyle(.plain)
                                .foregroundStyle(NanoPalette.textPrimary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .frame(maxWidth: 300)

                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                showMultiCategoryDrawer.toggle()
                            }
                        } label: {
                            Label(showMultiCategoryDrawer ? "收起分类筛选" : "展开分类筛选", systemImage: "line.3.horizontal.decrease.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(NanoPalette.amberGold)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(NanoPalette.amberGold.opacity(0.15)))
                        }
                        .buttonStyle(.plain)

                        if !facetFilter.isDefault {
                            Button("重置分类") {
                                facetFilter.resetAll()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(NanoPalette.electricBlue)
                        }

                        Spacer()

                        Button {
                            showTMDBSettings = true
                        } label: {
                            Label("刮削器 TMDB API 配置", systemImage: "gearshape.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(NanoPalette.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }

                    // 多维分类胶囊筛选面板（题材 / 地区 / 年份 / 画质 / 排序）
                    if showMultiCategoryDrawer {
                        NanoGlassCard(cornerRadius: 14, padding: 14) {
                            VStack(alignment: .leading, spacing: 10) {
                                categoryFacetRow(
                                    label: "题材",
                                    options: ["全部", "剧情", "喜剧", "动作", "科幻", "冒险", "悬疑", "纪录片"],
                                    selection: $facetFilter.genreFilter
                                )
                                categoryFacetRow(
                                    label: "地区",
                                    options: ["全部", "中国", "香港", "台湾", "美国", "日本", "韩国", "英国"],
                                    selection: $facetFilter.regionFilter
                                )
                                categoryFacetRow(
                                    label: "年份",
                                    options: ["全部", "2026", "2025", "2024", "更早"],
                                    selection: $facetFilter.yearFilter
                                )
                                categoryFacetRow(
                                    label: "规格",
                                    options: ["全部", "4K", "Dolby Vision", "HDR", "60 fps"],
                                    selection: $facetFilter.qualityFilter
                                )
                                HStack(spacing: 10) {
                                    Text("排序")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(NanoPalette.textMuted)
                                        .frame(width: 38, alignment: .leading)
                                    ForEach(MediaSortOrder.allCases) { order in
                                        let isSel = (facetFilter.sortOrder == order)
                                        Button {
                                            facetFilter.sortOrder = order
                                        } label: {
                                            Text(order.rawValue)
                                                .font(.system(size: 12, weight: isSel ? .bold : .medium))
                                                .foregroundStyle(isSel ? .black : NanoPalette.textSecondary)
                                                .padding(.horizontal, 11)
                                                .padding(.vertical, 5)
                                                .background(Capsule().fill(isSel ? NanoPalette.amberGold : Color.white.opacity(0.05)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    let columns = [GridItem(.adaptive(minimum: 175, maximum: 215), spacing: 20)]
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(filteredMedia) { item in
                            posterCard(item)
                        }
                    }
                }
                .padding(26)
            }
        }
        .sheet(isPresented: $showTMDBSettings) {
            VStack(alignment: .leading, spacing: 14) {
                Text("配置 TMDB API Key（用于在线拉取高清海报与演职员头像）")
                    .font(.headline)
                TextField("粘贴 TMDB v3 API Key", text: $appVM.tmdbAPIKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("完成保存") { showTMDBSettings = false }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(minWidth: 440)
        }
    }

    private func categoryFacetRow(label: String, options: [String], selection: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NanoPalette.textMuted)
                    .frame(width: 38, alignment: .leading)

                ForEach(options, id: \.self) { opt in
                    let isSel = (selection.wrappedValue == opt)
                    Button {
                        selection.wrappedValue = opt
                    } label: {
                        Text(opt)
                            .font(.system(size: 12, weight: isSel ? .bold : .medium))
                            .foregroundStyle(isSel ? .white : NanoPalette.textSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(isSel ? NanoPalette.electricBlue : Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func posterCard(_ item: MediaItem) -> some View {
        NanoGlassCard(cornerRadius: 14, padding: 10) {
            appVM.selectedSection = .cinemaDetail(item.id)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    if let urlStr = item.posterURL, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                fallbackPosterArtwork(item)
                            }
                        }
                        .frame(height: 245)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        fallbackPosterArtwork(item)
                            .frame(height: 245)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Text("\(item.spec.resolution) · \(item.spec.dynamicRange)")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(NanoPalette.amberGold))
                        .padding(8)
                }

                Text(item.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NanoPalette.textPrimary)
                    .lineLimit(1)

                HStack {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(NanoPalette.amberGold)
                        Text(item.rating > 0 ? String(format: "%.1f", item.rating) : "新入库")
                    }
                    Spacer()
                    Text(item.kind == .tvSeries ? "共\(item.totalEpisodes)集" : (item.year.map(String.init) ?? ""))
                        .foregroundStyle(NanoPalette.textMuted)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NanoPalette.textSecondary)
            }
        }
    }

    private func fallbackPosterArtwork(_ item: MediaItem) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.22, green: 0.28, blue: 0.45), Color(red: 0.08, green: 0.11, blue: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                Image(systemName: item.kind == .tvSeries ? "tv.fill" : "film.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(NanoPalette.amberGold)
                Text(item.title)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
    }
}

// MARK: - 3. 沉浸式影院详情页（含手动搜词重新刮削匹配弹窗与真实 VFS 流解析播放）

public struct CinemaDetailView: View {
    @Bindable public var appVM: NanoAppViewModel
    public let mediaID: UUID

    @State private var showManualRematchSheet: Bool = false
    @State private var manualQueryText: String = ""
    @State private var tmdbCandidates: [MediaItem] = []
    @State private var isSearchingTMDB: Bool = false

    public init(appVM: NanoAppViewModel, mediaID: UUID) {
        self.appVM = appVM
        self.mediaID = mediaID
    }

    private var media: MediaItem {
        appVM.mediaItems.first(where: { $0.id == mediaID }) ?? appVM.mediaItems[0]
    }

    private var episodes: [MediaEpisode] {
        appVM.episodesByMediaID[media.id] ?? []
    }

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: NanoPalette.amberGold) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // 顶部悬浮操作胶囊条（返回海报墙 | TMDB 编号 | 手动重刮削按钮）
                    HStack(spacing: 12) {
                        Button {
                            appVM.selectedSection = .cinemaWall
                        } label: {
                            Label("返回海报墙", systemImage: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(NanoPalette.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)

                        Button {
                            manualQueryText = media.title
                            showManualRematchSheet = true
                        } label: {
                            Label("刮削修正", systemImage: "wand.and.stars")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(NanoPalette.amberGold)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(NanoPalette.amberGold.opacity(0.16)))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        if media.isCompleted {
                            Text("● 已完结")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(NanoPalette.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                    }

                    // 主视觉档案区
                    HStack(alignment: .top, spacing: 28) {
                        VStack(spacing: 10) {
                            ZStack {
                                if let pURL = media.posterURL, let url = URL(string: pURL) {
                                    AsyncImage(url: url) { phase in
                                        if case .success(let img) = phase {
                                            img.resizable().scaledToFill()
                                        } else {
                                            defaultDetailPoster
                                        }
                                    }
                                } else {
                                    defaultDetailPoster
                                }
                            }
                            .frame(width: 190, height: 270)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))

                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(NanoPalette.amberGold)
                                Text(String(format: "%.1f", media.rating))
                                    .fontWeight(.bold)
                                Text("· \(media.voteCount)人评分")
                                    .foregroundStyle(NanoPalette.textMuted)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(NanoPalette.textPrimary)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            Text("剧集档案  —  \(media.year ?? 2026) · \(media.seasonCount) 季 · \(media.totalEpisodes) 集")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(NanoPalette.amberGold)

                            Text(media.title)
                                .font(.system(size: 34, weight: .heavy))
                                .foregroundStyle(.white)

                            HStack(spacing: 12) {
                                let resumeEp = episodes.first(where: { $0.watchedPositionSec > 0 }) ?? episodes.first
                                Button {
                                    if let ep = resumeEp { playEpisode(ep) }
                                } label: {
                                    Label("继续播放 \(resumeEp?.code ?? "S01E01")", systemImage: "play.fill")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 10)
                                        .background(Capsule().fill(NanoPalette.amberGold))
                                }
                                .buttonStyle(.plain)

                                secondaryActionPill(title: "从第 1 集开始", icon: "backward.end.fill") {
                                    if let first = episodes.first { playEpisode(first) }
                                }

                                secondaryActionPill(title: "跳过片头尾  片头 \(media.introSkipSec)s", icon: "scissors") {
                                    if let idx = appVM.mediaItems.firstIndex(where: { $0.id == media.id }) {
                                        let nextVal = (media.introSkipSec == 0) ? 90 : ((media.introSkipSec == 90) ? 114 : 0)
                                        appVM.mediaItems[idx].introSkipSec = nextVal
                                    }
                                }
                            }

                            // Infuse Pro 特性：同片多存储源/多清晰度版本一键切换胶囊
                            if let editions = appVM.editionsByMediaID[media.id], !editions.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("多版本切换 (Infuse Pro Editions)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(NanoPalette.electricBlue)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 10) {
                                            ForEach(editions) { ed in
                                                Button {
                                                    Task { await appVM.playEditionVariant(ed, parentMedia: media) }
                                                } label: {
                                                    HStack(spacing: 6) {
                                                        Image(systemName: "play.square.fill")
                                                            .foregroundStyle(NanoPalette.amberGold)
                                                        Text("[\(ed.sourceName)] \(ed.editionLabel)")
                                                            .font(.system(size: 12, weight: .semibold))
                                                            .foregroundStyle(NanoPalette.textPrimary)
                                                    }
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 7)
                                                    .background(
                                                        Capsule()
                                                            .fill(Color.white.opacity(0.08))
                                                            .overlay(Capsule().strokeBorder(NanoPalette.electricBlue.opacity(0.5), lineWidth: 1))
                                                    )
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }

                            Text(media.overview)
                                .font(.system(size: 14))
                                .foregroundStyle(NanoPalette.textSecondary)
                                .lineSpacing(4)

                            let metaColumns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 12)]
                            LazyVGrid(columns: metaColumns, alignment: .leading, spacing: 14) {
                                specMetaCell(label: "首播", value: media.releaseDate)
                                specMetaCell(label: "季数 / 集数", value: "\(media.seasonCount) 季 · \(media.totalEpisodes) 集")
                                specMetaCell(label: "HDR 动态范围", value: media.spec.dynamicRange)
                                specMetaCell(label: "帧率 / 分辨率", value: "\(media.spec.resolution) · \(media.spec.frameRate)")
                                specMetaCell(label: "类型", value: media.genres.joined(separator: " / "))
                                specMetaCell(label: "语言 / 国家", value: "\(media.language) · \(media.country)")
                                specMetaCell(label: "出品平台", value: media.networkOrStudio)
                                specMetaCell(label: "TMDB ID", value: "#\(media.tmdbID ?? 0)")
                            }
                            .padding(.top, 4)
                        }
                    }

                    if !media.cast.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("| 演职员")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(NanoPalette.textPrimary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 22) {
                                    ForEach(media.cast) { actor in
                                        VStack(spacing: 8) {
                                            Circle()
                                                .fill(Color.white.opacity(0.10))
                                                .frame(width: 72, height: 72)
                                                .overlay(
                                                    Text(String(actor.name.prefix(1)))
                                                        .font(.system(size: 24, weight: .bold))
                                                        .foregroundStyle(NanoPalette.amberGold)
                                                )
                                                .overlay(Circle().strokeBorder(NanoPalette.subtleBorder, lineWidth: 1))
                                            Text(actor.name)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(NanoPalette.textPrimary)
                                            Text(actor.character)
                                                .font(.system(size: 11))
                                                .foregroundStyle(NanoPalette.textMuted)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("| 剧集列表  共 \(episodes.count) 个关联文件")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(NanoPalette.textPrimary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(episodes) { ep in
                                    episodeCard(ep)
                                }
                            }
                        }
                    }
                }
                .padding(28)
            }
        }
        .sheet(isPresented: $showManualRematchSheet) {
            manualRematchScraperSheet
        }
    }

    private var defaultDetailPoster: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.72, green: 0.24, blue: 0.14), Color(red: 0.20, green: 0.12, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                Image(systemName: "film.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(NanoPalette.amberGold)
                Text(media.title)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var manualRematchScraperSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("手动搜索 TMDB 修正刮削元数据")
                .font(.headline)

            HStack {
                TextField("输入正确片名关键词...", text: $manualQueryText)
                    .textFieldStyle(.roundedBorder)
                Button(isSearchingTMDB ? "搜索中..." : "搜索 TMDB") {
                    isSearchingTMDB = true
                    let q = manualQueryText
                    let key = appVM.tmdbAPIKey
                    Task {
                        let engine = MediaScraperEngine(tmdbAPIKey: key)
                        let res = (try? await engine.searchTMDB(query: q)) ?? []
                        await MainActor.run {
                            self.tmdbCandidates = res
                            self.isSearchingTMDB = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            if appVM.tmdbAPIKey.isEmpty {
                Text("提示：请先在「影院海报墙 -> 刮削器 TMDB API 配置」中填入 TMDB API Key。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tmdbCandidates) { cand in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(cand.title) (\(cand.releaseDate.prefix(4)))")
                                    .font(.subheadline.bold())
                                Text(cand.overview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button("应用此档案") {
                                appVM.applyRematchedMetadata(targetMediaID: media.id, newTemplate: cand)
                                showManualRematchSheet = false
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(8)
                    }
                }
            }
            .frame(height: 220)

            HStack {
                Spacer()
                Button("关闭") { showManualRematchSheet = false }
            }
        }
        .padding(24)
        .frame(minWidth: 520)
    }

    private func secondaryActionPill(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NanoPalette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .overlay(Capsule().strokeBorder(NanoPalette.subtleBorder, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    private func specMetaCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(NanoPalette.textMuted)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NanoPalette.textPrimary)
                .lineLimit(1)
        }
    }

    private func episodeCard(_ ep: MediaEpisode) -> some View {
        NanoGlassCard(cornerRadius: 12, padding: 12) {
            playEpisode(ep)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 240, height: 132)
                        .overlay(
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white.opacity(0.85))
                        )

                    Text(ep.code)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.72)))
                        .padding(8)
                }

                HStack(spacing: 6) {
                    Text(ep.code)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(NanoPalette.amberGold)
                    if ep.watchedPercentage > 0 {
                        Text("上次看到 \(ep.watchedPercentage)%")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(NanoPalette.amberGold))
                    } else {
                        Text("未看")
                            .font(.system(size: 11))
                            .foregroundStyle(NanoPalette.textMuted)
                    }
                    Spacer()
                    Text(ep.remainingMinutesText)
                        .font(.system(size: 11))
                        .foregroundStyle(NanoPalette.textMuted)
                }

                Text(ep.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NanoPalette.textPrimary)
                    .lineLimit(1)

                Text(ep.overview)
                    .font(.system(size: 12))
                    .foregroundStyle(NanoPalette.textSecondary)
                    .lineLimit(2)
                    .frame(width: 240, alignment: .leading)
            }
        }
    }

    private func playEpisode(_ ep: MediaEpisode) {
        Task {
            await appVM.playCinemaEpisode(ep, parentMedia: media)
        }
    }
}
