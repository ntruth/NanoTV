import NanoCore
import NanoDesignSystem
import NanoRemoteHub
import SwiftUI

public enum RemoteHubSubTab: String, CaseIterable, Hashable {
    case resources = "资源"
    case ranking = "榜单"
    case calendar = "日历"
    case footprints = "足迹"
    case playlists = "片单"
    case following = "关注"
}

/// 网络资源聚合仪表盘（1:1 复刻参考图6：圆环联网表 + 6维数据卡 + 分段缓存配额条 + 三引擎健康列表）
public struct RemoteResourceHubView: View {
    @Bindable public var appVM: NanoAppViewModel

    @State private var activeTab: RemoteHubSubTab = .resources
    @State private var globalSearchText: String = ""
    @State private var searchResults: [RemoteVodEntry] = []
    @State private var isSearching: Bool = false
    @State private var showImportRuleModal: Bool = false

    // 导入三类引擎配置状态
    @State private var newSiteName: String = ""
    @State private var newSiteEngine: RemoteSiteEngineType = .macCMSJson
    @State private var newSitePayload: String = ""
    @State private var newSitePrivate: Bool = false

    public init(appVM: NanoAppViewModel) {
        self.appVM = appVM
    }

    private var pillTabs: [NanoPillTabItem<RemoteHubSubTab>] {
        [
            NanoPillTabItem(id: .resources, title: "资源", systemIcon: "square.grid.2x2.fill"),
            NanoPillTabItem(id: .ranking, title: "榜单", systemIcon: "chart.bar.fill", badgeCount: 24),
            NanoPillTabItem(id: .calendar, title: "日历", systemIcon: "calendar", badgeCount: 24),
            NanoPillTabItem(id: .footprints, title: "足迹", systemIcon: "clock.fill", badgeCount: 54),
            NanoPillTabItem(id: .playlists, title: "片单", systemIcon: "rectangle.stack.fill", badgeCount: 4),
            NanoPillTabItem(id: .following, title: "关注", systemIcon: "heart.fill", badgeCount: 7)
        ]
    }

