import NanoCore
import NanoDesignSystem
import NanoSync
import NanoVFS
import SwiftUI

/// 全局统一搜索与流式分域聚合视图（1:1 对齐参考图：「关键词」标题 + 分类计数胶囊栏 + 异步检索进度行 + 分组卡片流）
public struct UnifiedSearchView: View {
    @Bindable public var appVM: NanoAppViewModel
    @State private var inputKeyword: String = ""

    public init(appVM: NanoAppViewModel) {
        self.appVM = appVM
    }

    private var coordinator: UnifiedSearchCoordinator {
        appVM.searchCoordinator
    }

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: NanoPalette.electricBlue) {
            VStack(alignment: .leading, spacing: 0) {
                // 1. 顶部搜索输入头与分域说明
                headerSearchInputSection
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                Divider().overlay(NanoPalette.subtleBorder)

                // 2. 主体流式结果区或快捷引导区
                if coordinator.query.isEmpty {
                    emptyPromptAndHotTagsSection
                } else {
                    streamingResultsScrollSection
                }
            }
        }
        .onAppear {
            inputKeyword = coordinator.query
        }
    }

    // MARK: - 顶部输入与标题胶囊栏（参考图上半部）

    private var headerSearchInputSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 顶部面包屑标识 + 搜索输入框
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(NanoPalette.electricBlue)
                    Text("统一搜索")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(NanoPalette.electricBlue)
                    Text("网盘 · 影院 · 网络影院 · 电视 · 资源 · 音乐")
                        .font(.system(size: 12))
                        .foregroundStyle(NanoPalette.textMuted)
                }

                Spacer()

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(NanoPalette.textMuted)
                    TextField("搜索片名、电视台、省份（如：上海）、演员、歌曲...", text: $inputKeyword)
                        .textFieldStyle(.plain)
                        .foregroundStyle(NanoPalette.textPrimary)
                        .frame(minWidth: 280)
                        .onSubmit {
                            coordinator.performUnifiedSearch(keyword: inputKeyword, in: appVM)
                        }
                    if !inputKeyword.isEmpty {
                        Button {
                            inputKeyword = ""
                            coordinator.performUnifiedSearch(keyword: "", in: appVM)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(NanoPalette.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        coordinator.performUnifiedSearch(keyword: inputKeyword, in: appVM)
                    } label: {
                        Text("搜索")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(NanoPalette.electricBlue))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                        .overlay(Capsule().strokeBorder(NanoPalette.subtleBorder, lineWidth: 1))
                )
            }

            if !coordinator.query.isEmpty {
                // 大号「关键词」标题与总命中计数
                VStack(alignment: .leading, spacing: 6) {
                    Text("「\(coordinator.query)」")
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(NanoPalette.textPrimary)

                    Text("共 \(coordinator.results.count) 项")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NanoPalette.textSecondary)
                }

                // 横向多域分类计数胶囊栏（全部 | 网盘 | 影院 | 网络影院 | 电视 | 资源 | 音乐）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(UnifiedSearchScope.allCases) { scope in
                            scopeFilterPill(scope)
                        }
                    }
                }
            }
        }
    }

    private func scopeFilterPill(_ scope: UnifiedSearchScope) -> some View {
        let isSelected = (coordinator.activeScope == scope)
        let itemCount = coordinator.count(for: scope)

        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                coordinator.activeScope = scope
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: scope.systemIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : iconTint(for: scope))

                Text(scope.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : NanoPalette.textPrimary)

                Text("\(itemCount)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? .white.opacity(0.92) : NanoPalette.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? NanoPalette.electricBlue : Color.white.opacity(0.06))
                    .overlay(
                        Capsule()
                            .strokeBorder(isSelected ? Color.clear : NanoPalette.subtleBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 异步流式加载进度行 + 分组结果卡片流（参考图下半部）

    private var streamingResultsScrollSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // 实时显示尚未完成的远程检索通道状态（复刻参考图「正在检索网盘... / 正在检索网络影院...」）
                let pendingList = UnifiedSearchScope.allCases.filter {
                    $0 != .all && coordinator.searchingScopes.contains($0) && (coordinator.activeScope == .all || coordinator.activeScope == $0)
                }

                if !pendingList.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(pendingList) { pending in
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(pending.loadingStatusPrompt)
                                    .font(.system(size: 13))
                                    .foregroundStyle(NanoPalette.textSecondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                // 分组展示已返回的各域结果
                ForEach(coordinator.groupedSections, id: \.scope) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        // 分组头徽章（如 `[📺] 电视  4`）
                        HStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(iconTint(for: section.scope).opacity(0.18))
                                    .frame(width: 26, height: 26)
                                Image(systemName: section.scope.systemIcon)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(iconTint(for: section.scope))
                            }

                            Text(section.scope.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(NanoPalette.textPrimary)

                            Text("\(section.items.count)")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(NanoPalette.textMuted)
                        }

                        // 条目卡片列表
                        VStack(spacing: 8) {
                            ForEach(section.items) { item in
                                searchResultRowCard(item)
                            }
                        }
                    }
                }

                if coordinator.searchingScopes.isEmpty && coordinator.filteredResults.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(NanoPalette.textMuted)
                        Text("未在「\(coordinator.activeScope.title)」分类下找到与「\(coordinator.query)」匹配的内容")
                            .font(.system(size: 14))
                            .foregroundStyle(NanoPalette.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                }
            }
            .padding(28)
        }
    }

    private func searchResultRowCard(_ item: UnifiedSearchResultItem) -> some View {
        NanoGlassCard(cornerRadius: 12, padding: 12) {
            triggerAction(item.action)
        } content: {
            HStack(spacing: 14) {
                // 左侧台标 / 封面图标框（复刻参考图左侧圆角白底/半透明台标卡）
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 56, height: 40)

                    if let art = item.artworkURL, let url = URL(string: art) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFit().padding(4)
                            } else {
                                fallbackRowIcon(for: item.scope)
                            }
                        }
                        .frame(width: 56, height: 40)
                    } else {
                        fallbackRowIcon(for: item.scope)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(NanoPalette.textPrimary)
                            .lineLimit(1)

                        if let badge = item.badgeText, !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(NanoPalette.amberGold))
                        }
                    }

                    Text(item.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(NanoPalette.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(NanoPalette.electricBlue.opacity(0.9))
            }
        }
    }

    private func fallbackRowIcon(for scope: UnifiedSearchScope) -> some View {
        Image(systemName: scope.systemIcon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(iconTint(for: scope))
    }

    // MARK: - 默认未搜索时的历史记录与地域/分类快搜引导

    private var emptyPromptAndHotTagsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近搜索与快捷体验词")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NanoPalette.textPrimary)

                    HStack(spacing: 10) {
                        ForEach(coordinator.recentQueries, id: \.self) { tag in
                            Button {
                                inputKeyword = tag
                                coordinator.performUnifiedSearch(keyword: tag, in: appVM)
                            } label: {
                                Label(tag, systemImage: "clock.arrow.circlepath")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(NanoPalette.textPrimary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(Color.white.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("按地域与题材一键检索")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NanoPalette.textPrimary)

                    let quickTags = ["上海", "北京", "湖南", "香港", "台湾", "4K", "Dolby Vision", "喜剧", "科幻", "蔡琴"]
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 10)], spacing: 10) {
                        ForEach(quickTags, id: \.self) { word in
                            NanoGlassCard(cornerRadius: 10, padding: 10) {
                                inputKeyword = word
                                coordinator.performUnifiedSearch(keyword: word, in: appVM)
                            } content: {
                                HStack {
                                    Text(word)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(NanoPalette.textPrimary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 11))
                                        .foregroundStyle(NanoPalette.textMuted)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private func iconTint(for scope: UnifiedSearchScope) -> Color {
        switch scope {
        case .all: return NanoPalette.electricBlue
        case .cloudDrive: return NanoPalette.onlineGreen
        case .cinema: return NanoPalette.amberGold
        case .networkCinema: return Color.pink
        case .liveTV: return Color.cyan
        case .remoteResource: return Color.purple
        case .music: return Color.orange
        }
    }

    private func triggerAction(_ payload: UnifiedSearchActionPayload) {
        switch payload {
        case .openCinemaMedia(let mediaID):
            appVM.selectedSection = .cinemaDetail(mediaID)

        case .playLiveChannel(let channelID, let lineIdx):
            guard let ch = appVM.liveChannels.first(where: { $0.id == channelID }) else { return }
            Task {
                await appVM.player.playLiveChannel(ch, lineIndex: lineIdx)
                appVM.isPresentingFullPlayer = true
            }

        case .playVFSNode(let sourceID, let path, let fileID, let isAudio):
            guard let src = appVM.storageSources.first(where: { $0.id == sourceID }) else { return }
            Task {
                let openToken = iCloudKeychainVault.shared.readSecret(forKey: "\(src.keychainCredentialID)_openapi")
                let secret = iCloudKeychainVault.shared.readSecret(forKey: "\(src.keychainCredentialID)_secret") ?? ""
                let user = iCloudKeychainVault.shared.readSecret(forKey: "\(src.keychainCredentialID)_user") ?? ""
                let coord = VFSDriverRegistry.makeDualTrackCoordinator(for: src, openAPIToken: openToken, cookieHeader: secret, basicUsername: user)
                let node = VFSNode(sourceID: src.id, fileID: fileID, name: (path as NSString).lastPathComponent, path: path, kind: isAudio ? .audio : .video)
                if let ticket = try? await coord.resolvePlayableTicket(for: node) {
                    await appVM.player.startPlayback(ticket: ticket, persistenceKey: "\(src.id.uuidString)_\(path)")
                    if !isAudio {
                        await MainActor.run { appVM.isPresentingFullPlayer = true }
                    }
                } else if path == "/Music/渡口.flac" || path.hasPrefix("/Music/") {
                    let demoURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")!
                    await appVM.player.startPlayback(ticket: PlayableStreamTicket(title: (path as NSString).lastPathComponent, subtitle: src.name, streamURL: demoURL))
                }
            }

        case .playRemoteStream(let title, let siteName, let streamURL):
            guard let url = URL(string: streamURL) else { return }
            let ticket = PlayableStreamTicket(title: title, subtitle: siteName, streamURL: url)
            Task {
                await appVM.player.startPlayback(ticket: ticket)
                appVM.isPresentingFullPlayer = true
            }
        }
    }
}
