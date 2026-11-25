import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaContentCore

/// 网络电视总览：直播 / 节目回看 / 信号 / 源库四个分页，分页切换在窗口工具栏里，
/// 与「网络存储」「网络资源」保持同一套结构。
struct TVHubView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel

    var body: some View {
        ZStack {
            TVBrand.background
            Group {
                if !tv.enabled {
                    TVDisabledView()
                } else {
                    switch tv.hubTab {
                    case .channels:
                        TVChannelsView()
                    case .tonight:
                        TVTonightView()
                    case .guide:
                        TVGuideView()
                    case .status:
                        TVStatusView()
                    case .overview:
                        TVOverviewView()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // 不再强制落到某个源：没有焦点时频道页展示所有源聚合的频道墙。
            tv.refreshIfNeeded()
        }
        .onChange(of: tv.reminderNotice) { _, notice in
            guard let notice else { return }
            store.showToast(notice)
            tv.clearReminderNotice()
        }
        .onDisappear { tv.cancelProbes() }
    }
}

/// 工具栏中区的分页胶囊：频道 / 电视源 / 状态。
struct TVHubTabs: View {
    @EnvironmentObject private var tv: IPTVBrowserModel
    @Namespace private var tabNamespace

    var body: some View {
        tabsCapsule
    }

    private var tabsCapsule: some View {
        HStack(spacing: 2) {
            ForEach(TVHubTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!tv.enabled)
        .opacity(tv.enabled ? 1 : 0.5)
    }

    private func tabButton(_ tab: TVHubTab) -> some View {
        let active = tv.hubTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                tv.setHubTab(tab)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .fixedSize()
                Text(tab.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let badge = badge(for: tab), badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(active ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(active ? Color.white.opacity(0.92)
                                           : Color.primary.opacity(0.08),
                                    in: Capsule(style: .continuous))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if active {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "tv-hub-tab", in: tabNamespace)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }

    private func badge(for tab: TVHubTab) -> Int? {
        switch tab {
        case .overview: return tv.playlists.count
        case .channels: return tv.channelsForFocusedSource.count
        case .tonight: return nil
        case .guide: return tv.isLoadingEPG ? 1 : nil
        case .status: return tv.isChecking ? 1 : nil
        }
    }
}

/// 点开具体电视源后的工具栏中区：不再是总览分页，只保留「全部频道 + 当前源」。
struct TVFocusedSourceBar: View {
    @EnvironmentObject private var tv: IPTVBrowserModel
    let playlistID: UUID

    var body: some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    tv.focusAllSources()
                    tv.setHubTab(.channels)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("全部频道")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回全部频道的聚合频道墙")

            Rectangle()
                .fill(TVBrand.hairline)
                .frame(width: 0.6, height: 13)

            HStack(spacing: 5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(TVBrand.gold.opacity(0.9))
                Text(tv.playlistName(for: playlistID))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text("\(tv.channelsForFocusedSource.count.formatted()) 频道")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - 关闭态
private struct TVDisabledView: View {
    @EnvironmentObject private var tv: IPTVBrowserModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("网络电视已关闭")
                .font(.system(size: 14, weight: .semibold))
            Text("开启后不会自动接入任何源：可以粘贴自己的 M3U 地址，或导入本地播放列表与拾光分享包。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("开启网络电视") { tv.setEnabled(true) }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - 频道

private struct TVChannelsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel

    /// 海报墙负责浏览，列表负责扫台与数字键跳转；两种密度共用同一份筛选结果。
    private enum Density: String, CaseIterable, Identifiable {
        case wall, list
        var id: String { rawValue }
        var title: String { self == .wall ? "海报墙" : "列表" }
        var symbol: String { self == .wall ? "square.grid.2x2" : "list.bullet" }
    }

    @AppStorage("luma.tv.channelDensity") private var densityRaw = Density.wall.rawValue
    private var density: Density {
        get { Density(rawValue: densityRaw) ?? .wall }
        nonmutating set { densityRaw = newValue.rawValue }
    }

    @State private var showMultiview = false
    @State private var showSubscriptions = false
    /// 全频直播下按源筛选：只过滤这一页的频道，不改侧边栏焦点。
    @State private var sourceFilterID: UUID?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
            content
        }
        .sheet(isPresented: $showMultiview) {
            TVMultiviewSheet()
                .environmentObject(store)
                .environmentObject(tv)
        }
        .sheet(isPresented: $showSubscriptions) {
            TVSubscriptionsSheet()
                .environmentObject(store)
                .environmentObject(tv)
        }
        .onChange(of: tv.focusedPlaylistID) { _, _ in
            // 侧边栏已经指定了源时，页内的源筛选没有意义，清掉避免「两个源」互相打架。
            sourceFilterID = nil
        }
    }

    /// 页内源筛选后的分区：保留原来的分组与排序，只把别的源剔掉。
    private var sections: [(group: String, channels: [TVChannel])] {
        guard let sourceFilterID else { return tv.groupedChannels }
        return tv.groupedChannels.compactMap { section in
            let list = section.channels.filter { $0.playlistID == sourceFilterID }
            return list.isEmpty ? nil : (group: section.group, channels: list)
        }
    }

    /// 顶栏读数只数一遍，不为了一个数字把频道重新分组。
    private var displayedChannelCount: Int {
        guard let sourceFilterID else { return tv.visibleChannels.count }
        return tv.visibleChannels.reduce(0) { count, channel in
            count + (channel.playlistID == sourceFilterID ? 1 : 0)
        }
    }

    /// 全频直播下按源筛选：菜单里列出每个源与频道数，选中后这一页只看该源。
    private var sourceFilterMenu: some View {
        let active = sourceFilterID != nil
        return Menu {
            Button {
                sourceFilterID = nil
            } label: {
                if sourceFilterID == nil {
                    Label("全部源", systemImage: "checkmark")
                } else {
                    Text("全部源")
                }
            }
            Divider()
            ForEach(tv.playlists) { playlist in
                let count = tv.channels.filter { $0.playlistID == playlist.id }.count
                Button {
                    sourceFilterID = playlist.id
                } label: {
                    let title = "\(shortSourceName(playlist.name)) · \(count)"
                    if sourceFilterID == playlist.id {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
                .disabled(count == 0)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 9, weight: .semibold))
                Text(sourceFilterLabel)
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background {
                Capsule(style: .continuous)
                    .fill(active ? TVBrand.gold : TVBrand.panel)
            }
            .overlay(Capsule(style: .continuous)
                .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("按源筛选频道")
    }

    private var sourceFilterLabel: String {
        guard let sourceFilterID,
              let playlist = tv.playlists.first(where: { $0.id == sourceFilterID })
        else { return "全部源" }
        return shortSourceName(playlist.name)
    }

    /// 源名通常写成「我的 IPTV · 国内频道（直连）」：胶囊里只留前半段。
    private func shortSourceName(_ name: String) -> String {
        name.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TVLiveBadge(compact: true)
                Text(currentSourceName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                // 三种分组方式在全部源与单个源里都能用，入口始终可见。
                groupingSwitch
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        quickChip(.favorites)
                        quickChip(.recent)
                        if tv.focusedPlaylistID == nil {
                            Rectangle()
                                .fill(TVBrand.hairline)
                                .frame(width: 1, height: 16)
                                .padding(.horizontal, 2)
                            sourceFilterMenu
                        }
                        Rectangle()
                            .fill(TVBrand.hairline)
                            .frame(width: 1, height: 16)
                            .padding(.horizontal, 2)
                        filterChip(nil)
                        ForEach(tv.filterOptions, id: \.self) { option in
                            filterChip(option)
                        }
                    }
                    .padding(.vertical, 1)
                }
                Spacer(minLength: 0)
                headerActions
                densitySwitch
                Text("\(displayedChannelCount) 个频道")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }

            if let message = tv.error, !message.isEmpty, !tv.channels.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(TVBrand.warning)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// 追剧 / 多画面 / 刷新：从前一行的标题区挪下来，和筛选放在同一行。
    private var headerActions: some View {
        HStack(spacing: 6) {
            compactAction("追剧",
                          systemImage: "bookmark.fill",
                          badge: tv.subscriptions.isEmpty ? nil : tv.subscriptions.count) {
                showSubscriptions = true
            }
            .help("我的追剧：订阅节目，未来 7 天自动提醒")

            compactAction("多画面", systemImage: "square.grid.2x2") {
                showMultiview = true
            }
            .help("2×2 同时看四个频道，声音只跟一个")

            compactAction("刷新", systemImage: "arrow.clockwise") {
                tv.refresh()
            }
            .disabled(tv.isLoading)
            .help("重新拉取当前电视源")
        }
    }

    private func compactAction(_ title: String,
                               systemImage: String,
                               badge: Int? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(TVBrand.gold)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(TVBrand.gold.opacity(0.16), in: Capsule())
                }
            }
            .foregroundStyle(.primary.opacity(0.78))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(TVBrand.panel, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    private func quickChip(_ filter: TVQuickFilter) -> some View {
        let active = tv.quickFilter == filter
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                tv.quickFilter = active ? nil : filter
                if !active {
                    tv.groupFilter = nil
                    tv.provinceFilter = nil
                    tv.countryFilter = nil
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(filter.title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
            }
            .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background {
                Capsule(style: .continuous)
                    .fill(active ? TVBrand.gold : TVBrand.panel)
            }
            .overlay(Capsule(style: .continuous)
                .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .help(filter == .favorites ? "只看收藏的频道" : "只看最近看过的频道")
    }

    private func filterChip(_ option: String?) -> some View {
        let mode = tv.effectiveGroupingMode
        let active: Bool
        switch mode {
        case .province:
            active = tv.quickFilter == nil && tv.provinceFilter == option
        case .country:
            active = tv.quickFilter == nil && tv.countryFilter == option
        case .category:
            active = tv.quickFilter == nil && tv.groupFilter == option
        }
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                tv.quickFilter = nil
                switch mode {
                case .province:
                    tv.provinceFilter = option
                case .country:
                    tv.countryFilter = option
                case .category:
                    tv.groupFilter = option
                }
            }
        } label: {
            Text(option ?? "全部")
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? TVBrand.onWave : Color.secondary)
                .padding(.horizontal, 11)
                .frame(height: 25)
                .background {
                    Capsule(style: .continuous)
                        .fill(active ? TVBrand.wave : TVBrand.panel)
                }
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    /// 「按类型 / 按省份 / 按国家」切换：省份模式把地方台按省份聚合成一节，
    /// 国家模式把频道按国家 / 地区聚合成一节。
    private var groupingSwitch: some View {
        HStack(spacing: 2) {
            ForEach(TVGroupingMode.allCases) { mode in
                let active = tv.groupingMode == mode
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        tv.setGroupingMode(mode)
                    }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 23)
                        .background {
                            if active {
                                Capsule(style: .continuous).fill(TVBrand.gold)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(mode == .province ? "把地方台按省份聚合"
                      : (mode == .country ? "把频道按国家 / 地区聚合" : "按新闻 / 体育等类型分组"))
            }
        }
        .padding(2)
        .background(TVBrand.panel, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        .fixedSize()
    }

    private var densitySwitch: some View {
        HStack(spacing: 2) {
            ForEach(Density.allCases) { item in
                let active = density == item
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { density = item }
                } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(active ? TVBrand.onWave : Color.secondary)
                        .frame(width: 24, height: 23)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(TVBrand.wave)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(2)
        .background(TVBrand.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if tv.isLoading, tv.channels.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在拉取各地区频道…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tv.channels.isEmpty, let sourceError = tv.sourceError {
            VStack(spacing: 12) {
                SourceErrorView(error: sourceError) { action in
                    if action == .retry { tv.refresh() }
                }
                .frame(maxWidth: 460)
                Button("重新拉取") { tv.refresh() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if tv.visibleChannels.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.isEmpty {
            Text("这个源在当前筛选下没有频道")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if density == .list {
            channelList
        } else {
            let numbers = Dictionary(uniqueKeysWithValues: tv.channelsForFocusedSource.enumerated().map {
                ($0.element.id, $0.offset + 1)
            })
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        Color.clear
                            .frame(height: 0)
                            .id("tv-top")
                        ForEach(sections, id: \.group) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Capsule(style: .continuous)
                                        .fill(TVBrand.signal)
                                        .frame(width: 3, height: 12)
                                    Text(section.group)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text("\(section.channels.count)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Rectangle()
                                        .fill(TVBrand.hairline)
                                        .frame(height: 0.8)
                                }
                                LazyVGrid(columns: columns, spacing: 14) {
                                    ForEach(section.channels) { channel in
                                        TVChannelTile(channel: channel,
                                                      number: numbers[channel.id] ?? 0,
                                                      isPlaying: playingChannelID == channel.id) {
                                            store.openTVChannel(channel)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
                // 换源时重建滚动视图：上一个源很可能滚到很深处，只剩偏移量会显示空白。
                .id(tv.focusedPlaylistID?.uuidString ?? "tv-all")
                // 换分组 / 换省份 / 换国家 / 换分组方式 / 搜索时回到顶部，避免沿用之前的位置。
                .onChange(of: tv.groupFilter) { _, _ in scrollToTop(proxy) }
                .onChange(of: tv.provinceFilter) { _, _ in scrollToTop(proxy) }
                .onChange(of: tv.countryFilter) { _, _ in scrollToTop(proxy) }
                .onChange(of: tv.groupingMode) { _, _ in scrollToTop(proxy) }
                .onChange(of: tv.searchText) { _, _ in scrollToTop(proxy) }
            }
        }
    }

    /// 列表密度：14–18 行/屏，固定列用于快速扫台；不显示渐变与阴影，保证长列表滚动。
    private var channelList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Color.clear.frame(height: 0).id("tv-top")
                    ForEach(sections, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Capsule(style: .continuous)
                                    .fill(TVBrand.signal)
                                    .frame(width: 3, height: 10)
                                Text(section.group)
                                    .font(.system(size: 12, weight: .semibold))
                                Text("\(section.channels.count)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
                            }
                            VStack(spacing: 1) {
                                ForEach(section.channels) { channel in
                                    TVChannelRow(channel: channel,
                                                 number: tv.channelNumber(for: channel),
                                                 isPlaying: playingChannelID == channel.id) {
                                        store.openTVChannel(channel)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            .id(tv.focusedPlaylistID?.uuidString ?? "tv-all")
            .onChange(of: tv.groupFilter) { _, _ in scrollToTop(proxy) }
            .onChange(of: tv.provinceFilter) { _, _ in scrollToTop(proxy) }
            .onChange(of: tv.countryFilter) { _, _ in scrollToTop(proxy) }
            .onChange(of: tv.groupingMode) { _, _ in scrollToTop(proxy) }
            .onChange(of: tv.searchText) { _, _ in scrollToTop(proxy) }
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("tv-top", anchor: .top)
    }

    private var currentSourceName: String {
        guard let id = tv.focusedPlaylistID else { return "全频直播" }
        return tv.playlistName(for: id)
    }

    /// 当前正在播放的频道：查看器里打开的电视频道。
    private var playingChannelID: String? {
        guard let viewerID = store.viewerID else { return nil }
        return store.tvPlaybackChannel(for: viewerID)?.id
    }

    private var emptyMessage: String {
        if !tv.searchText.isEmpty { return "没有找到「\(tv.searchText)」" }
        if tv.quickFilter == .favorites {
            return "还没有收藏频道。右键频道卡选择「收藏」，之后会出现在这里。"
        }
        if tv.quickFilter == .recent {
            return "还没有最近观看。打开一个频道后会出现在这里。"
        }
        return "这个电视源还没有频道，去「源库」分页点一下检测。"
    }
}

/// 频道卡片：16:9 信号面板 + 台标 + LIVE / 画质角标；悬停时描边发光并浮起。
private struct TVChannelTile: View {
    @EnvironmentObject private var tv: IPTVBrowserModel
    let channel: TVChannel
    let number: Int
    let isPlaying: Bool
    let onPlay: () -> Void

    @State private var hovered = false
    @State private var preview: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 开启「减少动态效果」时不做悬停放大 / 浮起。
    private var lift: Bool { hovered && !reduceMotion }

    var body: some View {
        Button(action: onPlay) {
            VStack(spacing: 0) {
                panel
                footer
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovered ? TVBrand.surfaceHover : TVBrand.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .shadow(color: (hovered || isPlaying) && !reduceMotion ? TVBrand.wave.opacity(0.22) : TVBrand.shadow,
                    radius: (hovered || isPlaying) && !reduceMotion ? 14 : 8,
                    y: (hovered || isPlaying) && !reduceMotion ? 6 : 4)
            .scaleEffect(lift ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(tv.probeState(for: channel.id) == .unavailable ? 0.74 : 1)
        .onHover { value in
            withAnimation(.easeOut(duration: 0.16)) { hovered = value }
        }
        .contextMenu {
            Button(isPlaying ? "重新打开" : "播放") { onPlay() }
            Button(tv.isFavorite(channel) ? "取消收藏" : "收藏") {
                tv.toggleFavorite(channel)
            }
            Button("重试取帧") { tv.retryPreview(for: channel) }
        }
        .help("\(channel.name) · \(tv.playlistName(for: channel.playlistID))")
        .task(id: channel.id) {
            await tv.requestPreview(for: channel)
        }
        .task(id: previewKey) {
            guard tv.probeState(for: channel.id) == .available else { return }
            if let image = await TVPreviewCache.shared.image(for: channel.id) {
                withAnimation(.easeOut(duration: 0.2)) { preview = image }
            }
        }
    }

    private var previewKey: String {
        "\(channel.id)#\(tv.probeState(for: channel.id).rawValue)"
    }

    private var borderColor: Color {
        if isPlaying { return TVBrand.wave }
        if hovered { return TVBrand.wave.opacity(0.55) }
        return TVBrand.stroke
    }

    private var borderWidth: CGFloat {
        isPlaying ? 1.4 : (hovered ? 1 : 0.7)
    }

    private var panel: some View {
        ZStack {
            LinearGradient(colors: [TVBrand.cardTop, TVBrand.cardBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let preview {
                // 抓到的实时画面铺满面板，台标缩成左下角小徽标。
                Color.clear
                    .overlay {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.42), .clear, .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                RadialGradient(colors: [TVBrand.wave.opacity(hovered ? 0.20 : 0.10), .clear],
                               center: .top, startRadius: 4, endRadius: 220)
                TVLogoImage(urlString: channel.logoURL,
                            size: CGSize(width: 130, height: 62))
                    .shadow(color: TVBrand.logoShadow, radius: 6, y: 2)
                    .scaleEffect(hovered ? 1.03 : 1)
            }

            VStack {
                HStack(alignment: .top) {
                    TVLiveBadge()
                    Spacer(minLength: 0)
                    if tv.isFavorite(channel) || hovered {
                        Image(systemName: tv.isFavorite(channel) ? "star.fill" : "star")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tv.isFavorite(channel) ? TVBrand.gold : Color.white.opacity(0.75))
                            .shadow(color: TVBrand.gold.opacity(0.5), radius: 4)
                    }
                    if let quality = channel.qualityLabel {
                        qualityPill(quality)
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    if preview != nil {
                        TVLogoImage(urlString: channel.logoURL,
                                    size: CGSize(width: 56, height: 22))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(TVBrand.previewScrim,
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Spacer(minLength: 0)
                    ZStack {
                        Circle()
                            .fill(TVBrand.wave)
                            .frame(width: 30, height: 30)
                            .shadow(color: TVBrand.wave.opacity(0.5), radius: 8)
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(TVBrand.onWave)
                    }
                    .opacity(hovered || isPlaying ? 1 : 0)
                    .scaleEffect(hovered || isPlaying ? 1 : 0.85)
                }
            }
            .padding(9)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14,
                                          bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0,
                                          topTrailingRadius: 14,
                                          style: .continuous))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 7) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(TVBrand.wave)
                    .frame(minWidth: 22, alignment: .leading)
                Text(channel.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let current = tv.currentProgram(for: channel) {
                    Text(clock(current.start))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary.opacity(hovered ? 1 : 0.55))
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
                if let current = tv.currentProgram(for: channel) {
                    Text(current.title)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    Text("\(clock(current.start)) – \(clock(current.end))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                } else {
                    Text(tv.isLoadingEPG ? "正在读取节目单…" : "暂无节目单")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            progressBar
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let current = tv.currentProgram(for: channel) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(TVBrand.hairline)
                    Capsule(style: .continuous)
                        .fill(TVBrand.wave)
                        .frame(width: max(0, proxy.size.width * programProgress(current)))
                }
            }
            .frame(height: 2)
            .padding(.top, 1)
        }
    }

    private var statusColor: Color {
        if isPlaying { return TVBrand.wave }
        switch tv.probeState(for: channel.id) {
        case .available: return TVBrand.success
        case .probing: return TVBrand.gold
        case .unavailable: return TVBrand.signal
        case .idle: return Color.secondary.opacity(0.5)
        }
    }

    private func programProgress(_ program: TVEPGProgram) -> Double {
        let total = max(1, program.duration)
        return min(max(Date().timeIntervalSince(program.start) / total, 0), 1)
    }

    private func clock(_ date: Date) -> String {
        Self.clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func qualityPill(_ quality: String) -> some View {
        let style = TVBrand.qualityStyle(quality)
        return Text(quality)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(style.fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(style.bg, in: Capsule(style: .continuous))
    }
}

/// 列表密度的一行：频道号 / 台标 / 台名 + 分组 / Now & Next / 进度 / 信号点 / 星标。
private struct TVChannelRow: View {
    @EnvironmentObject private var tv: IPTVBrowserModel
    let channel: TVChannel
    let number: Int
    let isPlaying: Bool
    let onPlay: () -> Void

    @State private var hovered = false

    private var current: TVEPGProgram? { tv.currentProgram(for: channel) }
    private var next: TVEPGProgram? { tv.nextProgram(for: channel) }

    private var statusColor: Color {
        switch tv.probeState(for: channel.id) {
        case .available: return TVBrand.success
        case .unavailable: return TVBrand.signal
        case .probing: return TVBrand.gold
        case .idle: return Color.secondary.opacity(0.5)
        }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onPlay) { rowContent }
                .buttonStyle(.plain)
            favoriteButton
                .padding(.trailing, 8)
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button(isPlaying ? "重新打开" : "播放", action: onPlay)
            Button(tv.isFavorite(channel) ? "取消收藏" : "收藏频道") { tv.toggleFavorite(channel) }
            Button("重新探测信号") { tv.retryPreview(for: channel) }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Capsule(style: .continuous)
                .fill(isPlaying ? TVBrand.wave : Color.clear)
                .frame(width: 2, height: 22)

            Text(String(format: "%02d", number))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isPlaying ? TVBrand.wave : Color.secondary)
                .frame(width: 30, alignment: .leading)

            TVLogoImage(urlString: channel.logoURL,
                        size: CGSize(width: 32, height: 20),
                        cornerRadius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(channel.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(channel.group)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 168, alignment: .leading)

            programInfo
                .frame(maxWidth: .infinity, alignment: .leading)

            if let current {
                ProgressView(value: progress(current))
                    .progressViewStyle(.linear)
                    .tint(TVBrand.wave)
                    .controlSize(.mini)
                    .frame(width: 72)
            }

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .help(probeHelp)
        }
        .padding(.leading, 8)
        .padding(.trailing, 28)
        .frame(height: 44)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var favoriteButton: some View {
        Button {
            tv.toggleFavorite(channel)
        } label: {
            Image(systemName: tv.isFavorite(channel) ? "star.fill" : "star")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tv.isFavorite(channel) ? TVBrand.gold : Color.secondary.opacity(0.45))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tv.isFavorite(channel) ? "取消收藏" : "收藏频道")
    }

    @ViewBuilder
    private var programInfo: some View {
        if let current {
            HStack(spacing: 6) {
                Text(current.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                Text("\(clock(current.start)) – \(clock(current.end))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                if let next {
                    Text("接下来 \(next.title)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else if let next {
            Text("接下来 \(clock(next.start)) · \(next.title)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("暂无节目单")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isPlaying ? TVBrand.wave.opacity(0.07)
                            : (hovered ? TVBrand.surfaceHover : Color.clear))
    }

    private var probeHelp: String {
        switch tv.probeState(for: channel.id) {
        case .available: return "信号正常"
        case .unavailable: return "信号异常"
        case .probing: return "正在抓帧"
        case .idle: return "尚未探测"
        }
    }

    private func progress(_ program: TVEPGProgram) -> Double {
        let total = max(1, program.duration)
        return min(max(Date().timeIntervalSince(program.start) / total, 0), 1)
    }

    private func clock(_ date: Date) -> String {
        Self.clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 节目单

/// 节目回看的三种看法：横向时间轴看「谁在播什么」，传送门回到某一天，环形表盘看「这一天怎么走」。
private enum TVGuideMode: String, CaseIterable, Identifiable {
    case timeline
    case portal
    case ring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: return "时间轴"
        case .portal: return "传送门"
        case .ring: return "时间环"
        }
    }

    var symbol: String {
        switch self {
        case .timeline: return "rectangle.split.3x1"
        case .portal: return "sparkles"
        case .ring: return "circle.dashed"
        }
    }
}

/// 节目单：优先回答「现在播什么、接下来是什么」。
/// 数据来自 M3U 头部的 XMLTV 地址；没有 EPG 时明确说明，不伪造节目。
private struct TVGuideView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel

    /// Guide 是「时间轴视图」：今天 / 明天，两小时窗口，30 分钟一格。
    /// 选中日期放在模型里，顶部工具栏的分页胶囊同步显示「N 个频道有节目单 · 昨天」。
    /// 非 mutating setter 让页面里已有的 `dayOffset = n` 写法继续可用。
    private var dayOffset: Int {
        get { min(2, max(-2, tv.guideDayOffset)) }
        nonmutating set { tv.guideDayOffset = min(2, max(-2, newValue)) }
    }
    @State private var windowHour = Calendar.current.component(.hour, from: Date())
    @State private var selected: TVEPGProgram?
    /// 时间轴：鼠标悬停的节目，只影响那一块的高亮。
    @State private var hoveredGuideProgramID: String?

    /// 节目回看的三种视图，默认落在时间轴。
    @AppStorage("tv.guideMode.v2") private var guideModeRaw = TVGuideMode.timeline.rawValue
    /// 时间环：选中频道、拖动时间、悬停时间（限频）。
    @State private var guideChannelID: String?
    /// 时间环「回到现在」的信号：把表盘指针收回此刻。
    @State private var ringResetTick = 0
    /// 「有节目的频道」缓存：避免每次重绘都遍历上千频道并排序。
    @State private var guideChannelsCache: [TVChannel] = []
    @State private var guideChannelsKey = ""
    /// 当前频道当天的节目缓存。
    @State private var ringProgramsCache: [TVEPGProgram] = []
    @State private var ringProgramsKey = ""

    private let channelColumnWidth: CGFloat = 200
    private let guideRowHeight: CGFloat = 58
    private let slotMinutes = 30
    /// 时间轴时间窗：默认 2 小时，可拖动调整到 1–12 小时。
    @State private var windowHours: Double = 2
    @State private var windowDragStartHours: Double?

    private var clampedWindowHours: Double {
        min(12, max(1, windowHours))
    }

    /// 刻度的格子数：固定 30 分钟一格，窗口拉长后格子变多。
    private var slotCount: Int {
        max(2, Int((clampedWindowHours * 60 / Double(slotMinutes)).rounded()))
    }

    /// 时间窗不能跨过午夜。
    private var maxWindowHour: Int {
        max(0, 24 - Int(ceil(clampedWindowHours)))
    }

    private var selectedDay: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: dayOffset, to: today) ?? today
    }

    private var guideMode: TVGuideMode {
        TVGuideMode(rawValue: guideModeRaw) ?? .timeline
    }

    private var windowStart: Date {
        Calendar.current.date(bySettingHour: windowHour,
                              minute: 0,
                              second: 0,
                              of: selectedDay) ?? selectedDay
    }

    private var windowEnd: Date {
        windowStart.addingTimeInterval(clampedWindowHours * 3600)
    }

    /// 缓存键：日期 / EPG 规模变化时才重算。
    private var guideCacheKey: String {
        "\(selectedDay.timeIntervalSince1970)-\(tv.epgPrograms.count)-\(tv.visibleChannels.count)-\(tv.epgUpdatedAt?.timeIntervalSince1970 ?? 0)"
    }

    /// 只读缓存：计算交给 `.task(id:)`，body 里绝不做全量遍历，
    /// 否则首帧 / 拖动时会用上千个频道反复卡住主线程。
    private var channelsWithEPG: [TVChannel] {
        guideChannelsCache
    }

    private func computeChannelsWithEPG() -> [TVChannel] {
        tv.channelsWithPrograms(on: selectedDay)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
            if let selected, guideMode == .timeline {
                detailBand(selected)
                Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
            }
            content
        }
        .task { tv.loadEPGIfNeeded() }
        // 名单与节目只在数据变化时重算一次，滚动 / 悬停 / 拖动都直接读缓存。
        .task(id: guideCacheKey) {
            let key = guideCacheKey
            let channels = computeChannelsWithEPG()
            guideChannelsCache = channels
            guideChannelsKey = key
        }
        .task(id: ringProgramsKeyNow) {
            let key = ringProgramsKeyNow
            let programs = computeRingPrograms()
            ringProgramsCache = programs
            ringProgramsKey = key
        }
        .onChange(of: dayOffset) { _, _ in
            selected = nil
            let hour = dayOffset == 0 ? Calendar.current.component(.hour, from: Date()) : 19
            windowHour = min(maxWindowHour, max(0, hour))
        }
        // 时间窗变长后起点不能越界；变短时不额外挪动。
        .onChange(of: windowHours) { _, _ in
            windowHour = min(maxWindowHour, max(0, windowHour))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                // 日期只看五天：前天 / 昨天 / 今天 / 明天 / 后天。历史用于回看，未来用于预约。
                ForEach(Array(-2...2), id: \.self) { offset in
                    dayChip(offset)
                }

                Rectangle()
                    .fill(TVBrand.hairline)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 2)

                modeSwitcher

                Rectangle()
                    .fill(TVBrand.hairline)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 2)

                if guideMode == .timeline {
                    windowButton("chevron.left", help: "往前一小时") { shiftWindow(-1) }
                    windowChip
                    windowButton("chevron.right", help: "往后一小时") { shiftWindow(1) }
                    Button("回到现在") { jumpToNow() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TVBrand.wave)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(TVBrand.wave.opacity(0.10), in: Capsule(style: .continuous))
                } else {
                    Button("回到现在") { jumpRingToNow() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TVBrand.gold)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(TVBrand.gold.opacity(0.12), in: Capsule(style: .continuous))
                }

                refreshButton

                // 节目单最近一次刷新时间：从标题栏挪回内容页，贴着刷新按钮。
                if let updated = tv.epgUpdatedAt {
                    Text("更新于 \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help("节目单最近一次成功刷新的时间")
                }

                Spacer(minLength: 0)
                if guideMode == .timeline { legend }
            }

            if let error = tv.epgError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(TVBrand.warning)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func dayChip(_ offset: Int) -> some View {
        let active = dayOffset == offset
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { dayOffset = offset }
        } label: {
            Text(guideDayTitle(offset))
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? TVBrand.onWave : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(active ? TVBrand.wave : TVBrand.panel,
                            in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .help(fullDayTitle(offset))
    }

    /// 标题：大前天 / 前天 / 昨天 / 今天 / 明天 / 后天 / 大后天。
    private func guideDayTitle(_ offset: Int) -> String {
        switch offset {
        case -3: return "大前天"
        case -2: return "前天"
        case -1: return "昨天"
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case 3: return "大后天"
        default:
            guard let date = Calendar.current.date(byAdding: .day, value: offset,
                                                   to: Calendar.current.startOfDay(for: Date()))
            else { return "—" }
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
    }

    /// 悬浮提示：带具体日期。
    private func fullDayTitle(_ offset: Int) -> String {
        guard let date = Calendar.current.date(byAdding: .day, value: offset,
                                               to: Calendar.current.startOfDay(for: Date()))
        else { return guideDayTitle(offset) }
        return "\(guideDayTitle(offset)) · \(date.formatted(.dateTime.month(.defaultDigits).day().weekday(.wide)))"
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(TVGuideMode.allCases) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.24)) {
                        guideModeRaw = mode.rawValue
                        selected = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 9, weight: .semibold))
                        Text(mode.title)
                            .font(.system(size: 10.5,
                                          weight: guideMode == mode ? .semibold : .regular))
                    }
                    .foregroundStyle(guideMode == mode ? TVBrand.onWave : Color.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background {
                        if guideMode == mode {
                            Capsule(style: .continuous).fill(TVBrand.wave)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode == .ring ? "环形表盘：拖动看一天"
                      : (mode == .portal ? "传送门：回到某一天的节目" : "横向时间轴"))
            }
        }
        .padding(2)
        .background(TVBrand.panel, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
    }

    private var refreshButton: some View {
        Button {
            tv.reloadEPG()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                Text("刷新节目单")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(TVBrand.panel, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .disabled(tv.isLoadingEPG)
        .help("重新拉取节目单（主源 + 补充源）")
    }

    private func windowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(TVBrand.panel, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 时间窗读数：带上具体日期，避免只看到时间不知道是哪一天。
    /// 左右拖动胶囊可把窗口从 1 小时拉到 12 小时。
    private var windowChip: some View {
        HStack(spacing: 6) {
            Text(guideDayTitle(dayOffset))
                .foregroundStyle(TVBrand.gold.opacity(0.9))
            Text(selectedDay.formatted(.dateTime.month(.defaultDigits).day()))
                .foregroundStyle(Color.primary.opacity(0.62))
            Rectangle()
                .fill(TVBrand.hairline)
                .frame(width: 1, height: 10)
            Text("\(clock(windowStart)) – \(clock(windowEnd))")
                .foregroundStyle(Color.primary.opacity(0.82))
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(TVBrand.wave.opacity(0.85))
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(TVBrand.panel, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        .fixedSize()
        .contentShape(Capsule(style: .continuous))
        .gesture(windowResizeGesture)
        .help("左右拖动调整时间窗（1–12 小时）")
    }

    /// 横向拖动换算成窗口长度：30pt ≈ 1 小时，按半小时吸附。
    private var windowResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let base = windowDragStartHours ?? clampedWindowHours
                windowDragStartHours = base
                let hours = base + value.translation.width / 30
                windowHours = min(12, max(1, (hours * 2).rounded() / 2))
            }
            .onEnded { _ in
                windowDragStartHours = nil
            }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendDot(TVBrand.signal.opacity(0.75), "正在播")
            legendDot(TVBrand.wave.opacity(0.75), "可回看 / 已播")
            legendDot(Color.primary.opacity(0.14), "无节目")
        }
    }

    private func legendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func shiftWindow(_ delta: Int) {
        windowHour = min(maxWindowHour, max(0, windowHour + delta))
        selected = nil
    }

    private func jumpToNow() {
        dayOffset = 0
        windowHour = min(maxWindowHour,
                         max(0, Calendar.current.component(.hour, from: Date())))
        withAnimation(.easeOut(duration: 0.2)) { selected = nil }
    }

    private func jumpRingToNow() {
        dayOffset = 0
        ringResetTick &+= 1
        withAnimation(.easeOut(duration: 0.2)) { selected = nil }
    }

    @ViewBuilder
    private var content: some View {
        if tv.isLoadingEPG, tv.epgPrograms.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在拉取节目单…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tv.epgPrograms.isEmpty {
            emptyState
        } else if channelsWithEPG.isEmpty {
            if dayOffset != 0 {
                emptyState(message: "\(guideDayTitle(dayOffset))还没有节目单。EPG 只覆盖源站已发布的日期，换一天或刷新节目单试试。")
            } else {
                emptyState(message: "已经拿到 EPG，但没有频道能匹配上。检查源的 tvg-id 是否与 XMLTV 一致。")
            }
        } else {
            switch guideMode {
            case .timeline:
                timeline
                    .transition(.opacity)
            case .portal:
                guidePortal
                    .transition(.opacity)
            case .ring:
                guideRing
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
    }

    /// 时间轴：左侧固定频道列，右侧两小时窗口。
    /// 节目按真实起止时间铺成连续的块，跨半点不再被切成重复的两格。
    private var timeline: some View {
        GeometryReader { proxy in
            let gridWidth = max(520, proxy.size.width - channelColumnWidth - 44)
            let slotWidth = gridWidth / CGFloat(slotCount)
            ScrollView {
                LazyVStack(spacing: 0) {
                    timeHeader(slotWidth: slotWidth)
                    ForEach(channelsWithEPG) { channel in
                        timelineRow(channel: channel, slotWidth: slotWidth)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
                .overlay(alignment: .topLeading) {
                    nowLine(slotWidth: slotWidth)
                }
            }
        }
    }

    /// 表头：整点更重、半点更轻，像一条真实的刻度尺。
    private func timeHeader(slotWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("频道")
                Text("\(channelsWithEPG.count)")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: channelColumnWidth, height: 34, alignment: .leading)

            ForEach(0..<slotCount, id: \.self) { slot in
                let minute = Calendar.current.component(.minute, from: slotStart(slot))
                // 窗口拉长后格子变窄，只保留整点读数，避免时间串在一起。
                let showsLabel = slotWidth >= 54 || minute == 0
                Text(showsLabel ? clock(slotStart(slot)) : "")
                    .font(.system(size: minute == 0 ? 10.5 : 9,
                                  weight: minute == 0 ? .semibold : .regular,
                                  design: .monospaced))
                    .foregroundStyle(minute == 0 ? Color.primary.opacity(0.72)
                                                 : Color.secondary.opacity(0.55))
                    .frame(width: slotWidth, height: 34, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(minute == 0 ? TVBrand.hairline : TVBrand.hairline.opacity(0.45))
                            .frame(height: 0.6)
                    }
            }
        }
        .frame(height: 34)
    }

    private func timelineRow(channel: TVChannel, slotWidth: CGFloat) -> some View {
        let isPlaying = channel.id == playingChannelID
        return HStack(spacing: 0) {
            channelCell(channel, isPlaying: isPlaying)
            programTrack(channel: channel, slotWidth: slotWidth)
        }
        .frame(height: guideRowHeight)
        .background {
            if isPlaying { TVBrand.signal.opacity(0.045) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(TVBrand.hairline.opacity(0.55)).frame(height: 0.5)
        }
    }

    private func channelCell(_ channel: TVChannel, isPlaying: Bool) -> some View {
        Button {
            store.openTVChannel(channel)
        } label: {
            HStack(spacing: 9) {
                Text(String(format: "%02d", tv.channelNumber(for: channel)))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isPlaying ? TVBrand.signal
                                               : Color.secondary.opacity(0.7))
                    .frame(width: 24, alignment: .leading)
                TVLogoImage(urlString: channel.logoURL,
                            size: CGSize(width: 36, height: 22),
                            cornerRadius: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 12, weight: isPlaying ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(channel.group)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isPlaying {
                    Circle().fill(TVBrand.signal).frame(width: 5, height: 5)
                } else if tv.isFavorite(channel) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(TVBrand.gold)
                }
            }
            .padding(.trailing, 10)
            .frame(width: channelColumnWidth, height: guideRowHeight)
            .overlay(alignment: .trailing) {
                Rectangle().fill(TVBrand.hairline).frame(width: 0.6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("播放 \(channel.name)")
    }

    // MARK: 时间轴 · 节目块

    private struct GuideSlice: Identifiable {
        let program: TVEPGProgram
        /// 落在时间窗里的那一段：块的宽度和读数都以它为准，避免「窗口是 19:00 起，
        /// 块上却写着 18:00」的错觉。
        let visibleStart: Date
        var visibleEnd: Date
        let x: CGFloat
        var width: CGFloat
        /// 碎片合并后的显示名与档数（正常节目为空 / 0）。
        var label: String? = nil
        var extraCount: Int = 0

        var id: String { program.id }
    }

    private func programTrack(channel: TVChannel, slotWidth: CGFloat) -> some View {
        let totalWidth = slotWidth * CGFloat(slotCount)
        let slices = programSlices(channel: channel, totalWidth: totalWidth)
        return ZStack(alignment: .topLeading) {
            hourGrid(slotWidth: slotWidth)
            ForEach(slices) { slice in
                programBlock(channel: channel, slice: slice)
                    .offset(x: slice.x, y: 6)
            }
        }
        .frame(width: totalWidth, height: guideRowHeight, alignment: .topLeading)
        .clipped()
    }

    /// 只取落在时间窗里的节目，并按真实时长换算成横向位置。
    /// 宽度不再强行撑到最小可读宽度，而是夹在「下一档的起点」之前，
    /// 长时间窗里短节目很多时也不会互相压住。
    private func programSlices(channel: TVChannel, totalWidth: CGFloat) -> [GuideSlice] {
        let start = windowStart
        let end = windowEnd
        let span = max(1, end.timeIntervalSince(start))
        var raw: [(program: TVEPGProgram, vs: Date, ve: Date, x: CGFloat, width: CGFloat)] = []
        for program in tv.programs(on: selectedDay, for: channel) {
            let visibleStart = max(program.start, start)
            let visibleEnd = min(program.end, end)
            guard visibleEnd > visibleStart else { continue }
            let x = CGFloat(visibleStart.timeIntervalSince(start) / span) * totalWidth
            let width = CGFloat(visibleEnd.timeIntervalSince(visibleStart) / span) * totalWidth
            raw.append((program, visibleStart, visibleEnd, x, max(1.5, width - 1.2)))
        }
        var slices: [GuideSlice] = []
        slices.reserveCapacity(raw.count)
        for (index, item) in raw.enumerated() {
            let limit = index + 1 < raw.count ? raw[index + 1].x : totalWidth
            let width = max(1.5, min(item.width, limit - item.x - 1))
            slices.append(GuideSlice(program: item.program,
                                     visibleStart: item.vs,
                                     visibleEnd: item.ve,
                                     x: item.x,
                                     width: width))
        }
        // 频道级自适应：几十秒一档的碎片（8K 轮播、宣传片）单独画只剩一条细线。
        // 规则：足够宽的节目单独成块；连续的碎片聚成一段并标注档数；
        // 夹在空档里的孤立碎片直接忽略，保持时间轴的真实性。
        var merged: [GuideSlice] = []
        merged.reserveCapacity(slices.count)
        let microWidth: CGFloat = 20
        var pendingMicro: GuideSlice?
        func flushPending() {
            if let pending = pendingMicro { merged.append(pending) }
            pendingMicro = nil
        }
        for slice in slices {
            if slice.width >= microWidth {
                flushPending()
                merged.append(slice)
                continue
            }
            if var pending = pendingMicro,
               slice.x - (pending.x + pending.width) <= 10 {
                pending.width = max(pending.width, slice.x + slice.width - pending.x)
                pending.visibleEnd = max(pending.visibleEnd, slice.visibleEnd)
                pending.extraCount += slice.extraCount + 1
                pendingMicro = pending
            } else {
                flushPending()
                pendingMicro = slice
            }
        }
        flushPending()
        return merged
    }

    /// 半小时细线 + 整点稍重的竖线，横向贯穿整行。
    private func hourGrid(slotWidth: CGFloat) -> some View {
        Canvas { context, size in
            for index in 0...slotCount {
                let x = CGFloat(index) * slotWidth
                let isHour = index % 2 == 0
                context.fill(Path(CGRect(x: x, y: 0, width: 0.6, height: size.height)),
                             with: .color(Color.primary.opacity(isHour ? 0.07 : 0.03)))
            }
        }
        .frame(width: slotWidth * CGFloat(slotCount), height: guideRowHeight)
        .allowsHitTesting(false)
    }

    /// 一档节目：底色区分状态，左侧细色条区分前后节目，正在播带进度线。
    /// 信息量随块宽收敛：长时间窗里窄块只留色条和标题，宽块才显示完整时间、时长与状态，
    /// 不再让文字互相压住。
    private func programBlock(channel: TVChannel, slice: GuideSlice) -> some View {
        let program = slice.program
        let width = slice.width
        let minutes = max(1, Int(slice.visibleEnd.timeIntervalSince(slice.visibleStart) / 60))
        let live = program.isLive && dayOffset == 0
        let past = program.end <= Date() && !live
        let canCatchUp = !(channel.catchUpSource ?? "").isEmpty
        let isSelected = selected?.id == program.id
        let isHovered = hoveredGuideProgramID == program.id
        let tint = TVRingPalette.colors[Self.programTintIndex(program)]
        let fillOpacity: Double = {
            if live { return 0.30 }
            if isSelected { return 0.24 }
            if isHovered { return past ? 0.16 : 0.15 }
            if past { return canCatchUp ? 0.13 : 0.05 }
            return 0.09
        }()
        let accent: Color = live ? TVBrand.signal
            : (past && !canCatchUp ? Color.primary.opacity(0.16) : tint)
        let progress: Double? = {
            guard live else { return nil }
            let span = program.end.timeIntervalSince(program.start)
            guard span > 0 else { return nil }
            return min(1, max(0, Date().timeIntervalSince(program.start) / span))
        }()
        // 宽度分档：哪些信息值得占地方。
        let showsRange = width >= 104
        let showsTime = width >= 50
        let showsTitle = width >= 26
        let showsBadge = width >= 126
        let showsDuration = width >= 172
        let tight = width < 62
        let corner = min(8, max(3, width * 0.28))
        let blockTitle: String = {
            guard let label = slice.label else { return program.title }
            if slice.extraCount > 0, width >= 96 {
                return "\(label) 等 \(slice.extraCount + 1) 档"
            }
            return label
        }()
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { selected = program }
        } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(tint.opacity(fillOpacity))
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(isSelected ? TVBrand.gold.opacity(0.65)
                                             : (live ? TVBrand.signal.opacity(0.42)
                                                     : Color.primary.opacity(0.06)),
                                  lineWidth: isSelected ? 1 : 0.6)

                VStack(alignment: .leading, spacing: tight ? 1 : 3) {
                    if showsTime {
                        HStack(spacing: 5) {
                            Text(showsRange
                                 ? "\(clock(slice.visibleStart)) – \(clock(slice.visibleEnd))"
                                 : clock(slice.visibleStart))
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(live ? TVBrand.signal
                                                      : Color.primary.opacity(0.52))
                                .lineLimit(1)
                            if live, showsBadge {
                                Text("正在播")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(TVBrand.signal)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(TVBrand.signal.opacity(0.16),
                                                in: Capsule(style: .continuous))
                            } else if past, canCatchUp, showsBadge {
                                Text("可回看")
                                    .font(.system(size: 7.5, weight: .medium))
                                    .foregroundStyle(.secondary.opacity(0.85))
                            }
                            Spacer(minLength: 0)
                            if showsDuration {
                                Text("\(minutes) 分")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if showsTitle {
                        Text(blockTitle)
                            .font(.system(size: tight ? 9.5 : 11.5, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(past && !canCatchUp ? 0.5 : 0.95))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, tight ? 4 : 11)
                .padding(.trailing, tight ? 3 : 8)
                .padding(.vertical, tight ? 4 : 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if let progress {
                    GeometryReader { geo in
                        Capsule(style: .continuous)
                            .fill(TVBrand.signal.opacity(0.7))
                            .frame(width: max(0, geo.size.width * progress), height: 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomLeading)
                    }
                    .padding(.bottom, 1)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: guideRowHeight - 12)
            .overlay(alignment: .leading) {
                if width >= 18 {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(accent)
                        .frame(width: 2.6)
                        .padding(.vertical, 9)
                        .padding(.leading, 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredGuideProgramID = program.id
            } else if hoveredGuideProgramID == program.id {
                hoveredGuideProgramID = nil
            }
        }
        .help(slice.extraCount > 0
              ? "\(program.title) 等 \(slice.extraCount + 1) 档碎片节目 · \(timeRange(program))"
              : "\(program.title) · \(timeRange(program))")
    }

    /// 节目底色取自和时间环同一组配色，按开播时间稳定取色。
    private static func programTintIndex(_ program: TVEPGProgram) -> Int {
        let slot = Int(program.start.timeIntervalSince1970 / 1800)
        return abs(slot) % TVRingPalette.colors.count
    }

    private func nowLine(slotWidth: CGFloat) -> some View {
        Group {
            if dayOffset == 0, Date() >= windowStart, Date() < windowEnd {
                let fraction = Date().timeIntervalSince(windowStart)
                    / windowEnd.timeIntervalSince(windowStart)
                VStack(spacing: 0) {
                    Circle()
                        .fill(TVBrand.signal)
                        .frame(width: 6, height: 6)
                    Rectangle()
                        .fill(LinearGradient(colors: [TVBrand.signal,
                                                      TVBrand.signal.opacity(0.22)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 1.4)
                }
                .frame(maxHeight: .infinity)
                .offset(x: 22 + channelColumnWidth
                        + slotWidth * CGFloat(slotCount) * fraction - 3)
                .allowsHitTesting(false)
            }
        }
    }

    private func slotStart(_ slot: Int) -> Date {
        windowStart.addingTimeInterval(TimeInterval(slot * slotMinutes * 60))
    }

    // MARK: - 传送门 / 时间环

    /// 传送门：与时间环共用左侧频道与顶部日期，中间是一扇回到某一天的门。
    private var guidePortal: some View {
        HStack(spacing: 0) {
            guideChannelRail
            Rectangle().fill(TVBrand.hairline).frame(width: 0.8)
            TVCatchupView(day: selectedDayBinding,
                          selectedID: $guideChannelID,
                          channel: guideChannel)
        }
    }

    /// 日期与传送门共用：传送门里换日时，顶部日期胶囊同步。
    private var selectedDayBinding: Binding<Date> {
        Binding(
            get: { selectedDay },
            set: { newValue in
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                let target = calendar.startOfDay(for: newValue)
                let offset = calendar.dateComponents([.day], from: today, to: target).day ?? 0
                dayOffset = min(2, max(-2, offset))
            }
        )
    }

    /// 时间环：把一整天卷成一个表盘。指针扫过哪一段，中央就显示那一档节目，可直接播放。
    /// 指针 / 悬停状态都收在 `TVTimeRingStage` 里：拖动时只有表盘重绘，
    /// 左侧频道栏和顶部日期条不再跟着重算。
    private var guideRing: some View {
        HStack(spacing: 0) {
            guideChannelRail
            Rectangle().fill(TVBrand.hairline).frame(width: 0.8)
            TVTimeRingStage(day: selectedDay,
                            dayOffset: dayOffset,
                            channel: guideChannel,
                            programs: ringPrograms,
                            dayLabel: ringDayLabel,
                            resetToken: "\(guideChannel?.id ?? "-")-\(selectedDay.timeIntervalSince1970)-\(ringResetTick)")
        }
    }

    private var guideChannel: TVChannel? {
        if let id = guideChannelID,
           let channel = channelsWithEPG.first(where: { $0.id == id }) {
            return channel
        }
        if let playing = playingChannelID,
           let channel = channelsWithEPG.first(where: { $0.id == playing }) {
            return channel
        }
        return channelsWithEPG.first
    }

    private var ringProgramsKeyNow: String {
        "\(guideChannel?.id ?? "-")-\(selectedDay.timeIntervalSince1970)-\(tv.epgPrograms.count)"
    }

    private var ringPrograms: [TVEPGProgram] {
        if ringProgramsKey == ringProgramsKeyNow { return ringProgramsCache }
        return computeRingPrograms()
    }

    private func computeRingPrograms() -> [TVEPGProgram] {
        guard let channel = guideChannel else { return [] }
        return tv.programs(on: selectedDay, for: channel)
    }

    private var guideChannelRail: some View {
        // 选中频道只查一次：每行都去 first(where:) 会退化成 O(n²)。
        let activeID = guideChannel?.id
        let playingID = playingChannelID
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(guideMode == .portal ? "可回看频道" : "转动的频道")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(channelsWithEPG.count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(channelsWithEPG) { channel in
                        guideChannelRow(channel, activeID: activeID, playingID: playingID)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 218, alignment: .top)
    }

    private func guideChannelRow(_ channel: TVChannel,
                                 activeID: String?,
                                 playingID: String?) -> some View {
        let active = channel.id == activeID
        let live = channel.id == playingID
        return Button {
            withAnimation(.easeOut(duration: 0.22)) {
                guideChannelID = channel.id
                selected = nil
            }
        } label: {
            HStack(spacing: 8) {
                Text(String(format: "%02d", tv.channelNumber(for: channel)))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(active ? TVBrand.gold : Color.secondary)
                    .frame(width: 26, alignment: .leading)
                TVLogoImage(urlString: channel.logoURL,
                            size: CGSize(width: 32, height: 20),
                            cornerRadius: 4)
                Text(channel.name)
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if live {
                    Circle().fill(TVBrand.signal).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(active ? TVBrand.gold.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var ringDayLabel: String {
        let name = guideDayTitle(dayOffset)
        let date = selectedDay.formatted(.dateTime.month(.defaultDigits).day())
        let weekday = selectedDay.formatted(.dateTime.weekday(.abbreviated))
        return "\(name) · \(date) \(weekday)"
    }

    private var playingChannelID: String? {
        guard let viewerID = store.viewerID else { return nil }
        return store.tvPlaybackChannel(for: viewerID)?.id
    }

    private func programChannel(_ program: TVEPGProgram) -> TVChannel {
        channelsWithEPG.first {
            tv.programs(on: selectedDay, for: $0).contains(where: { $0.id == program.id })
        } ?? channelsWithEPG[0]
    }

    private func detailBand(_ program: TVEPGProgram) -> some View {
        let channel = programChannel(program)
        let past = program.end <= Date()
        let canCatchUp = past && !(channel.catchUpSource ?? "").isEmpty
        return HStack(spacing: 10) {
            TVLogoImage(urlString: channel.logoURL,
                        size: CGSize(width: 46, height: 27),
                        cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(program.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(program.isLive && dayOffset == 0 ? "正在播" : (past ? "已播" : "待播"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(program.isLive && dayOffset == 0 ? TVBrand.signal : Color.secondary)
                }
                Text("\(channel.name) · \(timeRange(program)) · \(Int(program.duration / 60)) 分钟")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // 节目摘要：优先用 EPG 简介，没有就按节目名 / 时段兜底，稳定两行。
                Text(programSummary(program))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if program.isLive, dayOffset == 0 {
                Button("播放直播") { store.openTVChannel(channel) }
                    .controlSize(.small)
            }
            Button("回看") {
                store.openTVCatchup(channel, program: program)
            }
            .controlSize(.small)
            .disabled(!canCatchUp)
            .help(canCatchUp ? "回看这档节目" : "该源未声明回看，或节目尚未结束")
            if program.start > Date() {
                let reminded = tv.isReminded(program)
                Button(reminded ? "已预约" : "预约") {
                    tv.toggleReminder(program, channel: channel)
                }
                .controlSize(.small)
                .help(reminded ? "点击取消开播提醒" : "节目开播时用系统通知提醒")
            }
            if program.end > Date() {
                let scheduled = tv.pendingRecordings.contains {
                    $0.channelID == channel.id && $0.title == program.title
                        && abs($0.start.timeIntervalSince(program.start)) < 60
                }
                Button(scheduled ? "已排录制" : "录制") {
                    tv.scheduleRecording(channel: channel, program: program)
                }
                .controlSize(.small)
                .disabled(scheduled)
                .help("节目开始后自动录进图库")
            }
            Button {
                tv.toggleSubscription(program, channel: channel)
            } label: {
                Image(systemName: tv.isSubscribed(program) ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tv.isSubscribed(program) ? TVBrand.gold : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(tv.isSubscribed(program)
                  ? "取消追这档节目"
                  : "追这档节目：未来几天的同名播出自动提醒")
            Button {
                tv.toggleFavorite(channel)
            } label: {
                Image(systemName: tv.isFavorite(channel) ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tv.isFavorite(channel) ? TVBrand.gold : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(tv.isFavorite(channel) ? "取消收藏 \(channel.name)" : "收藏 \(channel.name)")
            Button {
                withAnimation(.easeOut(duration: 0.18)) { selected = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("收起节目详情")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(TVBrand.surface)
    }

    private var emptyState: some View {
        emptyState(message: tv.epgError ?? "当前源没有提供 EPG 节目单。")
    }

    private func emptyState(message: String) -> some View {
        LumaEmptyState(symbol: "calendar.badge.exclamationmark",
                       title: "还没有节目单",
                       message: message + "\nM3U 头部需要 url-tvg / x-tvg-url；也可以在「源库」的源菜单里填写 XMLTV 地址。")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clock(_ date: Date) -> String {
        Self.guideClockFormatter.string(from: date)
    }

    private func timeRange(_ program: TVEPGProgram) -> String {
        "\(clock(program.start)) – \(clock(program.end))"
    }

    /// 两行节目摘要：优先用 EPG 简介，清洗 HTML 与多余空白；没有简介时用确定信息兜底。
    private func programSummary(_ program: TVEPGProgram) -> String {
        let raw = (program.overview ?? program.subtitle ?? "")
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        let minutes = max(1, Int(program.duration / 60))
        return "\(program.title) · \(timeRange(program)) · 时长约 \(minutes) 分钟。"
    }

    private static let guideClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 传送门

/// 传送门：按天回到某一天的节目。日期与频道由「节目回看」统一管理，
/// 这里只负责这一扇门与节目列表，和左侧频道栏、顶部日期胶囊实时同步。
private struct TVCatchupView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel
    @Environment(\.colorScheme) private var scheme

    private var isLight: Bool { scheme == .light }
    /// 门内的正文 / 次要读数 / 提示：暗色是白字，浅色是深字。
    private var portalSecondaryInk: Color {
        isLight ? Color.black.opacity(0.58) : Color.white.opacity(0.55)
    }
    private var portalTertiaryInk: Color {
        isLight ? Color.black.opacity(0.42) : Color.white.opacity(0.38)
    }
    private var portalHintInk: Color {
        isLight ? Color.black.opacity(0.32) : Color.white.opacity(0.30)
    }

    /// 与时间轴 / 时间环共用的日期与当前频道。
    @Binding var day: Date
    @Binding var selectedID: String?
    /// 左栏当前频道：没选中时由外层给出兜底，保证三视图看到的是同一台。
    var channel: TVChannel?

    @State private var query = ""
    /// 时间门：悬停的日期、穿越时的收束动画、节目列表的重放计数。
    @State private var hoveredDay: Date?
    @State private var portalTravel = false
    @State private var crossTick = 0

    /// 时间门保留五天：前天 / 昨天 / 今天 / 明天 / 后天。历史用于回看，未来用于预约。
    private var days: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (-2...2).compactMap {
            Calendar.current.date(byAdding: .day, value: $0, to: today)
        }
    }

    private var catchupChannels: [TVChannel] {
        tv.visibleChannels.filter { !($0.catchUpSource ?? "").isEmpty }
    }

    private var selectedChannel: TVChannel? {
        if let selectedID, let match = tv.visibleChannels.first(where: { $0.id == selectedID }) {
            return match
        }
        return channel ?? catchupChannels.first ?? tv.visibleChannels.first
    }

    private var selectedPrograms: [TVEPGProgram] {
        guard let channel = selectedChannel else { return [] }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = tv.programs(on: day, for: channel)
        guard !keyword.isEmpty else { return list }
        return list.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
                || channel.name.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        programPane
            .task { tv.loadEPGIfNeeded() }
            .onChange(of: tv.focusedPlaylistID) { _, _ in
                selectedID = nil
            }
    }

    /// 概念 B · 时间门：回看不是「往后拖进度条」，而是「去某一天」。
    private var programPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                breadcrumb
                Spacer(minLength: 0)
                searchField
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        timePortal
                            .id(Self.programPaneTopID)
                        if let channel = selectedChannel {
                            if (channel.catchUpSource ?? "").isEmpty {
                                messageState("该源未声明回看",
                                             detail: "这个频道会保留在列表里，但回看入口不可用。换一个声明了 catchup-source 的源。")
                                    .frame(height: 180)
                            } else if selectedPrograms.isEmpty {
                                messageState("这一天没有节目",
                                             detail: query.isEmpty ? "节目单里没有这天的记录，换一天看看。" : "没有匹配「\(query)」的节目。")
                                    .frame(height: 180)
                            } else {
                                LazyVStack(spacing: 6) {
                                    ForEach(selectedPrograms) { program in
                                        tunnelProgramRow(channel: channel, program: program)
                                    }
                                }
                                // 换日 / 换台 / 穿越时整段节目列表重新淡入，滚动位置回到顶部。
                                .id("\(channel.id)-\(Int(day.timeIntervalSince1970))-\(crossTick)")
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        } else {
                            messageState("没有可用的频道", detail: "当前筛选下没有频道。")
                                .frame(height: 180)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
                // 切换频道 / 日期后整页回到顶部，不沿用上一个频道的滚动位置。
                .onChange(of: selectedChannel?.id) { _, _ in
                    scrollProgramPaneToTop(proxy)
                }
                .onChange(of: day) { _, _ in
                    scrollProgramPaneToTop(proxy)
                }
                .onChange(of: crossTick) { _, _ in
                    scrollProgramPaneToTop(proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static let programPaneTopID = "programPane.top"

    private func scrollProgramPaneToTop(_ proxy: ScrollViewProxy) {
        // 等新频道的列表完成布局后再定位，否则会停在旧内容的高度。
        DispatchQueue.main.async {
            proxy.scrollTo(Self.programPaneTopID, anchor: .top)
        }
    }

    /// 面包屑：现在 → 所选那天 → 频道。
    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Text("现在 \(clock(Date()))")
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
            Text("\(dayTitle(day)) · \(selectedPrograms.count) 档")
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
            Text(selectedChannel?.name ?? "—")
                .foregroundStyle(TVBrand.gold)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(TVBrand.panel, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
    }

    /// 时间门：一圈全息传送环，日期分布在光环上。
    /// 拖动光环 / 点左右箭头换日，点中心「穿越」进入那一天的节目。
    private var timePortal: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("TIME GATE")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(TVBrand.wave.opacity(0.85))
                Text("回看 · 时间门")
                    .font(.system(size: 9.5))
                    .foregroundStyle(portalTertiaryInk)
                Spacer(minLength: 0)
                if !Calendar.current.isDateInToday(day) {
                    Button("回到现在") {
                        selectDay(Calendar.current.startOfDay(for: Date()))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(TVBrand.wave)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(TVBrand.wave.opacity(0.10), in: Capsule(style: .continuous))
                }
                portalArrow("chevron.left",
                            enabled: selectedIndex > 0,
                            help: "回到更早一天") { stepDay(-1) }
                portalArrow("chevron.right",
                            enabled: selectedIndex < days.count - 1,
                            help: "回到更新一天") { stepDay(1) }
            }

            GeometryReader { proxy in
                let side = max(220, min(proxy.size.width, proxy.size.height) * 0.9)
                ZStack {
                    portalStage(side: side)
                    // 竖立的传送门：整体向后倾 15°，圆环压成椭圆，像一扇立在底座上的门。
                    ZStack {
                        portalRing(side: side)
                        portalCenter(side: side)
                        portalDayMarkers(side: side)
                    }
                    .rotation3DEffect(.degrees(15), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
                    .scaleEffect(portalTravel ? 1.5 : 1)
                    .opacity(portalTravel ? 0.08 : 1)
                    .animation(.easeIn(duration: 0.28), value: portalTravel)

                    // 穿越瞬间：一圈白光从门心向外扩。
                    if portalTravel {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                            .frame(width: side * 0.62, height: side * 0.62)
                            .scaleEffect(1.9)
                            .blur(radius: 5)
                            .shadow(color: TVBrand.wave.opacity(0.8), radius: 14)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .gesture(portalDrag(side: side))
            }
            .frame(height: 320)

            portalDataBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background { portalBackdrop }
    }

    /// 传送门背景：暗色是黑曜石暗场，浅色是带一点紫雾的暖白。
    private var portalBackdrop: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: isLight
                                 ? [Color(red: 0.985, green: 0.98, blue: 0.972),
                                    Color(red: 0.925, green: 0.918, blue: 0.945)]
                                 : [Color(red: 0.035, green: 0.03, blue: 0.065),
                                    Color.black.opacity(0.78)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RadialGradient(colors: [Color(red: 0.42, green: 0.26, blue: 0.95)
                                            .opacity(isLight ? 0.12 : 0.22),
                                        Color(red: 0.20, green: 0.55, blue: 1.0)
                                            .opacity(isLight ? 0.06 : 0.07),
                                        .clear],
                               center: .center, startRadius: 20, endRadius: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(red: 0.55, green: 0.45, blue: 1)
                        .opacity(isLight ? 0.18 : 0.22),
                                  lineWidth: 0.8)
            }
    }

    /// 门下方的底座：参考传送门的椭圆基座，前沿一道冷光边。
    private func portalStage(side: CGFloat) -> some View {
        ZStack {
            // 地面光斑
            Ellipse()
                .fill(RadialGradient(colors: [Color(red: 0.45, green: 0.30, blue: 1)
                                                  .opacity(isLight ? 0.18 : 0.30),
                                              .clear],
                                     center: .center, startRadius: 0, endRadius: side * 0.44))
                .frame(width: side * 0.94, height: 54)
                .blur(radius: 8)
                .offset(y: side * 0.30)
            // 底盘：暗色是深紫金属面，浅色是浅紫瓷面。
            Ellipse()
                .fill(LinearGradient(colors: isLight
                                     ? [Color(red: 0.95, green: 0.94, blue: 0.99),
                                        Color(red: 0.80, green: 0.79, blue: 0.90)]
                                     : [Color(red: 0.14, green: 0.10, blue: 0.28),
                                        Color(red: 0.04, green: 0.03, blue: 0.09)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: side * 0.76, height: 46)
                .offset(y: side * 0.30)
            // 底盘前沿：青→紫的高光边
            Ellipse()
                .stroke(LinearGradient(colors: [Color(red: 0.35, green: 0.85, blue: 1).opacity(0.95),
                                                Color(red: 0.72, green: 0.40, blue: 1).opacity(0.35),
                                                Color(red: 0.35, green: 0.85, blue: 1).opacity(0.55)],
                                       startPoint: .leading, endPoint: .trailing),
                        lineWidth: 2.4)
                .frame(width: side * 0.76, height: 46)
                .blur(radius: 0.6)
                .offset(y: side * 0.30)
            // 内圈凹槽
            Ellipse()
                .stroke(isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.14),
                        lineWidth: 0.8)
                .frame(width: side * 0.60, height: 30)
                .offset(y: side * 0.29)
            Ellipse()
                .stroke(Color(red: 0.85, green: 0.40, blue: 0.70)
                    .opacity(isLight ? 0.35 : 0.45), lineWidth: 1.6)
                .frame(width: side * 0.46, height: 20)
                .blur(radius: 1.2)
                .offset(y: side * 0.285)
        }
        .allowsHitTesting(false)
    }

    /// 传输环本体：外圈分段光带 + 秒刻度 + 内圈门弧。
    private func portalRing(side: CGFloat) -> some View {
        let r = side / 2 - 26
        let gateAngle = portalAngle(for: day)
        return ZStack {
            // 外层柔光
            Circle()
                .stroke(AngularGradient(gradient: Gradient(colors: [
                    Color(red: 0.55, green: 0.40, blue: 1),
                    Color(red: 0.25, green: 0.78, blue: 1),
                    Color(red: 0.95, green: 0.35, blue: 0.68),
                    Color(red: 0.55, green: 0.40, blue: 1)
                ]), center: .center), lineWidth: 10)
                .frame(width: r * 2, height: r * 2)
                .blur(radius: 18)
                .opacity(isLight ? 0.34 : 0.48)

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                // 外圈：48 段光带，每 4 段加粗一次。
                let segments = 48
                for index in 0..<segments {
                    let a0 = Double(index) / Double(segments) * 360 + 1.1
                    let a1 = a0 + 360 / Double(segments) - 2.2
                    var path = Path()
                    path.addArc(center: center, radius: r,
                                startAngle: .degrees(a0 - 90),
                                endAngle: .degrees(a1 - 90),
                                clockwise: false)
                    let t = Double(index) / Double(segments)
                    let color = Color(red: 0.30 + 0.52 * t,
                                      green: 0.74 - 0.20 * t,
                                      blue: 1.0)
                    context.stroke(path,
                                   with: .color(color.opacity(isLight ? 0.78 : 0.58)),
                                   style: StrokeStyle(lineWidth: index % 4 == 0 ? 2.8 : 1.2,
                                                      lineCap: .round))
                }

                // 秒刻度：短、密、贴在环内侧。
                for index in 0..<60 {
                    let angle = Double(index) / 60 * 360 - 90
                    let outer = r - 6
                    let inner = r - (index % 5 == 0 ? 16 : 11)
                    var path = Path()
                    path.move(to: CGPoint(x: center.x + CGFloat(cos(angle * .pi / 180)) * inner,
                                          y: center.y + CGFloat(sin(angle * .pi / 180)) * inner))
                    path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle * .pi / 180)) * outer,
                                             y: center.y + CGFloat(sin(angle * .pi / 180)) * outer))
                    context.stroke(path,
                                   with: .color(Color.primary.opacity(index % 5 == 0 ? 0.26 : 0.10)),
                                   style: StrokeStyle(lineWidth: index % 5 == 0 ? 1 : 0.5,
                                                      lineCap: .round))
                }

                // 内圈细线
                let innerRect = CGRect(x: center.x - (r - 30),
                                       y: center.y - (r - 30),
                                       width: (r - 30) * 2,
                                       height: (r - 30) * 2)
                context.stroke(Path(ellipseIn: innerRect),
                               with: .color(Color.primary.opacity(0.10)),
                               style: StrokeStyle(lineWidth: 1))

                // 门框内沿：白热高光 + 冷光边
                let rimRect = CGRect(x: center.x - (r - 15),
                                     y: center.y - (r - 15),
                                     width: (r - 15) * 2,
                                     height: (r - 15) * 2)
                context.stroke(Path(ellipseIn: rimRect),
                               with: .color(isLight ? Color.primary.opacity(0.55)
                                                    : Color.white.opacity(0.65)),
                               style: StrokeStyle(lineWidth: 1.4))
                context.stroke(Path(ellipseIn: rimRect.insetBy(dx: -2, dy: -2)),
                               with: .color(Color(red: 0.55, green: 0.72, blue: 1).opacity(0.30)),
                               style: StrokeStyle(lineWidth: 5))

                // 选中那一天的门弧：青 → 品红。
                var gate = Path()
                gate.addArc(center: center, radius: r - 18,
                            startAngle: .degrees(gateAngle - 90 - 32),
                            endAngle: .degrees(gateAngle - 90 + 32),
                            clockwise: false)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Color(red: 0.35, green: 0.88, blue: 1),
                                      Color(red: 0.95, green: 0.36, blue: 0.70)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: size.width, y: size.height))
                context.stroke(gate,
                               with: .color(Color(red: 0.35, green: 0.85, blue: 1).opacity(0.28)),
                               style: StrokeStyle(lineWidth: 14, lineCap: .round))
                context.stroke(gate, with: shading,
                               style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            .frame(width: side, height: side)
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }

    /// 日期节点：今天在正上方，明天在右、昨天在左、前天在下方。
    private func portalDayMarkers(side: CGFloat) -> some View {
        let radius = side / 2 - 26
        return ZStack {
            ForEach(days, id: \.self) { date in
                let angle = portalAngle(for: date) * .pi / 180
                let selected = Calendar.current.isDate(date, inSameDayAs: day)
                let hovered = hoveredDay.map {
                    Calendar.current.isDate($0, inSameDayAs: date)
                } ?? false
                let ink: Color = selected
                    ? Color.black.opacity(0.82)
                    : (isLight ? Color.black.opacity(hovered ? 0.82 : 0.55)
                               : Color.white.opacity(hovered ? 0.86 : 0.52))
                let fill: Color = selected
                    ? TVBrand.wave
                    : (isLight ? Color.white.opacity(0.88) : Color.black.opacity(0.55))
                let border: Color = selected
                    ? Color.clear
                    : (isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.12))
                Button {
                    selectDay(date)
                } label: {
                    VStack(spacing: 1) {
                        Text(dayNumber(date))
                            .font(.system(size: selected ? 12 : 10,
                                          weight: selected ? .bold : .medium,
                                          design: .monospaced))
                        Text(dayTitle(date))
                            .font(.system(size: 7, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(fill, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(border, lineWidth: 0.5)
                    }
                    .scaleEffect(selected ? 1.06 : (hovered ? 1.02 : 0.94))
                    .shadow(color: selected ? TVBrand.wave.opacity(0.55) : .clear,
                            radius: 8)
                }
                .buttonStyle(.plain)
                .position(x: side / 2 + CGFloat(cos(angle)) * radius,
                          y: side / 2 + CGFloat(sin(angle)) * radius)
                .onHover { inside in
                    if inside {
                        hoveredDay = date
                    } else if hoveredDay.map({
                        Calendar.current.isDate($0, inSameDayAs: date)
                    }) == true {
                        hoveredDay = nil
                    }
                }
                .help("穿越到 \(dayTitle(date))")
            }
        }
        .frame(width: side, height: side)
    }

    /// 环心：日期、节目数、穿越按钮。
    private func portalCenter(side: CGFloat) -> some View {
        let r = side / 2 - 26
        let weekday = day.formatted(.dateTime.weekday(.wide))
        let monthDay = day.formatted(.dateTime.month(.defaultDigits).day())
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: isLight
                                     ? [Color.white.opacity(0.95), Color.white.opacity(0.10)]
                                     : [Color.black.opacity(0.80), Color.black.opacity(0.16)],
                                     center: .center, startRadius: 10, endRadius: r * 0.82))
                .frame(width: r * 1.72, height: r * 1.72)

            // 门内光雾：一团品红、一团冷蓝，慢慢在门里晃。
            ZStack {
                Circle()
                    .fill(Color(red: 0.95, green: 0.35, blue: 0.68)
                        .opacity(isLight ? 0.22 : 0.30))
                    .frame(width: r * 0.62, height: r * 0.62)
                    .offset(x: -r * 0.30, y: -r * 0.12)
                    .blur(radius: 26)
                Circle()
                    .fill(Color(red: 0.35, green: 0.58, blue: 1)
                        .opacity(isLight ? 0.20 : 0.28))
                    .frame(width: r * 0.70, height: r * 0.70)
                    .offset(x: r * 0.34, y: r * 0.14)
                    .blur(radius: 30)
                Circle()
                    .fill(Color(red: 0.95, green: 0.35, blue: 0.68)
                        .opacity(isLight ? 0.12 : 0.16))
                    .frame(width: r * 0.42, height: r * 0.42)
                    .offset(x: r * 0.20, y: -r * 0.32)
                    .blur(radius: 20)
            }
            .frame(width: r * 1.72, height: r * 1.72)
            .clipShape(Circle())
            .allowsHitTesting(false)

            VStack(spacing: 3) {
                Text(Calendar.current.isDateInToday(day) ? "现在" : dayTitle(day))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(TVBrand.wave.opacity(0.85))
                Text(dayNumber(day))
                    .font(.system(size: 54, weight: .thin, design: .serif))
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
                Text("\(weekday) · \(monthDay)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(portalSecondaryInk)
                Text("\(selectedPrograms.count) 档节目 · \(catchupChannels.count) 个频道可回看")
                    .font(.system(size: 9))
                    .foregroundStyle(portalTertiaryInk)
                    .lineLimit(1)
                Button {
                    crossDay()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("穿越")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(LinearGradient(colors: [TVBrand.wave,
                                                        Color(red: 0.72, green: 0.45, blue: 1)],
                                               startPoint: .leading, endPoint: .trailing),
                                in: Capsule(style: .continuous))
                    .shadow(color: TVBrand.wave.opacity(0.45), radius: 10, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(width: r * 1.35)
        }
        .frame(width: side, height: side)
        .allowsHitTesting(true)
    }

    /// 日期数据条：所选日期的日期 / 星期 / 节目数 / 可回看频道 / 时段。
    private var portalDataBar: some View {
        HStack(spacing: 14) {
            portalDataCell("日期", day.formatted(.dateTime.month(.defaultDigits).day()))
            portalDataCell("星期", day.formatted(.dateTime.weekday(.wide)))
            portalDataCell("节目", "\(selectedPrograms.count) 档")
            portalDataCell("可回看", "\(catchupChannels.count) 个频道")
            if let first = selectedPrograms.first, let last = selectedPrograms.last {
                portalDataCell("时段", "\(clock(first.start)) – \(clock(last.end))")
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 9, weight: .semibold))
                Text("拖动光环或点日期换日")
                    .font(.system(size: 9))
            }
            .foregroundStyle(portalHintInk)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }

    private func portalDataCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(portalHintInk)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isLight ? Color.black.opacity(0.78)
                                         : Color.white.opacity(0.76))
        }
    }

    /// 沿光环拖动换日：按角度找最近的日期节点。
    private func portalDrag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let index = portalIndex(at: value.location, side: side),
                      days.indices.contains(index) else { return }
                guard !Calendar.current.isDate(days[index], inSameDayAs: day) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    day = days[index]
                }
            }
    }

    private func portalIndex(at point: CGPoint, side: CGFloat) -> Int? {
        let center = CGPoint(x: side / 2, y: side / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard hypot(dx, dy) > side * 0.26 else { return nil }
        var angle = atan2(dy, dx) * 180 / .pi
        if angle < 0 { angle += 360 }
        var best = 0
        var bestDelta = 360.0
        for (index, date) in days.enumerated() {
            var marker = portalAngle(for: date)
            while marker < 0 { marker += 360 }
            while marker >= 360 { marker -= 360 }
            let raw = abs(angle - marker)
            let delta = min(raw, 360 - raw)
            if delta < bestDelta {
                bestDelta = delta
                best = index
            }
        }
        return best
    }

    /// 时间门上的角度：今天在正上方，明天在右、昨天在左、前天在下方。
    private func portalAngle(for date: Date) -> Double {
        let today = Calendar.current.startOfDay(for: Date())
        let target = Calendar.current.startOfDay(for: date)
        let offset = Calendar.current.dateComponents([.day], from: today, to: target).day ?? 0
        // 四个节点均分一圈：今天在正上方，明天在右、昨天在左、前天在下方。
        let step = 360.0 / Double(max(1, days.count))
        return -90 + Double(offset) * step
    }

    private func portalArrow(_ symbol: String,
                             enabled: Bool,
                             help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? Color.white.opacity(0.82)
                                         : Color.white.opacity(0.20))
                .frame(width: 26, height: 22)
                .background(Color.white.opacity(enabled ? 0.07 : 0.03),
                            in: Capsule(style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// 穿越：门向前一冲、白光扩散，节目列表从底部重新淡入。
    private func crossDay() {
        guard !portalTravel else { return }
        store.showToast("穿越到 \(dayTitle(day)) · \(selectedChannel?.name ?? "")")
        crossTick += 1
        withAnimation(.easeIn(duration: 0.2)) { portalTravel = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            withAnimation(.easeOut(duration: 0.46)) { portalTravel = false }
        }
    }

    private var selectedIndex: Int {
        days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) } ?? 0
    }

    private func dayNumber(_ date: Date) -> String {
        Self.portalDayFormatter.string(from: date)
    }

    private static let portalDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d"
        return formatter
    }()

    private func stepDay(_ delta: Int) {
        guard !days.isEmpty else { return }
        let target = min(days.count - 1, max(0, selectedIndex + delta))
        selectDay(days[target])
    }

    private func selectDay(_ date: Date) {
        guard !Calendar.current.isDate(date, inSameDayAs: day) else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            day = date
        }
    }

    private func tunnelProgramRow(channel: TVChannel, program: TVEPGProgram) -> some View {
        let past = program.end <= Date()
        let live = program.isLive
        let future = program.start > Date()
        let catchUp = past && !(channel.catchUpSource ?? "").isEmpty
        let reminded = tv.isReminded(program)
        return Button {
            if live {
                store.openTVChannel(channel)
            } else if catchUp {
                store.openTVCatchup(channel, program: program)
            } else if future {
                tv.toggleReminder(program, channel: channel)
            }
        } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.16),
                                                  Color.black.opacity(0.35)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 26)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    }
                Text(clock(program.start))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(live ? TVBrand.signal : TVBrand.gold)
                    .frame(width: 44, alignment: .leading)
                Text(program.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(Int(program.duration / 60)) 分")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(live ? "直播" : (catchUp ? "回看" : (future ? (reminded ? "已预约" : "预约") : "已结束")))
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(live ? TVBrand.onGold
                                          : (catchUp ? TVBrand.onGold
                                                     : (future ? TVBrand.gold : Color.secondary.opacity(0.6))))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(live ? TVBrand.signal
                                     : (catchUp ? TVBrand.gold
                                                : Color.clear),
                                in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(future ? TVBrand.gold.opacity(0.45) : Color.clear,
                                      lineWidth: 0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(live ? TVBrand.signal.opacity(0.08) : TVBrand.surface,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(live ? TVBrand.signal.opacity(0.35) : TVBrand.stroke, lineWidth: 0.7))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!live && !catchUp && !future)
        .opacity(past && !catchUp ? 0.55 : 1)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("搜索节目", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 9)
        .frame(width: 176, height: 24)
        .background(TVBrand.panel, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
    }

    private func messageState(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let today = calendar.startOfDay(for: Date())
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "明天" }
        if let before = calendar.date(byAdding: .day, value: -2, to: today),
           calendar.isDate(date, inSameDayAs: before) { return "前天" }
        if let before = calendar.date(byAdding: .day, value: -3, to: today),
           calendar.isDate(date, inSameDayAs: before) { return "大前天" }
        if let after = calendar.date(byAdding: .day, value: 2, to: today),
           calendar.isDate(date, inSameDayAs: after) { return "后天" }
        if let after = calendar.date(byAdding: .day, value: 3, to: today),
           calendar.isDate(date, inSameDayAs: after) { return "大后天" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    private func clock(_ date: Date) -> String {
        Self.catchupClockFormatter.string(from: date)
    }

    private static let catchupClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 总览

/// 网络电视总览：与「网络存储 · 存储」页同构——大标题 + 聚合入口 + 源卡片，
/// 源卡片上直接完成启用、检测与进入频道墙。
private struct TVOverviewView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var epgEditingID: UUID?
    @State private var epgDraft = ""
    /// 拖动源时的落点行：画一条提示线。
    @State private var dropTargetID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                aggregateCard
                if tv.playlists.isEmpty {
                    emptyState
                } else {
                    sourceList
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("重命名电视源", isPresented: Binding(get: { renamingID != nil },
                                              set: { if !$0 { renamingID = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renamingID = nil }
            Button("保存") {
                if let id = renamingID { tv.renamePlaylist(id, to: renameText) }
                renamingID = nil
            }
        } message: {
            Text("只改显示名称，播放地址不变。")
        }
        .sheet(isPresented: Binding(get: { epgEditingID != nil },
                                   set: { if !$0 { epgEditingID = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("EPG 节目单地址")
                    .font(.system(size: 15, weight: .semibold))
                Text("填写 XMLTV 地址后，「节目单」与「回看」会用它匹配频道。留空表示不额外使用该源的 EPG；拾光还会自动合并内置的公共补充节目单（历史 3 天、未来 3 天）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("https://example.com/epg.xml", text: $epgDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("取消") { epgEditingID = nil }
                    Button("保存") {
                        if let id = epgEditingID {
                            tv.setEPGURL(epgDraft, for: id)
                        }
                        epgEditingID = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 440)
        }
    }

    /// 检测 / 导入：从前一行标题区挪到「电视源」分组标题右侧。
    private var sourceActions: some View {
        HStack(spacing: 8) {
            if tv.isChecking {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("检测中")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                tv.checkAllSources()
            } label: {
                Label("检测全部", systemImage: "bolt.horizontal.circle")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(TVBrand.panel, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(tv.isChecking)
            .help("按顺序逐一检测每个已启用的电视源")
            Button {
                tv.showWizard = true
            } label: {
                Label("接入电视源", systemImage: "plus")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(TVBrand.wave)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(TVBrand.panel, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            transferMenu
        }
    }

    /// 电视源导出：导入统一收进「接入电视源」，这里只负责分享给其他人。
    private var transferMenu: some View {
        SourceExportButton(scope: .television,
                           count: tv.playlists.count,
                           exportData: { tv.exportPlaylistBundle() })
    }

    /// 聚合入口：所有已启用源合并成一堵频道墙。
    private var aggregateCard: some View {
        Button {
            tv.focusAllSources()
            tv.setHubTab(.channels)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [TVBrand.wave, TVBrand.signal],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.78))
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("全频直播")
                            .font(.system(size: 15, weight: .semibold))
                        Text("聚合")
                            .font(.system(size: 9))
                            .foregroundStyle(TVBrand.wave)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(TVBrand.wave.opacity(0.14),
                                        in: Capsule(style: .continuous))
                    }
                    Text("\(tv.playlists.filter(\.isEnabled).count) 个源 · \(tv.aggregateChannelCount) 个频道合并展示")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(TVBrand.cardTop)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(TVBrand.wave.opacity(0.35), lineWidth: 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(tv.aggregateChannelCount == 0)
        .help("不区分来源，展示所有已启用源的全部频道")
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("电视源")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(tv.playlists.filter(\.isEnabled).count) / \(tv.playlists.count) 已启用")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                sourceActions
            }
            LazyVStack(spacing: 10) {
                ForEach(tv.playlists) { playlist in
                    sourceRow(playlist)
                        .overlay(alignment: .top) {
                            if dropTargetID == playlist.id {
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                    .padding(.horizontal, 10)
                            }
                        }
                        .onDrop(of: [tvSourceDragType],
                                delegate: TVSourceReorderDropDelegate(
                                    target: playlist.id,
                                    tv: tv,
                                    onTargeted: { targeted in
                                        if targeted {
                                            dropTargetID = playlist.id
                                        } else if dropTargetID == playlist.id {
                                            dropTargetID = nil
                                        }
                                    }))
                }
                // 拖到末尾 → 排到最后。
                Color.clear
                    .frame(height: 6)
                    .onDrop(of: [tvSourceDragType],
                            delegate: TVSourceEndDropDelegate(tv: tv))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            LumaEmptyState(symbol: "antenna.radiowaves.left.and.right.slash",
                           title: "还没有电视源",
                           actions: [
                               LumaEmptyAction(title: "接入电视源…",
                                               symbol: "square.and.arrow.down",
                                               filled: true) {
                                   tv.showWizard = true
                               }
                           ])
        }
    }

    private func sourceRow(_ playlist: TVPlaylist) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // 卡片主体与「网络存储」一致：点一下进入该源的频道墙。
            Button {
                tv.focusPlaylist(playlist.id)
                tv.setHubTab(.channels)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: playlist.isEnabled ? "tv.fill" : "tv.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(playlist.isEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(playlist.name)
                                .font(.system(size: 12.5, weight: .semibold))
                            // 导入时不再区分地区，默认按大陆处理；只有历史源还带上港台等标记时才显示。
                            if playlist.region != .mainland {
                                Text(playlist.region.title)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.07),
                                                in: Capsule(style: .continuous))
                            }
                        }
                        Text(playlist.displayAddress)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        if let epg = playlist.epgURLString, !epg.isEmpty {
                            Text("EPG · \(epg)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        healthLine(playlist)
                        let categories = tv.categoryGroups(for: playlist.id)
                        if !categories.isEmpty {
                            Text(categories.prefix(5).map { "\($0.group) \($0.count)" }
                                .joined(separator: " · "))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 拖动排序：顺序写进电视库，侧边栏与频道页同步生效。
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .contentShape(Rectangle())
                .onDrag { tvSourceDragProvider(playlist.id) }
                .help("拖动调整源顺序")

            Toggle("", isOn: Binding(get: { playlist.isEnabled },
                                     set: { tv.setPlaylistEnabled(playlist.id, enabled: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            Button("检测") { tv.enqueueConnectionChecks([playlist.id]) }
                .controlSize(.small)
                .disabled(tv.isChecking)

            Menu {
                Button("重命名…") {
                    renameText = playlist.name
                    renamingID = playlist.id
                }
                Button("设置 EPG 地址…") {
                    epgDraft = playlist.epgURLString ?? ""
                    epgEditingID = playlist.id
                }
                Button("删除这个源", role: .destructive) { tv.removePlaylist(playlist.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
        .opacity(playlist.isEnabled ? 1 : 0.72)
    }

    @ViewBuilder
    private func healthLine(_ playlist: TVPlaylist) -> some View {
        if let message = playlist.lastError, !message.isEmpty {
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(TVBrand.danger)
                .lineLimit(2)
        } else if let checkedAt = playlist.lastCheckedAt {
            HStack(spacing: 8) {
                Label("\(playlist.lastChannelCount ?? 0) 个频道", systemImage: "tv")
                if let latency = playlist.lastLatencyMilliseconds {
                    Label("\(latency) ms", systemImage: "bolt.fill")
                }
                Text(relativeText(checkedAt))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        } else {
            Text("尚未检测")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func relativeText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return "检测于 " + formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 状态

private struct TVStatusView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel

    /// 信号页筛选：全部 / 异常 / 4K / 收藏。
    private enum SignalFilter: String, CaseIterable, Identifiable {
        case all, issues, uhd, favorites
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .issues: return "异常"
            case .uhd: return "4K"
            case .favorites: return "收藏"
            }
        }
    }

    @State private var filter: SignalFilter = .all
    @State private var detailChannel: TVChannel?

    private var runningChecks: [JobProgress] {
        store.activeSourceJobs.filter { $0.kind == .connectivity }
    }

    private var scopedChannels: [TVChannel] {
        let base = tv.channelsForFocusedSource
        switch filter {
        case .all:
            return base
        case .issues:
            return base.filter {
                if case .unavailable = tv.probeState(for: $0.id) { return true }
                return false
            }
        case .uhd:
            return base.filter { tv.probeReport(for: $0.id)?.resolutionText == "4K" }
        case .favorites:
            return base.filter { tv.isFavorite($0) }
        }
    }

    /// 排序：异常优先 → 正常按首帧延迟升序 → 未探测垫底。
    private var sortedChannels: [TVChannel] {
        scopedChannels.sorted { lhs, rhs in
            let left = tv.probeReport(for: lhs.id)
            let right = tv.probeReport(for: rhs.id)
            let leftRank = left.map { $0.isSuccess ? 1 : 0 } ?? 2
            let rightRank = right.map { $0.isSuccess ? 1 : 0 } ?? 2
            if leftRank != rightRank { return leftRank < rightRank }
            let leftLatency = left?.ttfbMilliseconds ?? Int.max
            let rightLatency = right?.ttfbMilliseconds ?? Int.max
            if leftLatency != rightLatency { return leftLatency < rightLatency }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 延迟最低的三个正常频道，给「最稳」角标。
    private var bestChannelIDs: Set<String> {
        let ranked = tv.channelsForFocusedSource.compactMap { channel -> (String, Int)? in
            guard let report = tv.probeReport(for: channel.id),
                  report.isSuccess,
                  let latency = report.ttfbMilliseconds else { return nil }
            return (channel.id, latency)
        }
        .sorted { $0.1 < $1.1 }
        .prefix(3)
        .map(\.0)
        return Set(ranked)
    }

    /// 信号雷达：按 24 小时可用率 + 首帧延迟给频道排序，给出「今晚最稳的 10 个台」。
    private var radarChannels: [(channel: TVChannel, availability: Double, latency: Int?)] {
        var ranked: [(TVChannel, Double, Int?)] = []
        for channel in tv.visibleChannels {
            let report = tv.probeReport(for: channel.id)
            let availability = tv.availability(for: channel.id)
            guard availability != nil || report?.ttfbMilliseconds != nil else { continue }
            let score = availability ?? (report?.isSuccess == true ? 1 : 0)
            ranked.append((channel, score, report?.ttfbMilliseconds))
        }
        return ranked
            .sorted { lhs, rhs in
                if abs(lhs.1 - rhs.1) > 0.001 { return lhs.1 > rhs.1 }
                return (lhs.2 ?? Int.max) < (rhs.2 ?? Int.max)
            }
            .prefix(10)
            .map { (channel: $0.0, availability: $0.1, latency: $0.2) }
    }

    private var radarStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TVBrand.wave)
                Text("信号雷达 · 今晚最稳")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("按 24 小时可用率与延迟排序")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(radarChannels.enumerated()), id: \.offset) { pair in
                        radarCard(rank: pair.offset + 1,
                                  channel: pair.element.channel,
                                  availability: pair.element.availability,
                                  latency: pair.element.latency)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func radarCard(rank: Int, channel: TVChannel,
                           availability: Double, latency: Int?) -> some View {
        Button {
            detailChannel = channel
        } label: {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(rank <= 3 ? TVBrand.gold : Color.secondary.opacity(0.6))
                    .frame(width: 18, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("可用 \(Int(availability * 100))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(availability >= 0.8 ? TVBrand.success : TVBrand.warning)
                        if let latency {
                            Text("\(latency)ms")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 176, alignment: .leading)
            .background(TVBrand.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(rank <= 3 ? TVBrand.gold.opacity(0.28) : TVBrand.stroke, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .help("查看 \(channel.name) 的信号详情")
    }

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        if tv.isProbingChannels {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer(minLength: 8)
                        if tv.isProbingChannels {
                            Button("停止探测") { tv.cancelProbes() }
                                .controlSize(.small)
                        }
                        Button {
                            tv.probeFocusedSourceChannels()
                        } label: {
                            Label("探测全部", systemImage: "waveform.path.ecg")
                                .font(.system(size: 11))
                        }
                        .disabled(tv.channelsForFocusedSource.isEmpty || tv.isProbingChannels)
                        Menu {
                            Button("检测全部源") { tv.checkAllSources() }
                                .disabled(tv.isChecking)
                            Button("清空截帧缓存") { tv.clearImageCaches() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 12))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("更多信号操作")
                    }

                    if !runningChecks.isEmpty {
                        sectionTitle("正在检测", count: runningChecks.count)
                        ForEach(runningChecks) { job in
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(jobTitle(job)).font(.system(size: 12, weight: .medium))
                                    Text(job.message ?? "排队中…")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.accentColor.opacity(0.07)))
                        }
                    }

                    sectionTitle("探测画面", count: sortedChannels.count)
                    if !radarChannels.isEmpty {
                        radarStrip
                    }
                    filterChips
                    if tv.probeReports.isEmpty {
                        emptySignalState
                    } else if sortedChannels.isEmpty {
                        Text("当前筛选下没有频道。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 208), spacing: 10)],
                                  spacing: 10) {
                            ForEach(sortedChannels) { channel in
                                TVSignalCard(channel: channel,
                                             number: tv.channelNumber(for: channel),
                                             report: tv.probeReport(for: channel.id),
                                             state: tv.probeState(for: channel.id),
                                             isFavorite: tv.isFavorite(channel),
                                             isBest: bestChannelIDs.contains(channel.id),
                                             onPlay: { store.openTVChannel(channel) },
                                             onProbe: {
                                                 Task { await tv.requestPreview(for: channel, force: true) }
                                             },
                                             onToggleFavorite: { tv.toggleFavorite(channel) },
                                             onDetail: { detailChannel = channel })
                            }
                        }
                    }

                    Rectangle()
                        .fill(TVBrand.hairline)
                        .frame(height: 0.8)
                        .padding(.vertical, 2)

                    sectionTitle("源状态", count: tv.playlists.count)
                    if tv.playlists.isEmpty {
                        Text("还没有电视源。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tv.playlists) { playlist in
                            statusRow(playlist)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        .sheet(item: $detailChannel) { channel in
            TVSignalDetailView(channel: channel,
                               report: tv.probeReport(for: channel.id),
                               state: tv.probeState(for: channel.id),
                               playlistName: tv.playlistName(for: channel.playlistID),
                               onPlay: {
                                   detailChannel = nil
                                   store.openTVChannel(channel)
                               },
                               onProbe: {
                                   Task { await tv.requestPreview(for: channel, force: true) }
                               },
                               onToggleFavorite: { tv.toggleFavorite(channel) },
                               isFavorite: tv.isFavorite(channel))
        }
        // 低频巡检：收藏频道先探，其余只补 6 小时前的旧结果。
        .task { tv.patrolStaleSignals() }
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(SignalFilter.allCases) { item in
                let active = filter == item
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { filter = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(active ? Color.white : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(active ? Color.accentColor : Color.primary.opacity(0.06),
                                    in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if tv.isProbingChannels {
                Text("已标注 \(tv.probeStates.values.filter { $0 == .available || $0 == .unavailable }.count) / \(tv.channelsForFocusedSource.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private var emptySignalState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(TVBrand.wave)
                VStack(alignment: .leading, spacing: 2) {
                    Text("还没有探测结果")
                        .font(.system(size: 12, weight: .medium))
                    Text("探测会抓一帧真实画面，并记录首帧延迟、分辨率与码率。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("探测当前源") { tv.probeFocusedSourceChannels() }
                    .disabled(tv.channelsForFocusedSource.isEmpty)
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.06)))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 0.6)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }

    private func statusRow(_ playlist: TVPlaylist) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol(playlist))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusColor(playlist))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(playlist.name).font(.system(size: 12, weight: .medium))
                    if !playlist.isEnabled {
                        Text("已停用").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                }
                if let message = playlist.lastError, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TVBrand.danger)
                        .lineLimit(2)
                } else if let checkedAt = playlist.lastCheckedAt {
                    HStack(spacing: 8) {
                        Text("\(playlist.lastChannelCount ?? 0) 个频道")
                        if let latency = playlist.lastLatencyMilliseconds { Text("\(latency) ms") }
                        Text(checkedAtText(checkedAt))
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                } else {
                    Text("尚未检测").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Button("检测") { tv.enqueueConnectionChecks([playlist.id]) }
                .controlSize(.small)
                .disabled(!playlist.isEnabled || tv.isChecking)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.regularMaterial))
        .opacity(playlist.isEnabled ? 1 : 0.7)
    }

    private func statusSymbol(_ playlist: TVPlaylist) -> String {
        if playlist.lastError != nil { return "exclamationmark.triangle.fill" }
        if playlist.lastCheckedAt != nil { return "checkmark.circle.fill" }
        return "circle.dashed"
    }

    private func statusColor(_ playlist: TVPlaylist) -> Color {
        if playlist.lastError != nil { return TVBrand.warning }
        if playlist.lastCheckedAt != nil { return TVBrand.success }
        return .secondary
    }

    private func checkedAtText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func jobTitle(_ job: JobProgress) -> String {
        guard let uuid = UUID(uuidString: String(job.sourceID.rawValue.dropFirst("tv:".count))) else {
            return "检测电视源"
        }
        return "检测 \(tv.playlistName(for: uuid))"
    }
}

/// 信号卡：真实截帧 + 媒体参数。失败时明确写「无法截帧」并给出原因。
private struct TVSignalCard: View {
    let channel: TVChannel
    let number: Int
    let report: TVProbeReport?
    let state: TVProbeState
    let isFavorite: Bool
    let isBest: Bool
    let onPlay: () -> Void
    let onProbe: () -> Void
    let onToggleFavorite: () -> Void
    let onDetail: () -> Void

    @State private var hovered = false

    private var statusColor: Color {
        switch state {
        case .available: return TVBrand.success
        case .unavailable: return TVBrand.danger
        case .probing: return TVBrand.wave
        case .idle: return Color.secondary
        }
    }

    private var metrics: String {
        guard let report else {
            return state == .probing ? "正在抓帧…" : "未探测 · \(channel.lineCount) 线路"
        }
        guard report.isSuccess else {
            return report.error ?? "无法截帧"
        }
        return "\(report.resolutionText) · \(report.bitrateText) · \(report.latencyText) · \(channel.lineCount) 线路"
    }

    var body: some View {
        ZStack(alignment: .center) {
            Button(action: onPlay) { cardBody }
                .buttonStyle(.plain)
            if hovered {
                HStack(spacing: 6) {
                    hoverAction("info.circle.fill", help: "查看信号详情", action: onDetail)
                    hoverAction("arrow.clockwise", help: "重新探测", action: onProbe)
                }
                .padding(6)
                .background(Color.black.opacity(0.46), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
                .transition(.opacity)
            }
        }
        .onHover { value in
            withAnimation(.easeOut(duration: 0.14)) { hovered = value }
        }
        .contextMenu {
            Button("播放", action: onPlay)
            Button("查看信号详情", action: onDetail)
            Button("重新探测", action: onProbe)
            Divider()
            Button(isFavorite ? "取消收藏" : "收藏频道", action: onToggleFavorite)
        }
        .help("\(channel.name) · \(metrics)")
    }

    private func hoverAction(_ symbol: String,
                             help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            thumb
            nameRow
            Text(metrics)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(report?.isSuccess == true ? Color.secondary : Color.secondary.opacity(0.65))
                .lineLimit(1)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovered ? TVBrand.surfaceHover : TVBrand.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovered ? Color.accentColor.opacity(0.35) : TVBrand.stroke,
                              lineWidth: 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var thumb: some View {
        TVSignalThumb(channel: channel, report: report, state: state)
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .padding(7)
                    .shadow(color: statusColor.opacity(0.6), radius: 3)
            }
            .overlay(alignment: .topTrailing) {
                if isBest {
                    Text("最稳")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(TVBrand.onGold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(TVBrand.gold, in: Capsule(style: .continuous))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let quality = channel.qualityLabel {
                    let style = TVBrand.qualityStyle(quality)
                    Text(quality)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(style.fg)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(style.bg,
                                    in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        .padding(6)
                }
            }
    }

    private var nameRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(String(format: "%02d", number))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(channel.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            favoriteButton
        }
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isFavorite ? TVBrand.gold : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "取消收藏" : "收藏频道")
    }
}

/// 16:9 截帧：优先用本次探测结果，其次读 30 分钟内的缓存。
private struct TVSignalThumb: View {
    let channel: TVChannel
    let report: TVProbeReport?
    let state: TVProbeState

    @State private var cached: NSImage?

    private var shown: NSImage? { report?.image ?? cached }

    var body: some View {
        ZStack {
            Rectangle().fill(TVBrand.previewScrim)

            if let shown {
                Image(nsImage: shown)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 5) {
                    if state == .probing {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("抓帧中")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    } else if state == .unavailable {
                        Image(systemName: "video.slash")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(.white.opacity(0.8))
                        Text("无法截帧")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    } else if let logo = channel.logoURL, !logo.isEmpty {
                        TVLogoImage(urlString: logo, size: CGSize(width: 58, height: 33))
                        Text("未探测")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.white.opacity(0.55))
                        Text("未探测")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .task(id: report?.updatedAt) {
            guard report?.image == nil else {
                cached = nil
                return
            }
            cached = await TVPreviewCache.shared.image(for: channel.id)
        }
    }
}

/// 信号详情：放大截帧 + 完整参数 + 线路说明，动作只保留能真正执行的几项。
private struct TVSignalDetailView: View {
    @EnvironmentObject private var tv: IPTVBrowserModel
    @Environment(\.dismiss) private var dismiss

    let channel: TVChannel
    let report: TVProbeReport?
    let state: TVProbeState
    let playlistName: String
    let onPlay: () -> Void
    let onProbe: () -> Void
    let onToggleFavorite: () -> Void
    let isFavorite: Bool

    @State private var copied = false

    private var number: Int { tv.channelNumber(for: channel) }

    private var statusText: String {
        if let report {
            return report.isSuccess ? "正常" : "异常"
        }
        switch state {
        case .probing: return "抓帧中"
        case .available: return "正常"
        case .unavailable: return "异常"
        case .idle: return "未探测"
        }
    }

    private var statusColor: Color {
        switch state {
        case .available: return TVBrand.success
        case .unavailable: return TVBrand.danger
        case .probing: return TVBrand.wave
        case .idle: return Color.secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 16) {
                TVSignalThumb(channel: channel, report: report, state: state)
                    .frame(width: 300)
                parameters
            }
            lineSection
            actions
        }
        .padding(18)
        .frame(width: 640)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", number))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(TVBrand.wave)
            Text(channel.name)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(statusColor.opacity(0.10), in: Capsule(style: .continuous))
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(TVBrand.panel, in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private var parameters: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("分辨率", report?.resolutionText ?? "—")
            detailRow("码率", report?.bitrateText ?? "—")
            detailRow("首帧延迟", report?.latencyText ?? "—")
            detailRow("协议", channel.isHLS ? "HLS" : "HTTP")
            detailRow("画质标记", channel.qualityLabel ?? "—")
            detailRow("候选线路", "\(channel.lineCount) 条")
            detailRow("来源", playlistName)
            if let updated = report?.updatedAt {
                detailRow("最近探测", updated.formatted(date: .omitted, time: .standard))
            }
            detailRow("24h 可用率", availabilityText)
            if !tv.probePoints(for: channel.id).isEmpty {
                TVAvailabilityBar(points: tv.probePoints(for: channel.id))
                    .frame(height: 14)
            }
            if let error = report?.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(TVBrand.danger)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var availabilityText: String {
        guard let ratio = tv.availability(for: channel.id) else { return "—" }
        let count = tv.probePoints(for: channel.id).count
        return "\(Int((ratio * 100).rounded()))% · \(count) 次"
    }

    private var lineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("线路")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(channel.streamLines.count) 条候选")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(channel.streamLines.enumerated()), id: \.offset) { index, url in
                lineRow(index: index, url: url)
            }
            Text("锁定默认线路后，打开频道优先走这条；失败会自动顺延，全部失败才展示错误卡片。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(TVBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(TVBrand.stroke, lineWidth: 0.7))
    }

    private func lineRow(index: Int, url: String) -> some View {
        let isPreferred = tv.preferredLines[channel.id] == url
        let isCurrent = channel.streamURL == url
        return HStack(spacing: 8) {
            Text("线路 \(index + 1)")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(isCurrent ? TVBrand.wave : Color.secondary)
                .frame(width: 44, alignment: .leading)
            Text(lineHost(url))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isPreferred {
                Text("默认")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(TVBrand.onGold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(TVBrand.gold, in: Capsule(style: .continuous))
            } else if index == 0 {
                Text("最佳")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(TVBrand.wave)
            }
            Button(isPreferred ? "恢复自动" : "设为默认") {
                tv.setPreferredLine(isPreferred ? nil : url, for: channel)
            }
            .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isCurrent ? TVBrand.wave.opacity(0.08) : Color.clear)
        }
    }

    private func lineHost(_ url: String) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else { return url }
        return host + (parsed.path.isEmpty ? "" : parsed.path)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("播放", action: onPlay)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            Button("重新探测", action: onProbe)
                .controlSize(.regular)
            Button(isFavorite ? "取消收藏" : "收藏频道", action: onToggleFavorite)
                .controlSize(.regular)
            Button(copied ? "已复制" : "复制流地址") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(channel.streamURL, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            }
            .controlSize(.regular)
            Spacer(minLength: 0)
            Text("截帧与参数来自最近一次探测，不做占位画面")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }
}

/// 24 小时可用率小柱：成功为绿、失败为红，按时间从左到右排列。
private struct TVAvailabilityBar: View {
    let points: [TVProbePoint]

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, points.count)
            let barWidth = max(1.5, (proxy.size.width - CGFloat(count)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(point.success ? TVBrand.success.opacity(0.78)
                                            : TVBrand.danger.opacity(0.72))
                        .frame(width: barWidth,
                               height: point.success ? proxy.size.height
                                                     : proxy.size.height * 0.42)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 多画面

/// 2×2 四个频道：静音同时预览，点击某一格把声音切过去，双击放大进播放器。
private struct TVMultiviewSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel
    @Environment(\.dismiss) private var dismiss

    @State private var channels: [TVChannel] = []
    @State private var players: [String: AVPlayer] = [:]
    @State private var audioChannelID: String?

    private let columns = [GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TVBrand.wave)
                Text("多画面")
                    .font(.system(size: 15, weight: .semibold))
                Text("声音跟随：\(audioChannel?.name ?? "—")")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
            if channels.isEmpty {
                Text("没有可同时播放的 HLS 频道。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(channels) { channel in
                        cell(channel)
                    }
                }
                .padding(10)
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .background(TVBrand.background)
        .onAppear(perform: setup)
        .onDisappear(perform: teardown)
    }

    private var audioChannel: TVChannel? {
        channels.first { $0.id == audioChannelID }
    }

    private func setup() {
        let favorites = tv.visibleChannels.filter { tv.isFavorite($0) }
        var pool = favorites.isEmpty ? tv.channelsForFocusedSource : favorites
        // AVPlayer 只认 HLS：FLV / 无后缀直播地址在这里会黑屏，先筛一轮。
        let hls = pool.filter(\.isHLS)
        if hls.count >= 4 { pool = hls }
        channels = Array(pool.prefix(4))
        for (index, channel) in channels.enumerated() {
            let player = makePlayer(channel, muted: index != 0)
            players[channel.id] = player
            if index == 0 { audioChannelID = channel.id }
            player.play()
        }
    }

    private func teardown() {
        for player in players.values {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        players = [:]
        channels = []
    }

    private func makePlayer(_ channel: TVChannel, muted: Bool) -> AVPlayer {
        let url = URL(string: channel.streamURL)
        let options: [String: Any]? = channel.headers.isEmpty
            ? nil
            : ["AVURLAssetHTTPHeaderFieldsKey": channel.headers]
        let asset = url.map { AVURLAsset(url: $0, options: options) }
        let item = asset.map { AVPlayerItem(asset: $0) }
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        player.actionAtItemEnd = .none
        return player
    }

    private func cell(_ channel: TVChannel) -> some View {
        let focused = channel.id == audioChannelID
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)
            TVStreamLayer(player: players[channel.id])
            LinearGradient(colors: [Color.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .center)
                .allowsHitTesting(false)
            HStack(spacing: 6) {
                Text(String(format: "%02d", tv.channelNumber(for: channel)))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(focused ? TVBrand.gold : .white.opacity(0.7))
                Text(channel.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if focused {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TVBrand.gold)
                }
                Button {
                    dismiss()
                    store.openTVChannel(channel)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 22, height: 20)
                        .background(Color.white.opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("放大播放 \(channel.name)")
            }
            .padding(9)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? TVBrand.gold.opacity(0.8) : Color.white.opacity(0.10),
                              lineWidth: focused ? 1.2 : 0.6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(count: 2) {
            dismiss()
            store.openTVChannel(channel)
        }
        .onTapGesture {
            selectAudio(channel)
        }
    }

    private func selectAudio(_ channel: TVChannel) {
        audioChannelID = channel.id
        for (id, player) in players {
            player.isMuted = id != channel.id
        }
    }
}

/// 我的追剧：订阅的节目 + 未来 7 天的播出日历，提醒自动排好。
private struct TVSubscriptionsSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    private var occurrences: [(channel: TVChannel, program: TVEPGProgram)] {
        tv.subscriptionOccurrences(days: 7)
    }

    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    var body: some View {
        // 扫描一次 EPG，页头、日签与列表共用同一份结果。
        let all = occurrences
        return VStack(spacing: 0) {
            header(all: all)
            Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
            if tv.subscriptions.isEmpty {
                emptyState
            } else {
                subscriptionChips
                dayStrip(all: all)
                Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
                calendarList(all: all)
            }
        }
        .frame(width: 760, height: 600)
        .background { LumaAmbientBackground(intensity: 0.5) }
    }

    private func header(all: [(channel: TVChannel, program: TVEPGProgram)]) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(TVBrand.gold.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TVBrand.gold)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("我的追剧")
                    .font(.system(size: 17, weight: .semibold))
                Text(tv.subscriptions.isEmpty
                     ? "订阅节目后，未来 7 天的播出会自动排好提醒"
                     : "\(tv.subscriptions.count) 个订阅 · 未来 7 天 \(all.count) 次播出")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bookmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(TVBrand.gold.opacity(0.85))
            Text("还没有追的节目")
                .font(.system(size: 15, weight: .semibold))
            Text("在节目单的节目详情里点书签，或在「黄金时段」卡片上点书签；\n同名节目未来几天的播出都会自动提醒。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("去节目单挑一档") {
                tv.setHubTab(.guide)
                dismiss()
            }
            .controlSize(.large)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subscriptionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tv.subscriptions) { subscription in
                    HStack(spacing: 5) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(TVBrand.gold)
                        Text(subscription.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                        Button {
                            tv.removeSubscription(subscription)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 12, height: 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("取消追《\(subscription.title)》")
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(TVBrand.surface, in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    private func dayStrip(all: [(channel: TVChannel, program: TVEPGProgram)]) -> some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                let count = all.filter {
                    Calendar.current.isDate($0.program.start, inSameDayAs: day)
                }.count
                let active = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selectedDay = day }
                } label: {
                    VStack(spacing: 1) {
                        Text(dayLabel(day))
                            .font(.system(size: 9.5, weight: .semibold))
                        HStack(spacing: 3) {
                            Text(day.formatted(.dateTime.day()))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(active ? TVBrand.gold : Color.secondary)
                            }
                        }
                    }
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(active ? TVBrand.gold.opacity(0.16) : TVBrand.surface,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(active ? TVBrand.gold.opacity(0.45) : TVBrand.hairline,
                                      lineWidth: 0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private func calendarList(all: [(channel: TVChannel, program: TVEPGProgram)]) -> some View {
        let items = all.filter {
            Calendar.current.isDate($0.program.start, inSameDayAs: selectedDay)
        }
        return ScrollView {
            LazyVStack(spacing: 0) {
                if items.isEmpty {
                    VStack(spacing: 8) {
                        Text("这一天没有追的节目")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("换一天看看，或到节目单里追新的节目。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 56)
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { pair in
                        subscriptionRow(channel: pair.element.channel,
                                        program: pair.element.program)
                        if pair.offset < items.count - 1 {
                            Rectangle()
                                .fill(TVBrand.hairline)
                                .frame(height: 0.6)
                                .padding(.leading, 62)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private func subscriptionRow(channel: TVChannel, program: TVEPGProgram) -> some View {
        let live = program.isLive
        let past = program.end <= Date()
        let canCatchUp = past && !(channel.catchUpSource ?? "").isEmpty
        let reminded = tv.isReminded(program)
        return HStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(program.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(live ? TVBrand.signal : TVBrand.gold)
                Text("\(Int(program.duration / 60)) 分")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 46)

            TVLogoImage(urlString: channel.logoURL,
                        size: CGSize(width: 34, height: 18),
                        cornerRadius: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(program.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(channel.name)
                        .lineLimit(1)
                    Text(live ? "正在播" : (past ? (canCatchUp ? "可回看" : "已结束") : "待播"))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(live ? TVBrand.signal : Color.secondary)
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if live {
                Button("看直播") { store.openTVChannel(channel) }
                    .controlSize(.small)
            } else if past, canCatchUp {
                Button("回看") { store.openTVCatchup(channel, program: program) }
                    .controlSize(.small)
            } else if !past {
                Button(reminded ? "已预约" : "预约") {
                    tv.toggleReminder(program, channel: channel)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(live ? TVBrand.signal.opacity(0.05) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInTomorrow(day) { return "明天" }
        return day.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// 给多画面用的 AVPlayerLayer 容器。
private struct TVStreamLayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer()
        layer.player = player
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer?.sublayers?.first as? AVPlayerLayer)?.player = player
    }
}

// MARK: - 今晚推荐规则

/// 节目分类：直播页的「黄金时段」货架与「今晚」页共用一套标题、颜色与图标。
enum TVGuideCategory: String, CaseIterable, Identifiable {
    case news, sport, drama, variety, movie, documentary, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .news: return "新闻"
        case .sport: return "赛事"
        case .drama: return "剧集"
        case .variety: return "综艺"
        case .movie: return "电影"
        case .documentary: return "纪实"
        case .other: return "精选"
        }
    }

    var tint: Color {
        switch self {
        case .news: return TVBrand.wave
        case .sport: return TVBrand.gold
        case .drama: return LumaBrand.violet
        case .variety: return LumaBrand.coral
        case .movie: return LumaBrand.cyan
        case .documentary: return LumaBrand.mint
        case .other: return Color.secondary
        }
    }

    var symbol: String {
        switch self {
        case .news: return "newspaper"
        case .sport: return "sportscourt"
        case .drama: return "theatermasks"
        case .variety: return "sparkles"
        case .movie: return "film"
        case .documentary: return "leaf"
        case .other: return "square.grid.2x2"
        }
    }
}

/// 一场赛事：同一场比赛在多个频道同播时只留一条，channel 是其中最适合打开的那一台。
struct TVSportEvent: Identifiable {
    let key: String
    var channel: TVChannel
    var program: TVEPGProgram
    var simulcast: Int
    /// 全部同播频道（第 0 条是默认频道）：赛事详情据此给出「换台」列表。
    var channels: [TVChannel] = []
    var id: String { key }
}

/// 赛事角度：当前热播 / 即将开赛 / 历史 / 未来。
enum TVSportAngle: String, CaseIterable, Identifiable {
    case live, upcoming, history, future

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "当前热播"
        case .upcoming: return "即将开赛"
        case .history: return "历史"
        case .future: return "未来"
        }
    }

    var symbol: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .upcoming: return "clock"
        case .history: return "clock.arrow.circlepath"
        case .future: return "calendar"
        }
    }

    var tint: Color {
        switch self {
        case .live: return TVBrand.signal
        case .upcoming: return TVBrand.gold
        case .history: return Color.secondary
        case .future: return TVBrand.wave
        }
    }
}

/// 体育类型：赛事分区上的一排筛选胶囊。
enum TVSportType: String, CaseIterable, Identifiable {
    case all, general, football, basketball, worldCup, olympic, tennis, snooker,
         volleyball, badminton, tableTennis, athletics, aquatics, winter,
         combat, racing, esports, golf, baseball, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .general: return "综合"
        case .football: return "足球"
        case .basketball: return "篮球"
        case .worldCup: return "世界杯"
        case .olympic: return "奥运"
        case .tennis: return "网球"
        case .snooker: return "斯诺克"
        case .volleyball: return "排球"
        case .badminton: return "羽毛球"
        case .tableTennis: return "乒乓球"
        case .athletics: return "田径"
        case .aquatics: return "游泳"
        case .winter: return "冰雪"
        case .combat: return "格斗"
        case .racing: return "赛车"
        case .esports: return "电竞"
        case .golf: return "高尔夫"
        case .baseball: return "棒球"
        case .other: return "其他"
        }
    }

    /// 从赛事标题推断类型：先认「世界杯 / 奥运」这类大赛，再认具体项目。
    static func detect(_ title: String) -> TVSportType {
        let text = title.lowercased()
        func hit(_ words: [String]) -> Bool {
            words.contains { text.contains($0) }
        }
        if hit(["世界杯"]) { return .worldCup }
        if hit(["奥运", "冬奥", "亚运", "全运", "残奥", "大运会"]) { return .olympic }
        if hit(["篮球", "nba", "cba", "wnba", "篮联"]) { return .basketball }
        if hit(["足球", "英超", "欧冠", "中超", "亚冠", "西甲", "意甲", "德甲", "法甲",
                "世预赛", "亚洲杯", "欧洲杯", "足总杯", "足协杯", "美洲杯"]) { return .football }
        if hit(["排球", "女排", "男排", "排超"]) { return .volleyball }
        if hit(["羽毛球", "羽球", "羽超", "汤杯", "尤伯杯", "全英赛"]) { return .badminton }
        if hit(["乒乓", "乒超", "wtt", "世乒赛"]) { return .tableTennis }
        if hit(["网球", "温网", "法网", "美网", "澳网", "wta", "atp", "中网"]) { return .tennis }
        if hit(["斯诺克", "台球", "九球", "中式台球"]) { return .snooker }
        if hit(["田径", "马拉松", "竞走", "钻石联赛", "室内田径"]) { return .athletics }
        if hit(["游泳", "跳水", "花样游泳", "水球", "公开水域"]) { return .aquatics }
        if hit(["滑雪", "滑冰", "冰球", "冰壶", "花滑", "雪车", "钢架雪车", "短道速滑"]) {
            return .winter
        }
        if hit(["拳击", "格斗", "ufc", "mma", "散打", "自由搏击", "摔跤", "柔道",
                "跆拳道", "空手道"]) { return .combat }
        if hit(["赛车", "f1", "摩托", "拉力", "环法", "方程式", "越野赛"]) { return .racing }
        if hit(["电竞", "英雄联盟", "王者荣耀", "kpl", "lpl", "dota", "csgo", "守望先锋"]) {
            return .esports
        }
        if hit(["高尔夫", "pga", "欧巡"]) { return .golf }
        if hit(["棒球", "mlb", "垒球", "棒球联赛"]) { return .baseball }
        if hit(["体操", "举重", "射箭", "击剑", "赛艇", "帆船", "自行车", "攀岩",
                "滑板", "冲浪", "龙舟", "武术", "围棋", "象棋", "国际象棋"]) { return .general }
        return .other
    }
}

/// 综艺 / 纪实等非赛事节目里的一档：同一个节目名跨台只留一条。
struct TVShowPick: Identifiable {
    let key: String
    var channel: TVChannel
    var program: TVEPGProgram
    var simulcast: Int
    var id: String { key }
}

/// 黄金时段的一档精选：带评分与「入选理由」，方便界面解释为什么推荐它。
struct TVPrimePick: Identifiable {
    let key: String
    let channel: TVChannel
    let program: TVEPGProgram
    let category: TVGuideCategory
    let simulcast: Int
    let score: Int
    let reasons: [String]
    var id: String { key }
}

/// 黄金时段里的一个 30 分钟格子：档数按「不同节目」统计，同播只算一档。
struct TVPrimeSlot: Identifiable {
    let index: Int
    let count: Int
    /// 这一格里占比最高的类型，决定格子的颜色。
    let category: TVGuideCategory?
    var id: Int { index }
}

/// 某一天里一个频道的节目：整页快照的输入，纯计算函数不必再碰视图模型。
struct TVChannelDay {
    let channel: TVChannel
    let programs: [TVEPGProgram]
}

/// 「夜航」页整页一次算好的数据：节目单只扫一遍，赛事 / 黄金时段 / 综艺 / 人物
/// 共用同一份分类结果，切换角度、预约、追剧都不再重扫节目单。
struct TVTonightSnapshot {
    var sports: [TVSportEvent] = []
    var history: [TVSportEvent] = []
    var future: [TVSportEvent] = []
    /// 赛事 key → 体育类型：行标签与筛选胶囊直接取，不再逐行推断标题。
    var sportTypes: [String: TVSportType] = [:]
    var picks: [TVPrimePick] = []
    /// 黄金时段每 30 分钟的档数统计：热力条用它，不受精选名额限制。
    var primeSlots: [TVPrimeSlot] = []
    var variety: [TVShowPick] = []
    var people: [TVShowPick] = []
    /// 已追的节目 id：卡片书签状态一次算好，渲染时不再重跑正则。
    var followedProgramIDs: Set<String> = []

    /// 页头统计：节目档数与涉及的频道数。
    var showCount: Int { picks.count + variety.count + people.count }
    var channelCount: Int {
        Set(sports.map(\.channel.id) + picks.map(\.channel.id)
            + variety.map(\.channel.id) + people.map(\.channel.id)).count
    }
}

/// 「今晚赛事 / 黄金时段」的匹配规则：识别、同播合并、频道优先与排序都收在这里，
/// 直播页的两条货架和「夜航」页共用同一份逻辑，不会再各算一套。
enum TVTonightRules {
    /// 赛事关键词：比原先多了世界杯 / 奥运 / 决赛这类「大赛」词，以及田径、赛车、格斗等项目。
    static let sportKeywords: [String] = [
        "体育", "足球", "篮球", "网球", "排球", "羽毛球", "乒乓", "斯诺克", "高尔夫",
        "赛车", "拳击", "格斗", "电竞", "田径", "马拉松", "环法", "滑雪", "冰球", "棒球",
        "联赛", "杯", "球赛", "英超", "欧冠", "中超", "亚冠", "NBA", "CBA", "F1", "UFC",
        "WTT", "ATP", "WTA", "KPL", "LPL", "MLB", "PGA", "世界杯", "奥运", "亚运", "全运",
        "决赛", "半决赛", "德比", "世锦赛", "锦标赛", "公开赛", "大奖赛", "巡回赛",
        "排位赛", "小组赛", "附加赛", "资格赛", "全明星", "乒超", "羽超", "排超",
        "游泳", "跳水", "体操", "举重", "射箭", "击剑", "摔跤", "柔道", "跆拳道",
        "冰壶", "花滑", "短道速滑", "赛艇", "帆船", "攀岩", "滑板", "冲浪", "武术"
    ]

    /// 栏目类标题：名字里有体育但并不比赛事，避免把「体育新闻」当成一场比赛。
    static let sportExclusions: [String] = [
        "体育新闻", "体育世界", "体育晨报", "体育人间", "体坛快讯", "赛事预告",
        "精彩回顾", "体育报道", "赛事集锦", "体育资讯", "运动空间", "健身动起来"
    ]

    /// 黄金时段窗口：19:30 – 23:30。
    static func primeWindow(on day: Date) -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: day)
        guard let start = calendar.date(bySettingHour: 19, minute: 30, second: 0, of: today),
              let end = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: today)
        else { return nil }
        return (start, end)
    }

    /// 关键词预先转小写：赛事判定要跑上万次，避免每次都做本地化大小写比较。
    private static let sportKeywordsLower = sportKeywords.map { $0.lowercased() }

    static func isSport(_ program: TVEPGProgram, channel: TVChannel) -> Bool {
        if sportExclusions.contains(where: { program.title.contains($0) }) { return false }
        let lowered = program.title.lowercased()
        if sportKeywordsLower.contains(where: { lowered.contains($0) }) {
            return true
        }
        // 体育频道上的整档节目（足够长）也算赛事：很多联赛只写「焦点战」这类泛标题。
        return channel.group.contains("体育") && program.duration >= 20 * 60
    }

    /// 综艺关键词：常见国民综艺的名字也收进来，光靠「综艺 / 晚会」会漏掉一大半。
    static let varietyKeywords: [String] = [
        "综艺", "晚会", "盛典", "演唱会", "喜剧", "脱口秀", "访谈", "真人秀",
        "歌手", "舞台", "王牌", "奔跑吧", "极限挑战", "你好星期六", "快乐大本营",
        "天天向上", "向往的生活", "中餐厅", "乘风破浪", "披荆斩棘", "明星大侦探",
        "密室大逃脱", "我们的歌", "天赐的声音", "声生不息", "青春环游记", "花儿与少年",
        "非诚勿扰", "中国好声音", "欢乐喜剧人", "一年一度喜剧大赛", "脱口秀大会",
        "春晚", "跨年", "元宵", "中秋"
    ]

    /// 纪实 / 人物关键词。
    static let documentaryKeywords: [String] = [
        "纪录", "纪实", "人文", "地理", "自然", "探索", "档案", "人物", "大师",
        "匠心", "传奇", "历史", "寻访", "走进", "国家记忆", "大国重器", "舌尖",
        "航拍中国", "如果国宝会说话", "我在故宫修文物", "河西走廊", "敦煌", "故事"
    ]

    /// 人物记录：在纪实里优先挑「讲人」的片子。
    static let peopleKeywords: [String] = [
        "人物", "大师", "匠心", "传奇", "人生", "面孔", "故事", "记忆", "时代", "档案"
    ]

    /// 栏目分类的预转小写关键词：整页一次遍历时每档节目只调一次。
    private static let varietyKeywordsLower = varietyKeywords.map { $0.lowercased() }
    private static let documentaryKeywordsLower = documentaryKeywords.map { $0.lowercased() }

    static func category(_ title: String) -> TVGuideCategory {
        if ["新闻", "联播", "朝闻", "焦点访谈", "观察", "资讯"].contains(where: { title.contains($0) }) {
            return .news
        }
        if ["剧场", "电视剧", "连续剧", "第", "集", "季"].contains(where: { title.contains($0) }) {
            return .drama
        }
        let lowered = title.lowercased()
        if varietyKeywordsLower.contains(where: { lowered.contains($0) }) {
            return .variety
        }
        if title.contains("电影") { return .movie }
        if documentaryKeywordsLower.contains(where: { lowered.contains($0) }) {
            return .documentary
        }
        return .other
    }

    static func isPeopleDocumentary(_ title: String) -> Bool {
        peopleKeywords.contains { title.contains($0) }
    }

    /// 频道权重：同一档节目被多个台同播时，优先用这个台播。
    static func channelPriority(_ channel: TVChannel) -> Int {
        let name = channel.name
        var score = 0
        if name.contains("CCTV5") || name.contains("CCTV-5") { score += 30 }
        if name.contains("体育") { score += 20 }
        if name.contains("CCTV") { score += 10 }
        if name.contains("卫视") { score += 6 }
        if channel.isHLS { score += 2 }
        return score
    }

    /// 节目名归一化：用于「同一档节目」的去重与同播统计。
    static func key(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
    }

    /// 单次遍历生成整页数据。
    /// 原先每个板块各扫一遍节目单（赛事三个角度 + 黄金时段两次 + 综艺两次 + 人物一次），
    /// 现在频道 × 节目只走一遍，赛事判定、栏目分类、体育类型都只算一次。
    static func tonightSnapshot(today: [TVChannelDay],
                                tomorrow: [TVChannelDay],
                                now: Date) -> TVTonightSnapshot {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let dayEnd = startOfDay.addingTimeInterval(86_400)
        let horizon = now.addingTimeInterval(14 * 3600)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? dayEnd
        let tomorrowEnd = tomorrowStart.addingTimeInterval(86_400)
        let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? startOfDay
        let window = primeWindow(on: now)

        var liveBest: [String: TVSportEvent] = [:]
        var historyBest: [String: TVSportEvent] = [:]
        var futureBest: [String: TVSportEvent] = [:]
        var simulcastIndex: [String: Set<String>] = [:]
        var slotKeys: [Int: Set<String>] = [:]
        var slotCategories: [Int: [TVGuideCategory: Int]] = [:]
        var primeCandidates: [(channel: TVChannel, program: TVEPGProgram,
                               category: TVGuideCategory, programKey: String)] = []
        var eveningShows: [String: TVShowPick] = [:]
        var allDayShows: [String: TVShowPick] = [:]
        var documentaries: [String: TVShowPick] = [:]

        for day in today {
            let channel = day.channel
            for program in day.programs {
                // 赛事判定与栏目分类是整页最贵的两步，每档节目只做一次。
                let sport = isSport(program, channel: channel)
                let guideCategory = category(program.title)
                let titleKey = key(program.title)

                if sport {
                    if program.end > now, program.start <= horizon {
                        let eventKey = titleKey + "#"
                            + String(Int(program.start.timeIntervalSince1970 / 1800))
                        mergeSport(TVSportEvent(key: eventKey, channel: channel,
                                                program: program, simulcast: 1),
                                   channel: channel, into: &liveBest)
                    }
                    if program.end <= now, program.start >= startOfDay {
                        let eventKey = titleKey + "#"
                            + String(Int(program.start.timeIntervalSince1970 / 1800))
                        mergeSport(TVSportEvent(key: eventKey, channel: channel,
                                                program: program, simulcast: 1),
                                   channel: channel, into: &historyBest)
                    }
                }

                // 同播统计覆盖黄金时段内的所有节目（含赛事），与原先一致。
                if let window, program.start >= window.start, program.start < window.end {
                    let bucket = titleKey + "#"
                        + String(Int(program.start.timeIntervalSince1970 / 300))
                    simulcastIndex[bucket, default: []].insert(channel.name)
                    // 时段热度：按「不同节目」计数，同播台只算一档。
                    let slot = Int(program.start.timeIntervalSince(window.start) / 1800)
                    if slotKeys[slot, default: []].insert(bucket).inserted {
                        slotCategories[slot, default: [:]][guideCategory, default: 0] += 1
                    }
                    if !sport, program.end > now, titleKey.count >= 2 {
                        primeCandidates.append((channel, program, guideCategory, titleKey))
                    }
                }

                guard program.start >= startOfDay, program.start < dayEnd, titleKey.count >= 2 else {
                    continue
                }
                if guideCategory == .variety {
                    mergeShow(program, channel: channel, titleKey: titleKey, into: &allDayShows)
                    if program.start >= evening {
                        mergeShow(program, channel: channel, titleKey: titleKey, into: &eveningShows)
                    }
                } else if guideCategory == .documentary {
                    mergeShow(program, channel: channel, titleKey: titleKey, into: &documentaries)
                }
            }
        }

        // 明天的赛事：只扫明天的节目单，避免和「今天」重复判定。
        for day in tomorrow {
            for program in day.programs where program.start >= tomorrowStart {
                guard program.start < tomorrowEnd,
                      isSport(program, channel: day.channel) else { continue }
                let eventKey = key(program.title) + "#"
                    + String(Int(program.start.timeIntervalSince1970 / 1800))
                mergeSport(TVSportEvent(key: eventKey, channel: day.channel,
                                        program: program, simulcast: 1),
                           channel: day.channel, into: &futureBest)
            }
        }

        var snapshot = TVTonightSnapshot()
        snapshot.sports = liveBest.values
            .sorted { $0.program.start < $1.program.start }
            .prefix(40)
            .map { $0 }
        snapshot.history = historyBest.values
            .sorted { $0.program.start > $1.program.start }
            .prefix(16)
            .map { $0 }
        snapshot.future = futureBest.values
            .sorted { $0.program.start < $1.program.start }
            .prefix(16)
            .map { $0 }
        for event in snapshot.sports + snapshot.history + snapshot.future {
            if snapshot.sportTypes[event.key] == nil {
                snapshot.sportTypes[event.key] = TVSportType.detect(event.program.title)
            }
        }

        var picked: [String: TVPrimePick] = [:]
        for candidate in primeCandidates {
            let program = candidate.program
            let bucket = candidate.programKey + "#"
                + String(Int(program.start.timeIntervalSince1970 / 300))
            let simulcast = simulcastIndex[bucket]?.count ?? 1
            let value = score(program: program,
                              category: candidate.category,
                              simulcast: simulcast,
                              channel: candidate.channel,
                              now: now)
            if let current = picked[candidate.programKey], current.score >= value { continue }
            picked[candidate.programKey] = TVPrimePick(key: candidate.programKey,
                                                       channel: candidate.channel,
                                                       program: program,
                                                       category: candidate.category,
                                                       simulcast: simulcast,
                                                       score: value,
                                                       reasons: reasons(program: program,
                                                                        category: candidate.category,
                                                                        simulcast: simulcast))
        }
        // 每个 30 分钟时段只留评分最高的几档：40 个名额平均分到整个黄金时段，
        // 否则会被 19:30 这一档节目占满，后面的时段与热力条全是空的。
        let perSlot = 5
        var bySlot: [Int: [TVPrimePick]] = [:]
        for pick in picked.values {
            let offset = window.map { pick.program.start.timeIntervalSince($0.start) } ?? 0
            let slot = max(0, Int(offset / 1800))
            bySlot[slot, default: []].append(pick)
        }
        var balanced: [TVPrimePick] = []
        for slot in bySlot.keys.sorted() {
            balanced += (bySlot[slot] ?? [])
                .sorted { $0.score > $1.score }
                .prefix(perSlot)
        }
        if balanced.count < 40 {
            let chosen = Set(balanced.map(\.key))
            let rest = picked.values
                .filter { !chosen.contains($0.key) }
                .sorted { $0.score > $1.score }
            balanced += rest.prefix(40 - balanced.count)
        }
        snapshot.picks = balanced.sorted { $0.program.start < $1.program.start }

        // 时段热度用全量节目统计（同播只算一档），和上面精选名额无关。
        if let window {
            let slotCount = max(1, Int(window.end.timeIntervalSince(window.start) / 1800))
            snapshot.primeSlots = (0..<slotCount).map { index in
                let counts = slotCategories[index] ?? [:]
                return TVPrimeSlot(index: index,
                                   count: slotKeys[index]?.count ?? 0,
                                   category: counts.max { $0.value < $1.value }?.key)
            }
        }

        let eveningPicks = sortedShows(eveningShows, limit: 12)
        snapshot.variety = eveningPicks.isEmpty ? sortedShows(allDayShows, limit: 12) : eveningPicks

        let allDocumentaries = sortedShows(documentaries, limit: 40)
        let people = allDocumentaries.filter { isPeopleDocumentary($0.program.title) }
        let rest = allDocumentaries.filter { !isPeopleDocumentary($0.program.title) }
        snapshot.people = Array((people + rest).prefix(10))
        return snapshot
    }

    /// 同名赛事合并：同播台数累加，频道权重高的留下。
    private static func mergeSport(_ event: TVSportEvent,
                                   channel: TVChannel,
                                   into best: inout [String: TVSportEvent]) {
        guard var existing = best[event.key] else {
            var created = event
            created.channels = [channel]
            created.simulcast = 1
            best[event.key] = created
            return
        }
        if existing.channels.isEmpty {
            existing.channels = [existing.channel]
        }
        if !existing.channels.contains(where: { $0.id == channel.id }) {
            existing.channels.append(channel)
        }
        existing.simulcast = existing.channels.count
        if channelPriority(channel) > channelPriority(existing.channel) {
            existing.channel = channel
            existing.program = event.program
        }
        best[event.key] = existing
    }

    /// 同名综艺 / 纪实跨台合并：同播台数累加，频道权重高的留下。
    private static func mergeShow(_ program: TVEPGProgram,
                                  channel: TVChannel,
                                  titleKey: String,
                                  into best: inout [String: TVShowPick]) {
        guard var existing = best[titleKey] else {
            best[titleKey] = TVShowPick(key: titleKey, channel: channel,
                                        program: program, simulcast: 1)
            return
        }
        existing.simulcast += 1
        if channelPriority(channel) > channelPriority(existing.channel) {
            existing.channel = channel
            existing.program = program
        }
        best[titleKey] = existing
    }

    /// 货架排序：正在播的在前，其次按开播时间。
    private static func sortedShows(_ picks: [String: TVShowPick], limit: Int) -> [TVShowPick] {
        picks.values
            .sorted { lhs, rhs in
                if lhs.program.isLive != rhs.program.isLive { return lhs.program.isLive }
                return lhs.program.start < rhs.program.start
            }
            .prefix(limit)
            .map { $0 }
    }

    /// 评分：同播台数 + 类型权重 + 大赛 / 首播 / 直播加权 + 频道权重 + 20:00 时段权重。
    static func score(program: TVEPGProgram,
                      category: TVGuideCategory,
                      simulcast: Int,
                      channel: TVChannel,
                      now: Date) -> Int {
        var score = min(5, simulcast) * 6
        switch category {
        case .news: score += 60
        case .sport: score += 50
        case .drama: score += 40
        case .variety: score += 35
        case .movie: score += 25
        case .documentary: score += 20
        case .other: score += 10
        }
        if program.title.contains("新闻联播") { score += 40 }
        if program.title.contains("首播") { score += 15 }
        if program.title.contains("决赛") { score += 25 }
        if program.title.contains("半决赛") { score += 15 }
        if program.isLive { score += 20 }
        score += channelPriority(channel) / 2
        if program.duration >= 45 * 60 { score += 5 }
        // 越接近 20:00 的节目越靠前。
        let components = Calendar.current.dateComponents([.hour, .minute], from: program.start)
        let minutes = (components.hour ?? 20) * 60 + (components.minute ?? 0)
        score += max(0, 40 - abs(minutes - 20 * 60) / 3)
        return score
    }

    /// 入选理由：界面上直接把这些标签摆出来，推荐不再是黑盒。
    static func reasons(program: TVEPGProgram,
                        category: TVGuideCategory,
                        simulcast: Int) -> [String] {
        var list: [String] = []
        if simulcast > 1 { list.append("\(simulcast) 台同播") }
        if program.title.contains("新闻联播") { list.append("全国联播") }
        if program.title.contains("决赛") { list.append("决赛") }
        if program.title.contains("首播") { list.append("首播") }
        if program.isLive { list.append("直播中") }
        let components = Calendar.current.dateComponents([.hour, .minute], from: program.start)
        let minutes = (components.hour ?? 20) * 60 + (components.minute ?? 20 * 60)
        if abs(minutes - 20 * 60) <= 45 { list.append("20:00 档") }
        if list.isEmpty {
            list.append(category == .other ? "综合精选" : "\(category.title)重点")
        }
        return Array(list.prefix(3))
    }
}

/// 「夜航」页派生数据缓存：签名不变就复用上一次的结果。
/// 用引用类型装缓存，命中时不触发 SwiftUI 的状态更新，只在真正需要时重建。
@MainActor
private final class TVTonightCache {
    private var key: String?
    private var snapshot = TVTonightSnapshot()

    func value(for key: String, build: () -> TVTonightSnapshot) -> TVTonightSnapshot {
        if key == self.key { return snapshot }
        let fresh = build()
        snapshot = fresh
        self.key = key
        return fresh
    }
}

// MARK: - 今晚

/// 独立「夜航」页：把直播页上的两条创意货架展开成长页面，
/// 赛事按角度与体育类型列出，黄金时段按类型分组，最后把匹配规则摊开。
private struct TVTonightView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel

    @State private var rulesShown = false
    /// 赛事角度：当前热播 / 即将开赛 / 历史 / 未来。
    @State private var sportAngle: TVSportAngle = .live
    /// 体育类型筛选：全部 / 篮球 / 足球 / 世界杯……
    @State private var sportType: TVSportType = .all
    /// 黄金时段类型筛选：nil 表示全部。
    @State private var primeCategory: TVGuideCategory?
    /// 黄金时段时段筛选：nil 表示整个黄金时段。
    @State private var primeSlot: Int?
    /// 综艺 / 人物货架是否展开全部。
    @State private var expandedShelves: Set<String> = []
    /// 悬停高亮：整页共用一组状态，卡片与行不再各自维护。
    @State private var hoveredSportKey: String?
    @State private var hoveredPrimeKey: String?
    @State private var hoveredShowKey: String?

    /// 整页派生数据的缓存：签名不变就直接复用，预约 / 追剧这类重绘不再重扫节目单。
    @State private var cache = TVTonightCache()

    var body: some View {
        // 一分钟一跳的稳定时钟：整页共用同一个时刻，
        // 「直播 / 已结束 / 明天」的翻面也就卡在分钟边界上，不会一帧一个样。
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 60)) { context in
            page(now: context.date)
        }
        // 进入夜航也把节目单补齐：缓存过期 / 首次进入都会在这里排一次更新，
        // 不然赛事、黄金时段、综艺全是空的。
        .task { tv.loadEPGIfNeeded() }
    }

    /// 节目单缺失提示：夜航整页的货架都来自节目单，没有时必须说清楚并给出更新入口。
    private var epgNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tv.isLoadingEPG ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tv.isLoadingEPG ? TVBrand.gold : LumaBrand.coral)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(tv.isLoadingEPG ? "正在更新节目单…" : "还没有节目单")
                    .font(.system(size: 12, weight: .semibold))
                Text(epgNoticeDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !tv.isLoadingEPG {
                Button("立即更新") { tv.reloadEPG() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(TVBrand.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6)
        }
    }

    private var epgNoticeDetail: String {
        if tv.isLoadingEPG {
            return "拉取完成后，赛事 / 黄金时段 / 综艺会自动填满这一页。"
        }
        if let error = tv.epgError, !error.isEmpty {
            return "上次更新失败：\(error)。点右侧重试。"
        }
        return "这一页的赛事、黄金时段与综艺都来自节目单；点右侧立即拉取，或在「源库」里补一份 XMLTV 地址。"
    }

    private func page(now: Date) -> some View {
        let snapshot = cache.value(for: cacheKey(now: now)) { buildSnapshot(now: now) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if tv.epgPrograms.isEmpty {
                    epgNotice
                }
                sportsSection(snapshot, now: now)
                primeSection(snapshot, followed: snapshot.followedProgramIDs, now: now)
                showShelf(title: "热播综艺",
                          symbol: "sparkles",
                          tint: LumaBrand.coral,
                          detail: "今晚 18:00 后 · \(snapshot.variety.count) 档",
                          picks: snapshot.variety,
                          emptyText: "节目单里还没有识别到今晚的综艺。",
                          now: now)
                showShelf(title: "人物记录",
                          symbol: "person.text.rectangle",
                          tint: LumaBrand.mint,
                          detail: "纪实 / 人物 · \(snapshot.people.count) 档",
                          picks: snapshot.people,
                          emptyText: "这段时间没有人物 / 纪实类节目；节目单更新后会自动出现。",
                          now: now)
                TVRecordingsPanel()
                rulesPanel
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
    }

    /// 缓存签名：节目单 / 频道集合 / 筛选条件 / 分钟 / 追剧状态任一变化才重建整页数据。
    private func cacheKey(now: Date) -> String {
        "\(tv.tonightDataSignature)|\(Int(now.timeIntervalSince1970 / 60))"
            + "|\(tv.subscriptions.count)"
    }

    /// 收集两天的节目单后一次算完：同一档节目的赛事判定、栏目分类都只做一次。
    private func buildSnapshot(now: Date) -> TVTonightSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let channels = tv.visibleChannels
        var snapshot = TVTonightRules.tonightSnapshot(
            today: channels.map {
                TVChannelDay(channel: $0, programs: tv.programs(on: today, for: $0))
            },
            tomorrow: channels.map {
                TVChannelDay(channel: $0, programs: tv.programs(on: tomorrow, for: $0))
            },
            now: now
        )
        let subscribed = Set(tv.subscriptions.map(\.key))
        if !subscribed.isEmpty {
            snapshot.followedProgramIDs = Set(
                snapshot.picks
                    .filter { subscribed.contains(tv.programKey($0.program.title)) }
                    .map { $0.program.id }
            )
        }
        return snapshot
    }

    // MARK: 头部

    private var refreshButton: some View {
        Button {
            tv.reloadEPG()
        } label: {
            HStack(spacing: 6) {
                if tv.isLoadingEPG {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(tv.isLoadingEPG ? "刷新中…" : "刷新节目单")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(TVBrand.panel, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .disabled(tv.isLoadingEPG)
        .help("重新拉取节目单")
    }

    private var rulesButton: some View {
        Button {
            rulesShown.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text("推荐规则")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(TVBrand.panel, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $rulesShown, arrowEdge: .top) {
            TVTonightRulesCard(compact: true)
                .padding(16)
                .frame(width: 400)
        }
    }

    // MARK: 赛事

    private func sportsSection(_ snapshot: TVTonightSnapshot, now: Date) -> some View {
        let live = snapshot.sports.filter { $0.program.isLive }
        let upcoming = snapshot.sports.filter { !$0.program.isLive }
        let buckets: [TVSportAngle: [TVSportEvent]] = [
            .live: live,
            .upcoming: upcoming,
            .history: snapshot.history,
            .future: snapshot.future
        ]
        let current = buckets[sportAngle] ?? []
        let types = snapshot.sportTypes
        let filtered = sportType == .all
            ? current
            : current.filter { types[$0.key] == sportType }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                sectionTitle(symbol: "sportscourt.fill",
                             tint: TVBrand.gold,
                             title: "最近赛事",
                             detail: "\(snapshot.sports.count) 场 · 未来 14 小时")
                refreshButton
                rulesButton
            }
            angleBar(buckets)
            typeChips(in: current, types: types)
            if !tv.sportFollows.isEmpty {
                followBar(snapshot: snapshot)
            }

            if filtered.isEmpty {
                emptyHint(symbol: "sportscourt", text: emptySportText(angle: sportAngle))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filtered) { event in
                        sportRow(event, type: types[event.key] ?? .other, now: now)
                    }
                }
            }
        }
    }

    /// 四个角度：当前热播 / 即将开赛 / 历史 / 未来。
    private func angleBar(_ buckets: [TVSportAngle: [TVSportEvent]]) -> some View {
        HStack(spacing: 5) {
            ForEach(TVSportAngle.allCases) { angle in
                let active = sportAngle == angle
                let count = buckets[angle]?.count ?? 0
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { sportAngle = angle }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: angle.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(angle.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .opacity(0.78)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(active ? TVBrand.onGold.opacity(0.16)
                                               : Color.primary.opacity(0.06),
                                        in: Capsule(style: .continuous))
                    }
                    .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
                    .padding(.horizontal, 13)
                    .frame(height: 31)
                    .background {
                        if active {
                            Capsule(style: .continuous).fill(angle.tint)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("\(angle.title) · \(count) 场")
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
        .fixedSize()
    }

    /// 体育类型：只列出当前角度里真的出现过的类型；换行平铺，不用左右拖。
    private func typeChips(in events: [TVSportEvent], types: [String: TVSportType]) -> some View {
        let present = Set(events.map { types[$0.key] ?? .other })
        let visible = TVSportType.allCases.filter { $0 == .all || present.contains($0) }
        return CatalogFlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(visible) { type in
                typeChip(type)
            }
        }
    }

    private func typeChip(_ type: TVSportType) -> some View {
        let active = sportType == type
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { sportType = type }
        } label: {
            Text(type.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
                .padding(.horizontal, 12)
                .frame(height: 27)
                .background(active ? TVBrand.gold : Color.primary.opacity(0.05),
                            in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 「我的关注」：关注词一键取消，并可批量给相关赛事排开赛提醒。
    private func followBar(snapshot: TVTonightSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("我的关注", systemImage: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TVBrand.gold)
                Text("\(tv.sportFollows.count) 个关键词")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("为关注赛事排提醒") {
                    let items = (snapshot.sports + snapshot.future)
                        .map { (channel: $0.channel, program: $0.program) }
                    tv.remindFollowedSports(items)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
            }
            CatalogFlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(tv.sportFollows) { follow in
                    Button {
                        tv.removeSportFollow(follow)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(follow.keyword)
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "xmark")
                                .font(.system(size: 7.5, weight: .bold))
                                .opacity(0.6)
                        }
                        .foregroundStyle(TVBrand.gold)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(TVBrand.gold.opacity(0.12), in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(TVBrand.gold.opacity(0.30), lineWidth: 0.6))
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("取消关注「\(follow.keyword)」")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(TVBrand.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6)
        }
    }

    private func emptySportText(angle: TVSportAngle) -> String {
        switch angle {
        case .live: return "此刻没有识别到正在直播的赛事。"
        case .upcoming: return "接下来 14 小时里还没有还没开播的赛事。"
        case .history: return "今天结束的节目单里还没识别到赛事。"
        case .future: return "节目单里还没有明天的赛事；等 EPG 补上后会自动出现。"
        }
    }

    private func sportRow(_ event: TVSportEvent, type: TVSportType, now: Date) -> some View {
        let program = event.program
        let channel = event.channel
        let live = program.isLive
        let past = program.end <= now
        let canCatchUp = past && !(channel.catchUpSource ?? "").isEmpty
        let reminded = tv.isReminded(program)
        let tint: Color = live ? TVBrand.signal : (past ? Color.secondary : TVBrand.gold)
        let isTomorrow = !Calendar.current.isDateInToday(program.start)
        let hovered = hoveredSportKey == event.key
        return HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(Self.clock.string(from: program.start))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                Text(Self.clock.string(from: program.end))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 58, alignment: .trailing)

            // 时间轨：直播是实心亮点，过去是灰点，未来是描边点。
            VStack(spacing: 0) {
                Circle()
                    .fill(live ? tint : Color.clear)
                    .overlay {
                        Circle().strokeBorder(tint.opacity(past ? 0.5 : 0.9),
                                              lineWidth: live ? 0 : 1.5)
                    }
                    .frame(width: 9, height: 9)
                    .shadow(color: live ? tint.opacity(0.75) : .clear, radius: 6)
                Rectangle()
                    .fill(tint.opacity(0.22))
                    .frame(width: 1, height: 34)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(program.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(past && !canCatchUp ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TVLogoImage(urlString: channel.logoURL,
                                size: CGSize(width: 34, height: 17),
                                cornerRadius: 3)
                    Text("\(String(format: "%02d", tv.channelNumber(for: channel))) · \(channel.name)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .lineLimit(1)
                    Text(type.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(TVBrand.gold.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(TVBrand.gold.opacity(0.13), in: Capsule(style: .continuous))
                    if tv.isFollowedSport(program.title) {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text("关注")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundStyle(TVBrand.gold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(TVBrand.gold.opacity(0.16), in: Capsule(style: .continuous))
                    }
                    if isTomorrow {
                        Text("明天")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(TVBrand.wave.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(TVBrand.wave.opacity(0.10), in: Capsule(style: .continuous))
                    }
                    if event.simulcast > 1 {
                        // 同播多台：赛事详情直接在这里换台，不必先进入某一家再翻。
                        Menu {
                            ForEach(Array(event.channels.enumerated()), id: \.element.id) { _, item in
                                Button {
                                    openSport(event, channel: item, now: now)
                                } label: {
                                    Text("\(String(format: "%02d", tv.channelNumber(for: item))) · \(item.name)")
                                }
                            }
                        } label: {
                            Text("\(event.simulcast) 台同播")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(TVBrand.wave.opacity(0.85))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("换一台同播频道")
                    }
                }
            }

            Spacer(minLength: 10)

            Button {
                openSport(event, now: now)
            } label: {
                HStack(spacing: 5) {
                    if live {
                        Circle()
                            .fill(TVBrand.onGold)
                            .frame(width: 5, height: 5)
                    }
                    Text(live ? "看直播"
                         : (past ? (canCatchUp ? "回看" : "已结束")
                            : (reminded ? "已提醒" : "开赛提醒")))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(live || reminded ? TVBrand.onGold : tint)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .background(live ? TVBrand.signal : (reminded ? TVBrand.gold : Color.clear),
                            in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(live || reminded ? Color.clear : tint.opacity(0.5),
                                  lineWidth: 0.7))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(past && !canCatchUp)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovered ? tint.opacity(0.75) : Color.clear)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(TVBrand.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(tint.opacity(hovered ? 0.07 : 0))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(live ? TVBrand.signal.opacity(0.35)
                                   : (hovered ? tint.opacity(0.42) : TVBrand.stroke),
                              lineWidth: 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture { openSport(event, now: now) }
        .onHover { inside in
            if inside {
                hoveredSportKey = event.key
            } else if hoveredSportKey == event.key {
                hoveredSportKey = nil
            }
        }
        .contextMenu {
            // 关注：从标题里拆出的球队 / 联赛各给一个开关。
            ForEach(tv.followCandidates(in: program.title), id: \.self) { keyword in
                Button(tv.isFollowingSport(keyword)
                       ? "取消关注「\(keyword)」"
                       : "关注「\(keyword)」") {
                    tv.toggleSportFollow(keyword)
                }
            }
            Divider()
            Button("定时录制") {
                tv.scheduleRecording(channel: channel, program: program)
            }
            if program.isLive {
                Button("立即录制 30 秒") {
                    tv.recordNow(channel: channel, title: program.title)
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// 行与按钮共用一套动作：直播直接进频道，结束的能回看就回看，未开赛的加提醒。
    private func openSport(_ event: TVSportEvent, now: Date) {
        openSport(event, channel: event.channel, now: now)
    }

    /// 指定同播频道时的动作：多台同播菜单与默认动作走同一份判断。
    private func openSport(_ event: TVSportEvent, channel: TVChannel, now: Date) {
        let program = event.program
        if program.isLive {
            store.openTVChannel(channel)
        } else if program.end <= now {
            if !(channel.catchUpSource ?? "").isEmpty {
                store.openTVCatchup(channel, program: program)
            }
        } else {
            tv.toggleReminder(program, channel: channel)
        }
    }

    // MARK: 黄金时段

    private func primeSection(_ snapshot: TVTonightSnapshot,
                              followed: Set<String>,
                              now: Date) -> some View {
        let picks = snapshot.picks
        // 按类型分组一次，类型胶囊与网格共用。
        let grouped = Dictionary(grouping: picks, by: \.category)
        let available = TVGuideCategory.allCases.filter { !(grouped[$0] ?? []).isEmpty }
        let selected = primeCategory.flatMap { grouped[$0] } ?? []
        var shown = selected.isEmpty ? picks : selected
        if let primeSlot {
            shown = shown.filter { primeSlotIndex(for: $0.program.start, now: now) == primeSlot }
        }
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle(symbol: "sparkles",
                         tint: TVBrand.wave,
                         title: "黄金时段",
                         detail: "19:30–23:30 · \(picks.count) 档精选 · 跨频道同播合并")
            if picks.isEmpty {
                emptyHint(symbol: "sparkles",
                          text: "这一时段还没有可推荐的节目；没有节目单的源不会参与。")
            } else {
                primeHeatStrip(snapshot.primeSlots, now: now)
                // 类型平铺 + 自适应网格：不再一排排横向拖动。
                CatalogFlowLayout(spacing: 8, lineSpacing: 8) {
                    primeChip(nil, label: "全部", count: picks.count, tint: TVBrand.wave)
                    ForEach(available) { category in
                        primeChip(category, label: category.title,
                                  count: (grouped[category] ?? []).count,
                                  tint: category.tint)
                    }
                }
                if shown.isEmpty {
                    emptyHint(symbol: "line.3.horizontal.decrease.circle",
                              text: "这个时段没有符合当前筛选的精选；点一下热度条或「全部」恢复。")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460),
                                                 spacing: 14)],
                              alignment: .leading, spacing: 14) {
                        ForEach(shown) { pick in
                            primeCard(pick, followed: followed.contains(pick.program.id), now: now)
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: primeCategory)
                    .animation(.easeOut(duration: 0.18), value: primeSlot)
                }
            }
        }
    }

    /// 节目开播时间落在黄金时段的第几个 30 分钟格子里。
    private func primeSlotIndex(for start: Date, now: Date) -> Int {
        guard let window = TVTonightRules.primeWindow(on: now) else { return 0 }
        return max(0, Int(start.timeIntervalSince(window.start) / 1800))
    }

    /// 黄金时段类型胶囊：点一下只看这一类。
    private func primeChip(_ category: TVGuideCategory?, label: String,
                           count: Int, tint: Color) -> some View {
        let active = primeCategory == category
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { primeCategory = category }
        } label: {
            HStack(spacing: 6) {
                if let category {
                    Image(systemName: category.symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.8)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background((active ? TVBrand.onGold : Color.primary).opacity(0.12),
                                in: Capsule(style: .continuous))
            }
            .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(active ? tint : Color.primary.opacity(0.05),
                        in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(active ? "点一下取消筛选" : "只看\(label)")
    }

    /// 黄金时段热力条：19:30 起每 30 分钟一格，格子的颜色是该时段占比最高的类型，
    /// 深浅表示这一格有多少档节目。数字来自全量节目统计，点格子可只看这一时段。
    private func primeHeatStrip(_ slots: [TVPrimeSlot], now: Date) -> some View {
        let base = TVTonightRules.primeWindow(on: now)?.start ?? now
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("时段热度")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("19:30 — 23:30 · 每格 30 分钟 · 点格子筛选")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if primeSlot != nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { primeSlot = nil }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                            Text("显示全部时段")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(TVBrand.wave)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(TVBrand.wave.opacity(0.10), in: Capsule(style: .continuous))
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                ForEach(slots) { slot in
                    let start = base.addingTimeInterval(Double(slot.index) * 1800)
                    let end = start.addingTimeInterval(1800)
                    let active = primeSlot == slot.index
                    let tint = slot.category?.tint ?? Color.secondary
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            primeSlot = active ? nil : slot.index
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(Self.clock.string(from: start))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(active ? tint : Color.secondary.opacity(0.8))
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(tint.opacity(slot.count == 0
                                                   ? 0.06
                                                   : 0.16 + min(0.36, Double(slot.count) * 0.05)))
                                .frame(height: 38)
                                .overlay {
                                    Text(slot.count == 0 ? "–" : "\(slot.count)")
                                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                        .foregroundStyle(slot.count == 0
                                                         ? Color.secondary.opacity(0.6)
                                                         : tint)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(active ? tint : tint.opacity(slot.count == 0 ? 0.06 : 0.28),
                                                      lineWidth: active ? 1.6 : 0.5)
                                }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(slot.count == 0)
                    .help("\(Self.clock.string(from: start))–\(Self.clock.string(from: end)) · \(slot.count) 档\(slot.category.map { " · 以\($0.title)为主" } ?? "")")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(TVBrand.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(TVBrand.stroke, lineWidth: 0.6)
        }
    }

    private func primeCard(_ pick: TVPrimePick, followed: Bool, now: Date) -> some View {
        let program = pick.program
        let channel = pick.channel
        let live = program.isLive
        let past = program.end <= now
        let canCatchUp = past && !(channel.catchUpSource ?? "").isEmpty
        let reminded = tv.isReminded(program)
        let tint = pick.category.tint
        let hovered = hoveredPrimeKey == pick.key
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(Self.clock.string(from: program.start))
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                Text("– " + Self.clock.string(from: program.end))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if live {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(TVBrand.onGold)
                            .frame(width: 4, height: 4)
                        Text("直播中")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundStyle(TVBrand.onGold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(TVBrand.signal, in: Capsule(style: .continuous))
                }
                Spacer(minLength: 0)
                Button {
                    tv.toggleSubscription(program, channel: channel)
                } label: {
                    Image(systemName: followed ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(followed ? TVBrand.gold : Color.secondary)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(followed ? "取消追这档节目" : "追这档节目：未来几天自动提醒")
            }

            Text(program.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                TVLogoImage(urlString: channel.logoURL,
                            size: CGSize(width: 34, height: 17),
                            cornerRadius: 3)
                Text("\(String(format: "%02d", tv.channelNumber(for: channel))) · \(channel.name)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(1)
                if pick.simulcast > 1 {
                    Text("\(pick.simulcast) 台同播")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(TVBrand.wave.opacity(0.85))
                }
            }

            HStack(spacing: 5) {
                ForEach(pick.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tint.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
                }
                Spacer(minLength: 4)
                Button {
                    openPrime(pick, now: now)
                } label: {
                    Text(live ? "看直播"
                         : (past ? (canCatchUp ? "回看" : "已结束")
                            : (reminded ? "已提醒" : "开播提醒")))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(live || reminded ? TVBrand.onGold : tint)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(live ? TVBrand.signal : (reminded ? TVBrand.gold : Color.clear),
                                    in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(live || reminded ? Color.clear : tint.opacity(0.5),
                                          lineWidth: 0.7))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(past && !canCatchUp)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TVBrand.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(hovered ? 0.14 : 0.06),
                                                      Color.clear],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [tint.opacity(live ? 0.6 : (hovered ? 0.55 : 0.3)),
                                                      tint.opacity(0.08)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing),
                              lineWidth: hovered ? 1.1 : 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { openPrime(pick, now: now) }
        .onHover { inside in
            if inside {
                hoveredPrimeKey = pick.key
            } else if hoveredPrimeKey == pick.key {
                hoveredPrimeKey = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// 卡片与按钮共用一套动作。
    private func openPrime(_ pick: TVPrimePick, now: Date) {
        let program = pick.program
        let channel = pick.channel
        if program.isLive {
            store.openTVChannel(channel)
        } else if program.end <= now {
            if !(channel.catchUpSource ?? "").isEmpty {
                store.openTVCatchup(channel, program: program)
            }
        } else {
            tv.toggleReminder(program, channel: channel)
        }
    }

    // MARK: 综艺 / 人物记录

    /// 综艺与人物记录共用一条横向货架：同名节目跨台合并，正在播的排最前。
    private func showShelf(title: String, symbol: String, tint: Color, detail: String,
                           picks: [TVShowPick], emptyText: String, now: Date) -> some View {
        let expanded = expandedShelves.contains(title)
        let collapseLimit = 6
        let shown = expanded ? picks : Array(picks.prefix(collapseLimit))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                sectionTitle(symbol: symbol, tint: tint, title: title, detail: detail)
                if picks.count > collapseLimit {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { toggleShelf(title) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "收起" : "全部 \(picks.count) 档")
                                .font(.system(size: 11.5, weight: .medium))
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .foregroundStyle(tint)
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            if picks.isEmpty {
                emptyHint(symbol: symbol, text: emptyText)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360),
                                             spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    ForEach(shown) { pick in
                        showCard(pick, tint: tint, now: now)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: expanded)
            }
        }
    }

    private func toggleShelf(_ title: String) {
        if expandedShelves.contains(title) {
            expandedShelves.remove(title)
        } else {
            expandedShelves.insert(title)
        }
    }

    private func showCard(_ pick: TVShowPick, tint: Color, now: Date) -> some View {
        let program = pick.program
        let channel = pick.channel
        let live = program.isLive
        let past = program.end <= now
        let canCatchUp = past && !(channel.catchUpSource ?? "").isEmpty
        let reminded = tv.isReminded(program)
        let hovered = hoveredShowKey == pick.key
        return VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 7) {
                    Text(Self.clock.string(from: program.start))
                        .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(tint)
                    Text("– " + Self.clock.string(from: program.end))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if live {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(TVBrand.onGold)
                                .frame(width: 4, height: 4)
                            Text("直播中")
                                .font(.system(size: 9.5, weight: .bold))
                        }
                        .foregroundStyle(TVBrand.onGold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(TVBrand.signal, in: Capsule(style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
                // 节目名首字做一枚淡色水印，卡片不用封面也有辨识度。
                Text(String(program.title.prefix(1)))
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(tint.opacity(0.10))
                    .offset(x: 2, y: -22)
                    .allowsHitTesting(false)
            }

            Text(program.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(past && !canCatchUp ? Color.secondary : Color.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                TVLogoImage(urlString: channel.logoURL,
                            size: CGSize(width: 34, height: 17),
                            cornerRadius: 3)
                Text("\(String(format: "%02d", tv.channelNumber(for: channel))) · \(channel.name)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(1)
                if pick.simulcast > 1 {
                    Text("\(pick.simulcast) 台")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(TVBrand.wave.opacity(0.8))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button {
                    openShow(pick, now: now)
                } label: {
                    Text(live ? "看直播"
                         : (past ? (canCatchUp ? "回看" : "已结束")
                            : (reminded ? "已提醒" : "开播提醒")))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(live || reminded ? TVBrand.onGold : tint)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(live ? TVBrand.signal : (reminded ? TVBrand.gold : Color.clear),
                                    in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(live || reminded ? Color.clear : tint.opacity(0.5),
                                          lineWidth: 0.7))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(past && !canCatchUp)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TVBrand.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(hovered ? 0.14 : 0.06),
                                                      Color.clear],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [tint.opacity(live ? 0.6 : (hovered ? 0.5 : 0.28)),
                                                      tint.opacity(0.06)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing),
                              lineWidth: hovered ? 1.1 : 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { openShow(pick, now: now) }
        .onHover { inside in
            if inside {
                hoveredShowKey = pick.key
            } else if hoveredShowKey == pick.key {
                hoveredShowKey = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// 卡片与按钮共用一套动作。
    private func openShow(_ pick: TVShowPick, now: Date) {
        let program = pick.program
        let channel = pick.channel
        if program.isLive {
            store.openTVChannel(channel)
        } else if program.end <= now {
            if !(channel.catchUpSource ?? "").isEmpty {
                store.openTVCatchup(channel, program: program)
            }
        } else {
            tv.toggleReminder(program, channel: channel)
        }
    }

    // MARK: 规则

    private var rulesPanel: some View {
        TVTonightRulesCard(compact: false)
    }

    // MARK: 小件

    private func sectionTitle(symbol: String, tint: Color,
                              title: String, detail: String) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.13))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 24, height: 24)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.2)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func emptyHint(symbol: String, text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(TVBrand.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TVBrand.stroke, lineWidth: 0.6)
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// 推荐规则说明：页面底部平铺一版，右上角「推荐规则」弹层用紧凑版。
private struct TVTonightRulesCard: View {
    var compact: Bool

    private struct Rule: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let rules: [Rule] = [
        Rule(symbol: "sportscourt",
             title: "赛事识别",
             detail: "标题里出现足球 / 篮球 / 联赛 / 杯 / 决赛 / NBA / 世界杯 等关键词；体育频道的整档节目也算。体育新闻、赛事预告这类栏目会被排除。"),
        Rule(symbol: "square.grid.2x2",
             title: "四个角度",
             detail: "当前热播＝正在直播；即将开赛＝今天接下来 14 小时；历史＝今天已经结束（有回看源的给「回看」）；未来＝明天的节目单。"),
        Rule(symbol: "sportscourt.fill",
             title: "体育类型",
             detail: "从标题识别世界杯 / 奥运 / 足球 / 篮球 / 排球 / 羽毛球 / 乒乓球 / 网球 / 斯诺克 / 田径 / 游泳 / 冰雪 / 格斗 / 赛车 / 电竞 / 高尔夫 / 棒球 / 综合；只列出当前角度里出现过的类型。"),
        Rule(symbol: "clock.badge.checkmark",
             title: "黄金时段",
             detail: "19:30–23:30 每 30 分钟一格做「时段热度」：格子颜色是该时段占比最高的类型，数量是这一格的档数；下面按类型过滤，自适应网格排开，点卡片直接播放或回看。"),
        Rule(symbol: "sparkles",
             title: "综艺与人物",
             detail: "综艺看标题里的节目名与类型词；人物记录优先「讲人」的纪实（人物 / 大师 / 匠心 / 传奇 / 档案）。同名节目跨台只留一条，正在播的排最前，默认先看 6 档、可展开全部。"),
        Rule(symbol: "chart.bar",
             title: "合并与排序",
             detail: "同播优先 CCTV-5、体育频道、CCTV 与卫视；黄金时段评分看同播台数、类型权重、决赛 / 首播 / 直播与靠近 20:00 的程度。")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 13) {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TVBrand.wave)
                Text("夜航推荐规则")
                    .font(.system(size: compact ? 13.5 : 16, weight: .semibold))
                Spacer(minLength: 0)
                if !compact {
                    Text("直播页的两条货架与本页共用同一套规则")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: compact ? 8 : 11) {
                ForEach(rules) { rule in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: rule.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TVBrand.wave.opacity(0.9))
                            .frame(width: 16)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.title)
                                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                            Text(rule.detail)
                                .font(.system(size: compact ? 11 : 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(compact ? 0 : 18)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(TVBrand.surface)
            }
        }
        .overlay {
            if !compact {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(TVBrand.stroke, lineWidth: 0.6)
            }
        }
    }
}

