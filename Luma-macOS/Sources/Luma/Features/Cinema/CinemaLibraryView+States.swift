import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 影院页的空状态、首次建库引导与进度条。

extension CinemaLibraryView {
    // MARK: 空状态 / 进度

    var setupBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 20))
                .foregroundStyle(LumaBrand.violet)
            VStack(alignment: .leading, spacing: 5) {
                Text("先填写 TMDB API Key，再开始刮削")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("影院会用文件名匹配电影 / 剧集，自动补上海报、背景图、年份与简介。TMDB 需要一个免费 Key；也可以切成豆瓣数据源，免 Key 直接刮。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("打开设置 › 影院", action: openCinemaSettings)
                    Button("打开 TMDB 申请页") {
                        open("https://www.themoviedb.org/settings/api")
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(LumaBrand.violet.opacity(0.10)))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(LumaBrand.violet.opacity(0.22))
        }
    }

    func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }

    var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在刮削这个链接下的视频  \(store.cinemaScrapeDone) / \(store.cinemaScrapeTotal)")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("取消") {
                    store.cancelCinemaScrape()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .help("取消刮削（已完成的结果会保留）")
                Text("\(Int(store.cinemaScrapeProgress * 100))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: store.cinemaScrapeProgress)
                .controlSize(.small)
        }
    }

    // MARK: 内容

    @ViewBuilder
    var content: some View {
        if store.cinemaTab == .folder {
            folderContent
        } else if allEntries.isEmpty {
            if !store.cinemaIndexLoaded {
                // 索引还在读：先给骨架屏，别让人以为影院是空的。
                skeletonGrid
            } else if showFirstRun {
                firstRunView
            } else {
                emptyState
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if store.cinemaActiveListID != nil {
                    activeListBanner
                }
                if store.cinemaViewMode == .wall {
                    wallStatsBar
                        .padding(.top, -6)
                }
                switch store.cinemaViewMode {
                case .shelf:
                    shelfContent
                case .wall:
                    wallContent
                case .card:
                    cardContent
                case .list:
                    listContent
                }
            }
        }
    }

    /// 索引读取期间的骨架屏：按当前海报墙列宽铺一屏占位卡。
    var skeletonGrid: some View {
        LumaSkeletonGrid(columns: wallColumns, count: 12, cardHeight: 210, footerLines: 2)
    }

    @ViewBuilder
    var activeListBanner: some View {
        if let list = store.cinemaList(store.cinemaActiveListID) {
            HStack(spacing: 8) {
                Image(systemName: list.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                Text("清单 · \(list.name)")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(list.count) 部")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("清除筛选") {
                    store.cinemaActiveListID = nil
                }
                .controlSize(.small)
                Button("删除清单", role: .destructive) {
                    store.deleteCinemaList(list.id)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(LumaBrand.amber.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(LumaBrand.amber.opacity(0.22), lineWidth: 0.8)
            }
        }
    }


    /// 文档约定 D4：未识别空态给命名示例 + 一个「去匹配」主行动，不写「暂无数据」。
    var unmatchedEmptyState: some View {
        LumaEmptyState(symbol: "questionmark.circle",
                       title: "\(unmatched.count) 条影片未识别",
                       message: "命名不规范会导致匹配失败。试试「片名.年份.分辨率」，或手动搜索片名。",
                       actions: unmatched.first.map { entry in
                           [LumaEmptyAction(title: "去匹配") { panelTarget = .match(entry) }]
                       } ?? [])
    }

    var showFirstRun: Bool {
        allEntries.isEmpty && store.cloudMounts.isEmpty && !firstRunDismissed
    }

    /// F5 首次建库：一项主行动 + 三步说明，允许跳过。
    var firstRunView: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: index == 1
                                             ? [LumaBrand.violet.opacity(0.55), Color.black.opacity(0.35)]
                                             : [LumaBrand.amber.opacity(0.45), Color.black.opacity(0.30)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 96, height: 144)
                        .overlay {
                            Image(systemName: index == 2 ? "tv" : "film")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                }
            }
            .opacity(0.34)
            .padding(.trailing, 34)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("LUMA CINEMA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(LumaBrand.amber)
                    Text("把影片放进来，\n剩下的交给影院")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .lineSpacing(3)
                    Text("选择一个目录或网盘，Luma 会扫描视频、自动匹配电影与剧集、生成海报墙。不需要转码，也不复制文件。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .frame(maxWidth: 520, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 18) {
                    firstRunStep("STEP 1", title: "选择来源", detail: "本地目录、夸克、阿里、WebDAV、SMB")
                    firstRunStep("STEP 2", title: "确认扫描规则", detail: "刮削源、NFO、跳过目录")
                    firstRunStep("STEP 3", title: "坐下看片", detail: "继续观看、海报墙、剧集聚合")
                }

                HStack(spacing: 10) {
                    Button {
                        store.presentCloudWizard()
                    } label: {
                        Label("添加片源", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button("稍后再说") {
                        firstRunDismissed = true
                    }
                    .controlSize(.large)
                }

                HStack(spacing: 6) {
                    ForEach(["本地目录", "夸克", "阿里云盘", "百度网盘", "WebDAV", "SMB", "AList"], id: \.self) { name in
                        Text(name)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                            .overlay {
                                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                            }
                    }
                }
            }
            .padding(34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [LumaBrand.amber.opacity(0.06), Color.primary.opacity(0.02)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
        }
    }

    func firstRunStep(_ index: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(index)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(LumaBrand.amber.opacity(0.85))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 168, alignment: .leading)
    }

    var emptyState: some View {
        LumaEmptyState(symbol: "film.stack",
                       title: mountID == nil ? "影院库还是空的" : "这个网盘的影院还是空的",
                       message: needsConfig
                           ? "先在设置里填写 TMDB API Key，或切换成免 Key 的豆瓣数据源，再回到这里刮削。"
                           : (mountID == nil
                              ? "点击顶部的「刮削」按钮开始。会扫描本地视频，按文件名匹配海报、类型与简介。"
                              : "点击顶部的「刮削」按钮会把当前网盘扫描到的视频逐个匹配海报与简介；匹配不上的会放进「未识别」，仍然可以播放。"),
                       actions: needsConfig ? [] : [
                           LumaEmptyAction(title: "开始刮削",
                                           symbol: "sparkles",
                                           filled: true) {
                               store.startCinemaScrape(for: scope)
                           }
                       ])
            .disabled(store.cinemaScrapeRunning)
    }
}
