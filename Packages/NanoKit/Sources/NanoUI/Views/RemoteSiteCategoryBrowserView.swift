import NanoCore
import NanoDesignSystem
import NanoRemoteHub
import SwiftUI

/// 远程资源站点二级分类瀑布流与选集播放页（支持按站点真实分类标签筛选、站内搜索与多线路选集）
public struct RemoteSiteCategoryBrowserView: View {
    @Bindable public var appVM: NanoAppViewModel
    public let site: RemoteResourceSite

    @State private var categories: [RemoteResourceEngineHub.RemoteSiteCategory] = []
    @State private var selectedCategoryID: String = "all"
    @State private var vodList: [RemoteVodEntry] = []
    @State private var currentPage: Int = 1
    @State private var siteSearchKeyword: String = ""
    @State private var isLoading: Bool = false
    @State private var selectedVodForEpisodes: RemoteVodEntry?

    public init(appVM: NanoAppViewModel, site: RemoteResourceSite) {
        self.appVM = appVM
        self.site = site
    }

    private static let fallbackCategories: [RemoteResourceEngineHub.RemoteSiteCategory] = [
        .init(id: "all", name: "最新推荐"),
        .init(id: "1", name: "电影"),
        .init(id: "2", name: "连续剧"),
        .init(id: "3", name: "综艺"),
        .init(id: "4", name: "动漫"),
        .init(id: "6", name: "动作片"),
        .init(id: "7", name: "喜剧片"),
        .init(id: "9", name: "科幻片")
    ]

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: NanoPalette.electricBlue) {
            VStack(alignment: .leading, spacing: 16) {
                // 1. 顶部站点返回栏与站内搜索
                HStack(spacing: 12) {
                    Button {
                        appVM.selectedSection = .remoteResourceHub
                    } label: {
                        Label("返回资源中心", systemImage: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NanoPalette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)

                    Text(site.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(NanoPalette.textPrimary)

                    Text(site.engineType.badgeTitle)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(NanoPalette.amberGold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(NanoPalette.amberGold.opacity(0.15)))

                    Spacer()

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(NanoPalette.textMuted)
                        TextField("在 \(site.name) 内搜索...", text: $siteSearchKeyword)
                            .textFieldStyle(.plain)
                            .foregroundStyle(NanoPalette.textPrimary)
                            .frame(width: 190)
                            .onSubmit {
                                currentPage = 1
                                Task { await loadVodEntries() }
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                // 2. 横向分类胶囊切换条
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        let displayCats = categories.isEmpty ? Self.fallbackCategories : ([.init(id: "all", name: "全部最新")] + categories)
                        ForEach(displayCats) { cat in
                            let isSel = (selectedCategoryID == cat.id)
                            Button {
                                selectedCategoryID = cat.id
                                currentPage = 1
                                siteSearchKeyword = ""
                                Task { await loadVodEntries() }
                            } label: {
                                Text(cat.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(isSel ? .white : NanoPalette.textSecondary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(isSel ? NanoPalette.electricBlue : Color.white.opacity(0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                // 3. 影片卡片网格
                if isLoading {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView("正在拉取「\(site.name)」分类内容...")
                            .foregroundStyle(NanoPalette.textSecondary)
                        Spacer()
                    }
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            let columns = [GridItem(.adaptive(minimum: 185, maximum: 225), spacing: 18)]
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(vodList) { vod in
                                    vodPosterCard(vod)
                                }
                            }

                            if !vodList.isEmpty {
                                HStack(spacing: 16) {
                                    Button("上一页") {
                                        guard currentPage > 1 else { return }
                                        currentPage -= 1
                                        Task { await loadVodEntries() }
                                    }
                                    .disabled(currentPage <= 1)
                                    .buttonStyle(.bordered)

                                    Text("第 \(currentPage) 页")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(NanoPalette.textSecondary)

                                    Button("下一页") {
                                        currentPage += 1
                                        Task { await loadVodEntries() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .padding(.top, 8)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                    }
                }
            }
        }
        .sheet(item: $selectedVodForEpisodes) { vod in
            vodEpisodeSelectorSheet(vod)
        }
        .task(id: site.id) {
            await loadCategoriesAndInitialList()
        }
    }

    private func vodPosterCard(_ vod: RemoteVodEntry) -> some View {
        NanoGlassCard(cornerRadius: 14, padding: 10) {
            selectedVodForEpisodes = vod
        } content: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    if let pic = vod.coverURL, let url = URL(string: pic) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFill()
                            } else {
                                placeholderCover(vod)
                            }
                        }
                        .frame(height: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        placeholderCover(vod)
                            .frame(height: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    if !vod.remarks.isEmpty {
                        Text(vod.remarks)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(NanoPalette.amberGold))
                            .padding(8)
                    }
                }

                Text(vod.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NanoPalette.textPrimary)
                    .lineLimit(1)

                Text(vod.categoryName.isEmpty ? site.name : vod.categoryName)
                    .font(.system(size: 11))
                    .foregroundStyle(NanoPalette.textMuted)
            }
        }
    }

    private func placeholderCover(_ vod: RemoteVodEntry) -> some View {
        ZStack {
            LinearGradient(colors: [NanoPalette.electricBlue.opacity(0.35), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(NanoPalette.amberGold)
                Text(vod.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
    }

    private func vodEpisodeSelectorSheet(_ vod: RemoteVodEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(vod.title)
                .font(.title3.bold())
            if !vod.overview.isEmpty {
                Text(vod.overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(vod.playRoutes) { route in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("线路：\(route.routeName)")
                                .font(.subheadline.bold())
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 125), spacing: 8)], spacing: 8) {
                                ForEach(route.episodes) { ep in
                                    Button(ep.title) {
                                        guard let url = URL(string: ep.url) else { return }
                                        selectedVodForEpisodes = nil
                                        let ticket = PlayableStreamTicket(title: "\(vod.title) · \(ep.title)", subtitle: "\(site.name) · \(route.routeName)", streamURL: url)
                                        Task {
                                            await appVM.player.startPlayback(ticket: ticket)
                                            appVM.isPresentingFullPlayer = true
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("关闭") { selectedVodForEpisodes = nil }
            }
        }
        .padding(24)
        .frame(minWidth: 540)
    }

    @MainActor
    private func loadCategoriesAndInitialList() async {
        if site.engineType == .macCMSJson || site.engineType == .fongMiTVBox {
            if let fetchedCats = try? await RemoteResourceEngineHub.fetchMacCMSCategories(site: site), !fetchedCats.isEmpty {
                self.categories = fetchedCats
            }
        }
        await loadVodEntries()
    }

    @MainActor
    private func loadVodEntries() async {
        isLoading = true
        var list: [RemoteVodEntry] = []
        switch site.engineType {
        case .macCMSJson, .fongMiTVBox:
            list = (try? await RemoteResourceEngineHub.fetchMacCMSListOrSearch(
                site: site,
                categoryTypeID: selectedCategoryID,
                keyword: siteSearchKeyword.isEmpty ? nil : siteSearchKeyword,
                page: currentPage
            )) ?? []
        case .customWebRule:
            list = (try? await RemoteResourceEngineHub.executeWebCrawlerList(
                site: site,
                keyword: siteSearchKeyword.isEmpty ? nil : siteSearchKeyword,
                page: currentPage
            )) ?? []
        }

        // 若演示域名不可达，提供示例条目以便直观体验分类选集交互
        if list.isEmpty && site.apiURL.contains(".example.org") {
            list = [
                RemoteVodEntry(
                    siteID: site.id,
                    siteName: site.name,
                    vodID: "demo_1",
                    title: "深海迷航 4K 修复版",
                    remarks: "4K HDR 中字",
                    categoryName: "科幻片",
                    overview: "来自 \(site.name) 分类浏览示例条目，接入真实苹果 CMS / FongMi 订阅后自动拉取实时片库。",
                    playRoutes: [
                        RemotePlayRoute(routeName: "极速4K专线", episodes: [
                            RemotePlayEpisode(title: "超清正片", url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")
                        ])
                    ]
                ),
                RemoteVodEntry(
                    siteID: site.id,
                    siteName: site.name,
                    vodID: "demo_2",
                    title: "繁花似锦 · 剧场版",
                    remarks: "更新至30集",
                    categoryName: "连续剧",
                    overview: "支持多播放线路与分集秒选。",
                    playRoutes: [
                        RemotePlayRoute(routeName: "蓝光直连", episodes: [
                            RemotePlayEpisode(title: "第01集", url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"),
                            RemotePlayEpisode(title: "第02集", url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")
                        ])
                    ]
                )
            ]
        }

        self.vodList = list
        isLoading = false
    }
}
