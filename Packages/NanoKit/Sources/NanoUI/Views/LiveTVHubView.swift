import NanoCore
import NanoDesignSystem
import NanoLiveTV
import SwiftUI

public enum LiveTVSubTab: String, CaseIterable, Hashable {
    case live = "直播"
    case epg = "节目单"
    case catchup = "回看"
    case signal = "信号"
    case sources = "源库"
}

/// 网络电视全功能中心（阶段三 V0.3 完整版：直播网格 + 全频电子节目单 + 多日回看时间轴 + 并发信号探针清理 + 多订阅源库管理）
public struct LiveTVHubView: View {
    @Bindable public var appVM: NanoAppViewModel
    public var forcedCategory: String?

    @State private var activeTab: LiveTVSubTab = .live
    @State private var dimensionByProvince: Bool = false
    @State private var selectedCategory: String = "全部"
    @State private var selectedCatchupDayOffset: Int = 0
    @State private var selectedCatchupChannelStdName: String = "CCTV4K"
    @State private var isProbingSignal: Bool = false

    // 新增订阅源弹窗状态
    @State private var showAddSubscriptionSheet: Bool = false
    @State private var subName: String = ""
    @State private var subM3UURL: String = ""
    @State private var subEPGURL: String = ""
    @State private var subUA: String = ""

    public init(appVM: NanoAppViewModel, forcedCategory: String? = nil) {
        self.appVM = appVM
        self.forcedCategory = forcedCategory
    }

    private var pillItems: [NanoPillTabItem<LiveTVSubTab>] {
        [
            NanoPillTabItem(id: .live, title: "直播", systemIcon: "play.tv", badgeCount: appVM.liveChannels.count),
            NanoPillTabItem(id: .epg, title: "节目单", systemIcon: "calendar.day.timeline.left"),
            NanoPillTabItem(id: .catchup, title: "回看", systemIcon: "clock.arrow.circlepath", badgeCount: appVM.liveChannels.filter(\.supportsCatchup).count),
            NanoPillTabItem(id: .signal, title: "信号", systemIcon: "bolt.horizontal.circle"),
            NanoPillTabItem(id: .sources, title: "源库", systemIcon: "tray.full", badgeCount: appVM.iptvSubscriptions.count)
        ]
    }