    private var onlineCount: Int {
        appVM.visibleRemoteSites.filter { $0.healthStatus == .online }.count
    }

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: NanoPalette.electricBlue) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 顶部导航栏
                    HStack {
                        Text("网络资源")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(NanoPalette.textPrimary)
                        Spacer()
                        NanoFloatingPillBar(items: pillTabs, selection: $activeTab)
                    }

                    // 上半部：资源统计大面板
                    NanoGlassCard(cornerRadius: 18, padding: 20) {
                        VStack(spacing: 18) {
                            HStack {
                                Label("资源统计  \(appVM.visibleRemoteSites.count) 个资源 · 支持 CMS JSON / FongMi / 网页爬虫规则", systemImage: "info.circle")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(NanoPalette.textSecondary)
                                Spacer()
                                Button {
                                    Task { await appVM.runAllRemoteSitesHealthCheck() }
                                } label: {
                                    Label("检测全部", systemImage: "dot.radiowaves.left.and.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(NanoPalette.textPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(Color.white.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                            }

                            HStack(spacing: 22) {
                                // 1. 左侧刻度圆环联网表
                                connectivityGaugeView
                                    .frame(width: 145)

                                // 2. 中部 6 宫格指标卡
                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                    metricMiniCard(title: "分类总数", value: "\(appVM.visibleRemoteSites.reduce(0) { $0 + $1.categoryCount })", icon: "folder.fill", tint: NanoPalette.electricBlue)
                                    metricMiniCard(title: "更新记录", value: "2400", icon: "sparkles", tint: NanoPalette.onlineGreen)
                                    metricMiniCard(title: "跨源续看", value: "\(appVM.visibleRemoteSites.reduce(0) { $0 + $1.continueWatchCount })", icon: "play.circle.fill", tint: NanoPalette.amberGold)
                                    metricMiniCard(title: "稍后看", value: "0", icon: "bookmark.fill", tint: NanoPalette.textSecondary)
                                    metricMiniCard(title: "关注专题", value: "7", icon: "star.circle.fill", tint: NanoPalette.onlineGreen)
                                    metricMiniCard(title: "自建片单", value: "4", icon: "film.stack.fill", tint: NanoPalette.electricBlue)
                                }

                                // 3. 右侧磁盘缓存上限管家（海报缓存 & 视频缓存分段进度条）
                                cacheQuotaPanel
                                    .frame(width: 265)
                            }

                            // 全局聚合搜索条
                            HStack(spacing: 12) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(NanoPalette.textMuted)
                                TextField("在所有启用资源里并发搜索... 片名 / 演员 / 题材", text: $globalSearchText)
                                    .textFieldStyle(.plain)
                                    .foregroundStyle(NanoPalette.textPrimary)
                                    .onSubmit {
                                        triggerAggregateSearch()
                                    }
                                Button {
                                    triggerAggregateSearch()
                                } label: {
                                    Text(isSearching ? "搜索中..." : "搜索")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(NanoPalette.electricBlue))
                                }
                                .buttonStyle(.plain)

                                Text("\(appVM.visibleRemoteSites.filter(\.isSearchable).count) 个源参与搜索")
                                    .font(.system(size: 11))
                                    .foregroundStyle(NanoPalette.textMuted)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black.opacity(0.28))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NanoPalette.subtleBorder, lineWidth: 1))
                            )
                        }
                    }

                    // 若有搜索结果则展示跨源聚合结果
                    if !searchResults.isEmpty {
                        NanoGlassCard(cornerRadius: 16, padding: 16) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("跨源搜索结果（共 \(searchResults.count) 条）")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(NanoPalette.textPrimary)
                                ForEach(searchResults) { vod in
                                    HStack {
                                        Text("[\(vod.siteName)]")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(NanoPalette.amberGold)
                                        Text(vod.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(NanoPalette.textPrimary)
                                        Text(vod.remarks)
                                            .font(.system(size: 12))
                                            .foregroundStyle(NanoPalette.textSecondary)
                                        Spacer()
                                        if let firstEp = vod.playRoutes.first?.episodes.first,
                                           let streamURL = URL(string: firstEp.url) {
                                            Button("立即播放") {
                                                let ticket = PlayableStreamTicket(title: vod.title, subtitle: "\(vod.siteName) · \(firstEp.title)", streamURL: streamURL)
                                                Task {
                                                    await appVM.player.startPlayback(ticket: ticket)
                                                    appVM.isPresentingFullPlayer = true
                                                }
                                            }
                                            .buttonStyle(.borderedProminent)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }

                    // 下半部：资源管理列表（对齐参考图6）
                    NanoGlassCard(cornerRadius: 18, padding: 20) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("资源管理")
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundStyle(NanoPalette.textPrimary)
                                    Text("\(appVM.visibleRemoteSites.count) 个资源 · 在线 \(onlineCount)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(NanoPalette.textMuted)
                                }
                                Spacer()
                                Button {
                                    appVM.cacheManager.clearPosterCache()
                                } label: {
                                    Text("清理海报")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(NanoPalette.textSecondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(Color.white.opacity(0.06)))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    appVM.cacheManager.clearVideoCache()
                                } label: {
                                    Text("清理视频")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(NanoPalette.textSecondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(Color.white.opacity(0.06)))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    showImportRuleModal = true
                                } label: {
                                    Label("导入资源", systemImage: "plus")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(NanoPalette.electricBlue))
                                }
                                .buttonStyle(.plain)
                            }

                            VStack(spacing: 10) {
                                ForEach(appVM.visibleRemoteSites) { site in
                                    remoteSiteRow(site)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .sheet(isPresented: $showImportRuleModal) {
            importRemoteSiteSheet
        }
    }

    private var connectivityGaugeView: some View {
        let total = max(1, appVM.visibleRemoteSites.count)
        let ratio = Double(onlineCount) / Double(total)
        return VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 10, dash: [3, 4]))
                    .frame(width: 108, height: 108)
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(NanoPalette.amberGold, style: StrokeStyle(lineWidth: 10, lineCap: .round, dash: [3, 4]))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 108, height: 108)
                VStack(spacing: 2) {
                    Text("\(onlineCount)/\(appVM.visibleRemoteSites.count)")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("已连接")
                        .font(.system(size: 11))
                        .foregroundStyle(NanoPalette.textMuted)
                }
            }
            Text("联网状态")
                .font(.system(size: 12))
                .foregroundStyle(NanoPalette.textSecondary)
        }
    }

    private func metricMiniCard(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(NanoPalette.textSecondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }

    private var cacheQuotaPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("缓存占用")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NanoPalette.textSecondary)
                Spacer()
                Text("LRU 自动守护")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NanoPalette.electricBlue)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("海报")
                        .font(.system(size: 12))
                        .foregroundStyle(NanoPalette.textSecondary)
                    Spacer()
                    Text(DiskCacheQuotaManager.formatBytes(appVM.cacheManager.posterUsedBytes))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                NanoSegmentedQuotaBar(ratio: appVM.cacheManager.posterUsageRatio, tint: NanoPalette.onlineGreen)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("视频")
                        .font(.system(size: 12))
                        .foregroundStyle(NanoPalette.textSecondary)
                    Spacer()
                    Text(DiskCacheQuotaManager.formatBytes(appVM.cacheManager.videoUsedBytes))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                NanoSegmentedQuotaBar(ratio: appVM.cacheManager.videoUsageRatio, tint: Color.pink.opacity(0.85))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }

    private func remoteSiteRow(_ site: RemoteResourceSite) -> some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(NanoPalette.electricBlue.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: "bolt.shield.fill")
                    .foregroundStyle(NanoPalette.electricBlue)
            }

            VStack(alignment: .leading, spacing: 3) {
                Button {
                    appVM.selectedSection = .remoteSiteDetail(site.id)
                } label: {
                    HStack(spacing: 5) {
                        Text(site.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(NanoPalette.textPrimary)
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                            .foregroundStyle(NanoPalette.electricBlue)
                    }
                }
                .buttonStyle(.plain)

                Text("\(site.name) (\(site.engineType.badgeTitle)) · 点击浏览分类片库")
                    .font(.system(size: 11))
                    .foregroundStyle(NanoPalette.textMuted)
            }

            Spacer()

            // 在线/需验证状态指示器
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor(site.healthStatus))
                    .frame(width: 7, height: 7)
                Text(statusLabel(site.healthStatus))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor(site.healthStatus))
            }
            .frame(width: 76, alignment: .leading)

            Text(site.latencyMs.map { "\($0) ms" } ?? "-- ms")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(NanoPalette.textSecondary)
                .frame(width: 72, alignment: .trailing)

            Text("\(site.categoryCount) 频道")
                .font(.system(size: 12))
                .foregroundStyle(NanoPalette.textMuted)
                .frame(width: 64, alignment: .trailing)

            Text(DiskCacheQuotaManager.formatBytes(site.cachedPosterBytes))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(NanoPalette.textMuted)
                .frame(width: 80, alignment: .trailing)

            Button {
                if let idx = appVM.remoteSites.firstIndex(where: { $0.id == site.id }) {
                    appVM.remoteSites[idx].isEnabled.toggle()
                }
            } label: {
                Text(site.isEnabled ? "● 启用" : "○ 停用")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(site.isEnabled ? NanoPalette.onlineGreen : NanoPalette.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
    }

    private var importRemoteSiteSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入网络资源（支持 CMS JSON / TVBox FongMi 订阅 / 自定义网页爬虫规则）")
                .font(.headline)

            Picker("规则引擎类型", selection: $newSiteEngine) {
                Text("标准苹果 CMS JSON 接口").tag(RemoteSiteEngineType.macCMSJson)
                Text("TVBox / FongMi JSON 订阅包").tag(RemoteSiteEngineType.fongMiTVBox)
                Text("自定义网页爬虫规则 JSON").tag(RemoteSiteEngineType.customWebRule)
            }

            TextField("站点备注名称", text: $newSiteName)
                .textFieldStyle(.roundedBorder)

            TextField("粘贴接口 URL、FongMi 订阅链接或网页规则 JSON", text: $newSitePayload)
                .textFieldStyle(.roundedBorder)

            Toggle("归入隐私加密分区（未解锁隐私空间时完全隐藏）", isOn: $newSitePrivate)

            HStack {
                Spacer()
                Button("取消") { showImportRuleModal = false }
                Button("立即导入") {
                    let payload = newSitePayload
                    let name = newSiteName.isEmpty ? "新建扩展源" : newSiteName
                    let engine = newSiteEngine
                    let priv = newSitePrivate
                    showImportRuleModal = false
                    Task {
                        await appVM.importRemoteResourceConfig(payload, customName: name, engine: engine, isPrivate: priv)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 520)
    }

    private func triggerAggregateSearch() {
        guard !globalSearchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        let kw = globalSearchText
        Task {
            let found = await RemoteResourceEngineHub.searchAcrossEnabledSites(keyword: kw, sites: appVM.visibleRemoteSites)
            await MainActor.run {
                self.searchResults = found
                self.isSearching = false
            }
        }
    }

    private func statusColor(_ status: RemoteSiteHealthStatus) -> Color {
        switch status {
        case .online: return NanoPalette.onlineGreen
        case .requireVerify: return NanoPalette.warningAmber
        case .checking: return NanoPalette.electricBlue
        case .offline: return NanoPalette.liveRed
        }
    }

    private func statusLabel(_ status: RemoteSiteHealthStatus) -> String {
        switch status {
        case .online: return "在线"
        case .requireVerify: return "需验证"
        case .checking: return "检测中"
        case .offline: return "离线"
        }
    }
}