    private var filteredChannels: [IPTVChannelGroup] {
        let targetCat = forcedCategory ?? selectedCategory
        return appVM.liveChannels.filter { ch in
            if targetCat == "全部" { return true }
            if targetCat == "收藏" { return ch.isFavorite }
            if dimensionByProvince {
                return ch.province == targetCat
            }
            return ch.category == targetCat
        }
    }

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: NanoPalette.electricBlue) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("网络电视")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(NanoPalette.textPrimary)
                    Spacer()
                    NanoFloatingPillBar(items: pillItems, selection: $activeTab)
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)

                switch activeTab {
                case .live:
                    liveGridSection
                case .epg:
                    epgMatrixGuideSection
                case .catchup:
                    catchupSplitSection
                case .signal:
                    signalDiagnosticSection
                case .sources:
                    sourceRepositorySection
                }
            }
        }
        .sheet(isPresented: $showAddSubscriptionSheet) {
            addSubscriptionSheetView
        }
    }

    // MARK: - 1. 直播频道网格（参考图1）

    private var liveGridSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    NanoLiveBadge(text: "直播")
                    Text("我的 IPTV · 多源聚合频道（直连）")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(NanoPalette.textPrimary)
                    Text("断流 8s 自动切源")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NanoPalette.electricBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(NanoPalette.electricBlue.opacity(0.16)))
                    Spacer()
                    Button {
                        showAddSubscriptionSheet = true
                    } label: {
                        Label("添加电视源 / EPG", systemImage: "plus.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(NanoPalette.electricBlue))
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        dimensionSwitchCapsule(title: "按类型", active: !dimensionByProvince) {
                            dimensionByProvince = false
                            selectedCategory = "全部"
                        }
                        dimensionSwitchCapsule(title: "按省份", active: dimensionByProvince) {
                            dimensionByProvince = true
                            selectedCategory = "全部"
                        }

                        Divider().frame(height: 16).overlay(NanoPalette.subtleBorder)

                        let cats = dimensionByProvince
                            ? ["全部", "北京", "湖南", "香港", "广东", "上海", "浙江", "江苏"]
                            : ["收藏", "全部", "央视", "卫视", "港澳台", "4K8K 频道", "地方"]

                        ForEach(cats, id: \.self) { cat in
                            let isSel = ((forcedCategory ?? selectedCategory) == cat)
                            Button {
                                selectedCategory = cat
                            } label: {
                                Text(cat == "收藏" ? "★ 收藏" : cat)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(isSel ? .white : NanoPalette.textSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(isSel ? NanoPalette.electricBlue : Color.white.opacity(0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                let columns = [GridItem(.adaptive(minimum: 235, maximum: 300), spacing: 16)]
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filteredChannels) { channel in
                        channelCard(channel)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    // MARK: - 2. 独立「节目单」全频道电子节目指南视图

    private var epgMatrixGuideSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("EPG 电子节目单指南")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(NanoPalette.textPrimary)
                        Text("自动解析 XMLTV (.xml / .xml.gz) 时间轴 · 实时追踪各频道当前播出与下期预告")
                            .font(.system(size: 13))
                            .foregroundStyle(NanoPalette.textSecondary)
                    }
                    Spacer()
                }

                ForEach(appVM.liveChannels) { ch in
                    NanoGlassCard(cornerRadius: 12, padding: 14) {
                        Task {
                            await appVM.player.playLiveChannel(ch, lineIndex: 0)
                            appVM.isPresentingFullPlayer = true
                        }
                    } content: {
                        HStack(spacing: 18) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(format: "%02d · %@", ch.channelNumber, ch.displayName))
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(NanoPalette.textPrimary)
                                Text(ch.category)
                                    .font(.system(size: 11))
                                    .foregroundStyle(NanoPalette.electricBlue)
                            }
                            .frame(width: 190, alignment: .leading)

                            Divider().frame(height: 36).overlay(NanoPalette.subtleBorder)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    NanoLiveBadge(text: "正在播出")
                                    Text(ch.currentProgram?.title ?? "实时信号直播中")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                Text("下一档预告：\(ch.nextProgram?.title ?? "待更新节目单")")
                                    .font(.system(size: 12))
                                    .foregroundStyle(NanoPalette.textMuted)
                            }

                            Spacer()

                            Image(systemName: "play.tv.fill")
                                .foregroundStyle(NanoPalette.electricBlue)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 3. 回看双栏时间轴页面（参考图2）

    private var catchupSplitSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("回看")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(NanoPalette.textPrimary)
                Text("\(appVM.liveChannels.filter(\.supportsCatchup).count) 个频道支持回看 · 选择一天，点击节目直接时移回放")
                    .font(.system(size: 13))
                    .foregroundStyle(NanoPalette.textSecondary)
            }

            HStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { offset in
                    let titles = ["今天", "昨天", "前天", "3天前", "4天前"]
                    let isSel = (selectedCatchupDayOffset == offset)
                    Button {
                        selectedCatchupDayOffset = offset
                    } label: {
                        VStack(spacing: 2) {
                            Text(titles[offset])
                                .font(.system(size: 13, weight: .bold))
                            Text(dateShortLabel(daysAgo: offset))
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(isSel ? Color.black : NanoPalette.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(isSel ? NanoPalette.amberGold : Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appVM.liveChannels.filter(\.supportsCatchup)) { ch in
                            let isSelected = (selectedCatchupChannelStdName == ch.standardName)
                            NanoGlassCard(cornerRadius: 10, padding: 12, isHighlighted: isSelected) {
                                selectedCatchupChannelStdName = ch.standardName
                            } content: {
                                HStack {
                                    Text(String(format: "%02d", ch.channelNumber))
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundStyle(NanoPalette.amberGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ch.displayName)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(NanoPalette.textPrimary)
                                        Text("\(appVM.catchupProgramsByChannel[ch.standardName]?.count ?? 0) 档节目可回看")
                                            .font(.system(size: 11))
                                            .foregroundStyle(NanoPalette.textMuted)
                                    }
                                    Spacer()
                                    Text("回看")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(NanoPalette.electricBlue)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(NanoPalette.electricBlue.opacity(0.16)))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 310)

                ScrollView {
                    let programs = appVM.catchupProgramsByChannel[selectedCatchupChannelStdName] ?? []
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(programs) { prog in
                            NanoGlassCard(cornerRadius: 10, padding: 13) {
                                playCatchupProgram(prog)
                            } content: {
                                HStack(spacing: 18) {
                                    Text(timeString(prog.startTime))
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundStyle(NanoPalette.amberGold)
                                    Text(prog.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(NanoPalette.textPrimary)
                                    Spacer()
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(NanoPalette.electricBlue)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    // MARK: - 4. 独立「信号」并发探针检测与失效源一键剔除页

    private var signalDiagnosticSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NanoGlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("信号健康度并发巡检")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(NanoPalette.textPrimary)
                            Text("并发发送首包 Range 探针检测延迟，自动将最快线路置顶，并支持一键清理超时死源")
                                .font(.system(size: 13))
                                .foregroundStyle(NanoPalette.textSecondary)
                        }
                        Spacer()

                        Button {
                            appVM.pruneOfflineIPTVLines()
                        } label: {
                            Text("剔除离线死链")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(NanoPalette.liveRed)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(NanoPalette.liveRed.opacity(0.14)))
                        }
                        .buttonStyle(.plain)

                        Button {
                            isProbingSignal = true
                            Task {
                                await appVM.probeAllIPTVChannelsSignal()
                                await MainActor.run { isProbingSignal = false }
                            }
                        } label: {
                            Label(isProbingSignal ? "并发测速中..." : "立即测速全部频道", systemImage: "speedometer")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(NanoPalette.electricBlue))
                        }
                        .buttonStyle(.plain)
                    }
                }

                ForEach(appVM.liveChannels) { ch in
                    HStack {
                        Text(ch.displayName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(NanoPalette.textPrimary)
                        Spacer()
                        Text("共 \(ch.lines.count) 条备用线路")
                            .font(.system(size: 12))
                            .foregroundStyle(NanoPalette.textMuted)
                        let bestMs = ch.lines.compactMap(\.latencyMs).min()
                        Text(bestMs.map { "最快 \($0) ms" } ?? "超时 / 未检测")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(bestMs != nil ? NanoPalette.onlineGreen : NanoPalette.warningAmber)
                            .frame(width: 120, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 5. 独立「源库」多订阅 M3U + XMLTV EPG 管理面板

    private var sourceRepositorySection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("IPTV 订阅源库管理")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(NanoPalette.textPrimary)
                        Text("管理多个 M3U / TXT 直播订阅及绑定的 XMLTV (.xml / .xml.gz) 节目单地址")
                            .font(.system(size: 13))
                            .foregroundStyle(NanoPalette.textSecondary)
                    }
                    Spacer()
                    Button {
                        showAddSubscriptionSheet = true
                    } label: {
                        Label("新增订阅源", systemImage: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(NanoPalette.amberGold))
                    }
                    .buttonStyle(.plain)
                }

                ForEach(appVM.iptvSubscriptions) { sub in
                    NanoGlassCard(cornerRadius: 14, padding: 16) {
                        HStack(spacing: 16) {
                            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(NanoPalette.electricBlue)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(sub.name)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(NanoPalette.textPrimary)
                                Text("M3U: \(sub.m3uURL)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(NanoPalette.textMuted)
                                    .lineLimit(1)
                                if let epg = sub.epgXMLTVURL, !epg.isEmpty {
                                    Text("EPG: \(epg)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(NanoPalette.onlineGreen)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Button("同步刷新") {
                                Task {
                                    await appVM.syncIPTVSubscription(sub)
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("删除") {
                                appVM.removeIPTVSubscription(id: sub.id)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 辅助组件与操作

    private func dimensionSwitchCapsule(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(active ? Color.black : NanoPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(active ? NanoPalette.amberGold : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    private func channelCard(_ channel: IPTVChannelGroup) -> some View {
        NanoGlassCard(cornerRadius: 14, padding: 14) {
            Task {
                await appVM.player.playLiveChannel(channel, lineIndex: 0)
                appVM.isPresentingFullPlayer = true
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    NanoLiveBadge(text: "直播")
                    Spacer()
                    if let ms = channel.lines.first?.latencyMs {
                        Text("\(ms) ms")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(NanoPalette.onlineGreen)
                    }
                    Button {
                        appVM.toggleFavoriteChannel(id: channel.id)
                    } label: {
                        Image(systemName: channel.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 13))
                            .foregroundStyle(channel.isFavorite ? NanoPalette.amberGold : NanoPalette.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.04))
                        .frame(height: 76)
                    VStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 22))
                            .foregroundStyle(NanoPalette.electricBlue.opacity(0.85))
                        if let tag = channel.lines.first?.resolutionTag {
                            Text(tag)
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(NanoPalette.amberGold)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(String(format: "%02d", channel.channelNumber))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(NanoPalette.electricBlue)
                        Text(channel.displayName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(NanoPalette.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(channel.lines.count)线")
                            .font(.system(size: 11))
                            .foregroundStyle(NanoPalette.textMuted)
                    }

                    HStack(spacing: 5) {
                        Circle()
                            .fill(channel.currentProgram != nil ? NanoPalette.liveRed : NanoPalette.textMuted)
                            .frame(width: 5, height: 5)
                        Text(channel.currentProgram?.title ?? "暂无节目单")
                            .font(.system(size: 12))
                            .foregroundStyle(NanoPalette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var addSubscriptionSheetView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加 IPTV 直播源与 XMLTV 节目单")
                .font(.headline)

            TextField("源名称（例如：家庭宽带组播 / 全球精选源）", text: $subName)
                .textFieldStyle(.roundedBorder)
            TextField("M3U / TXT 链接地址 或直接粘贴 #EXTM3U 文本", text: $subM3UURL)
                .textFieldStyle(.roundedBorder)
            TextField("可选：XMLTV EPG 节目单链接（支持 .xml 和 .xml.gz）", text: $subEPGURL)
                .textFieldStyle(.roundedBorder)
            TextField("可选：自定义 User-Agent（如 APTV/1.0 或 OkHttp）", text: $subUA)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("取消") { showAddSubscriptionSheet = false }
                Button("保存并立即解析") {
                    let newSub = IPTVSubscriptionSource(
                        name: subName.isEmpty ? "新建电视源" : subName,
                        m3uURL: subM3UURL,
                        epgXMLTVURL: subEPGURL.isEmpty ? nil : subEPGURL,
                        customUserAgent: subUA.isEmpty ? nil : subUA
                    )
                    showAddSubscriptionSheet = false
                    Task {
                        await appVM.addAndSyncIPTVSubscription(newSub)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 500)
    }

    private func playCatchupProgram(_ prog: EPGProgramItem) {
        guard let ch = appVM.liveChannels.first(where: { $0.standardName == prog.channelStdName }),
              let firstLine = ch.lines.first else { return }
        let url = IPTVLiveEngine.buildCatchupStreamURL(line: firstLine, program: prog) ?? URL(string: firstLine.url)!
        let ticket = PlayableStreamTicket(
            title: "\(ch.displayName) · 回看",
            subtitle: prog.title,
            streamURL: url,
            isLiveStream: false
        )
        Task {
            await appVM.player.startPlayback(ticket: ticket)
            appVM.isPresentingFullPlayer = true
        }
    }

    private func dateShortLabel(daysAgo: Int) -> String {
        let target = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "MM/dd"
        return f.string(from: target)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
