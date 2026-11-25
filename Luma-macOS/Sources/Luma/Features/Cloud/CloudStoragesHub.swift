import SwiftUI
import AppKit
import Foundation

// MARK: - 分页

/// 网络存储总览的顶层分页：网盘管理 / 图库 / 影院 / 续播。
/// 与「网络资源」一致，切换入口放在窗口工具栏里，内容区不再叠一条控制栏。
/// 「网盘管理」把接入、鉴权、索引、范围与跨源总览收在同一页。
enum CloudStoragesHubTab: String, CaseIterable, Identifiable, Hashable {
    case storages
    case photos
    case cinema
    case resume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .storages: return "网盘管理"
        case .photos: return "图库"
        case .cinema: return "影院"
        case .resume: return "续播"
        }
    }

    var symbol: String {
        switch self {
        case .storages: return "externaldrive.badge.icloud"
        case .photos: return "photo.stack"
        case .cinema: return "film.stack"
        case .resume: return "play.circle.fill"
        }
    }

    static let storageKey = "cloud.storages.hubTab.v1"

    /// 上次停留的分页：重开应用后仍停在同一页；没有记录时落在「网盘管理」。
    /// 旧的「总览 / 管理 / 索引 / 维护」分页都已并入「网盘管理」，读到时直接落过去。
    static var persisted: CloudStoragesHubTab {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return .storages }
        switch raw {
        case "overview", "manage", "index", "maintenance": return .storages
        default: return CloudStoragesHubTab(rawValue: raw) ?? .storages
        }
    }
}

// MARK: - Hub

/// 网络存储区：五个分页共用一层容器，具体内容各自滚动。
struct CloudStoragesHubView: View {
    @EnvironmentObject private var cloud: CloudBrowserModel

    var body: some View {
        Group {
            switch cloud.storagesTab {
            case .storages:
                CloudStoragesManageView()
            case .photos:
                CloudStoragesPhotosView()
            case .cinema:
                CloudStoragesCinemaView()
            case .resume:
                CloudStoragesResumeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 工具栏中区的分页胶囊：总览 / 存储 / 影院 / 续播 / 管理。
struct CloudStoragesHubTabs: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CloudStoragesHubTab.allCases) { tab in
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
    }

    func tabButton(_ tab: CloudStoragesHubTab) -> some View {
        let active = cloud.storagesTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                cloud.setStoragesTab(tab)
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
                        .matchedGeometryEffect(id: "cloud-storage-tab", in: tabNamespace)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }

    func badge(for tab: CloudStoragesHubTab) -> Int? {
        switch tab {
        case .storages:
            return cloud.mounts.count
        case .resume:
            return store.cloudMountContinueRecords.count
        case .photos, .cinema:
            return nil
        }
    }
}

// MARK: - 总览页

/// 跨源总览：把图库、视频与网络存储三源放到同一屏。
/// 所有读数都来自本机索引（图库统计 / 网盘索引 / 影院刮削 / 续播记录），不做联网统计。
/// 现在并入「存储」页，跟在存储卡片下方，不再单独占一个分页。
struct CloudStoragesSnapshotPanels: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel

    @State private var indexStates: [UUID: MetadataStore.CloudIndexState] = [:]

    // MARK: 图库
    var library: LibraryStore.LibraryStats { store.libraryStats }

    // MARK: 网络
    var indexedMounts: Int { indexStates.values.filter { $0.mediaCount > 0 }.count }
    var totalIndexMedia: Int { indexStates.values.reduce(0) { $0 + $1.mediaCount } }
    var totalIndexFolders: Int { indexStates.values.reduce(0) { $0 + $1.folderCount } }
    var maxIndexMedia: Int { max(1, indexStates.values.map(\.mediaCount).max() ?? 0) }

    var latestScan: (mount: CloudMount, state: MetadataStore.CloudIndexState)? {
        cloud.mounts
            .compactMap { mount in
                indexStates[mount.id].map { (mount: mount, state: $0) }
            }
            .max { $0.state.updatedAt < $1.state.updatedAt }
    }

    // MARK: 影院
    var cinemaItems: [CloudMountCinemaItem] {
        cloud.mounts.map { mount in
            let entries = Array(store.cinemaEntries(for: .mount(mount.id)).values)
            return CloudMountCinemaItem(mount: mount,
                                        summary: CloudCinemaSummary(entries: entries))
        }
    }

    var totalMatched: Int { cinemaItems.reduce(0) { $0 + $1.summary.matched } }
    var totalMovies: Int { cinemaItems.reduce(0) { $0 + $1.summary.movies } }
    var totalShows: Int { cinemaItems.reduce(0) { $0 + $1.summary.shows } }

    var latestScraped: (mount: CloudMount, matched: Int, date: Date)? {
        cinemaItems
            .compactMap { item in
                item.summary.lastScrapedAt.map { (mount: item.mount, matched: item.summary.matched, date: $0) }
            }
            .max { $0.date < $1.date }
    }

    // MARK: 续播
    var continueRecords: [CinemaProgressRecord] { store.cloudMountContinueRecords }
    var finishedCount: Int { store.cloudMountFinishedRecords.count }
    var remainingSeconds: Double { continueRecords.reduce(0) { $0 + $1.remainingSeconds } }
    var involvedMounts: Int { Set(continueRecords.compactMap(\.mountID)).count }

    var remainingText: String {
        let hours = remainingSeconds / 3600
        if hours >= 1 { return String(format: "%.1f 小时", hours) }
        return "\(max(0, Int((remainingSeconds / 60).rounded()))) 分钟"
    }

    var hasAnything: Bool {
        !cloud.mounts.isEmpty || library.photos > 0 || library.videos > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("跨源总览")
                    .font(.system(size: 17, weight: .semibold))
                Text("图库 · 视频 · 网络存储的只读读数")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !hasAnything {
                LumaEmptyState(symbol: "chart.pie",
                               title: "还没有可汇总的内容",
                               message: "导入照片或接入网络存储后，图库、视频与网盘的读数会汇总到这里。",
                               style: .card,
                               actions: [LumaEmptyAction(title: "接入存储",
                                                         symbol: "plus") {
                                   store.presentCloudWizard()
                               }])
            } else {
                heroPanel
                compositionPanel
                if !cloud.mounts.isEmpty {
                    volumePanel
                }
                activityPanel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { indexStates = store.cloudIndexStates() }
        .onChange(of: cloud.mounts.count) { _, _ in indexStates = store.cloudIndexStates() }
    }

    /// 四个跨源读数：图库、网络索引、影院识别、待续播。
    var heroPanel: some View {
        CloudHubPanel {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 122), spacing: 10)],
                      alignment: .leading,
                      spacing: 10) {
                CloudHubStatPod(title: "图库项目",
                                value: (library.photos + library.videos).formatted(),
                                unit: "项",
                                detail: "照片 \(library.photos.formatted()) · 视频 \(library.videos.formatted())",
                                symbol: "photo.stack.fill",
                                tint: LumaBrand.violet)
                CloudHubStatPod(title: "网络索引",
                                value: totalIndexMedia.formatted(),
                                unit: "项",
                                detail: "\(indexedMounts)/\(cloud.mounts.count) 个存储已建索引",
                                symbol: "externaldrive.fill.badge.icloud",
                                tint: LumaBrand.cyan)
                CloudHubStatPod(title: "影院识别",
                                value: totalMatched.formatted(),
                                unit: "部",
                                detail: "电影 \(totalMovies.formatted()) · 剧集 \(totalShows.formatted())",
                                symbol: "film.fill",
                                tint: LumaBrand.mint)
                CloudHubStatPod(title: "待续播",
                                value: continueRecords.count.formatted(),
                                unit: "条",
                                detail: continueRecords.isEmpty
                                    ? "没有未看完的视频"
                                    : "\(involvedMounts) 个存储 · 剩 \(remainingText)",
                                symbol: "play.circle.fill",
                                tint: LumaBrand.coral)
            }
        }
    }

    /// 三源构成：图库照片 / 图库视频 / 网络媒体共用一条比例条，影院识别作为网络子集单列。
    var compositionPanel: some View {
        let sources = [
            SnapshotSource(id: "photo", title: "图库照片", value: library.photos, tint: LumaBrand.violet),
            SnapshotSource(id: "video", title: "图库视频", value: library.videos, tint: LumaBrand.cyan),
            SnapshotSource(id: "cloud", title: "网络媒体", value: totalIndexMedia, tint: LumaBrand.amber)
        ]
        let shown = sources.filter { $0.value > 0 }
        let total = sources.reduce(0) { $0 + $1.value }

        return CloudHubPanel(spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("三源构成")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 8)
                Text("共 \(total.formatted()) 项")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if total > 0 {
                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        ForEach(shown) { source in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(LinearGradient(colors: [source.tint, source.tint.opacity(0.60)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(6, (proxy.size.width - CGFloat(shown.count - 1) * 3)
                                                        * CGFloat(source.value) / CGFloat(total)))
                        }
                    }
                }
                .frame(height: 14)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 8)],
                      alignment: .leading,
                      spacing: 8) {
                ForEach(sources) { source in
                    sourceLegend(source, total: total)
                }
            }

            if totalMatched > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "film.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LumaBrand.mint)
                    Text("其中影院已识别 \(totalMatched.formatted()) 部 · 电影 \(totalMovies.formatted()) / 剧集 \(totalShows.formatted())")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    func sourceLegend(_ source: SnapshotSource, total: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(source.tint)
                .frame(width: 7, height: 7)
            Text(source.title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(source.value.formatted())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if total > 0 {
                Text("\(Int((Double(source.value) / Double(total) * 100).rounded()))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 存储体量：每个已建索引的存储一行，用比例条对比媒体条目数。
    var volumePanel: some View {
        let indexed = cloud.mounts.filter { (indexStates[$0.id]?.mediaCount ?? 0) > 0 }
        return CloudHubPanel(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("存储体量")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(totalIndexFolders.formatted()) 个目录")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if indexed.isEmpty {
                Text("还没有索引清单 · 到「管理」里重新扫描后，这里会按存储对比体量。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(indexed) { mount in
                    let media = indexStates[mount.id]?.mediaCount ?? 0
                    HStack(spacing: 10) {
                        Text(mount.name)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 118, alignment: .leading)
                        CloudHubVolumeBar(fraction: Double(media) / Double(maxIndexMedia),
                                          tint: mount.kind.hubTint)
                        Text("\(media.formatted()) 项")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 66, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// 最近动态：观看 / 刮削 / 扫描 / 接入，全部只取本机记录。
    var activityPanel: some View {
        let moments = activities
        return CloudHubPanel(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("最近动态")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 8)
                Text(finishedCount > 0 ? "已看完 \(finishedCount) 条" : "按时间排序")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 8)

            if moments.isEmpty {
                Text("还没有观看、刮削或扫描记录。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(moments.indices, id: \.self) { index in
                    momentRow(moments[index])
                    if index < moments.count - 1 {
                        Divider().opacity(0.35).padding(.leading, 42)
                    }
                }
            }

            Text("读数来自本机索引与播放进度，不统计云端未扫描的内容。")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
                .padding(.top, 10)
        }
    }

    var activities: [SnapshotMoment] {
        var items: [SnapshotMoment] = []

        if let record = continueRecords.first {
            items.append(SnapshotMoment(id: "watch",
                                        symbol: "play.circle.fill",
                                        title: "最近观看 · \(record.title)",
                                        detail: "\(mountName(for: record)) · \(CloudHubFormat.remaining(record.remainingSeconds))",
                                        date: record.updatedAt,
                                        tint: LumaBrand.coral))
        }
        if let scraped = latestScraped {
            items.append(SnapshotMoment(id: "scrape",
                                        symbol: "wand.and.stars",
                                        title: "最近刮削 · \(scraped.mount.name)",
                                        detail: "已识别 \(scraped.matched.formatted()) 部",
                                        date: scraped.date,
                                        tint: LumaBrand.mint))
        }
        if let scan = latestScan {
            items.append(SnapshotMoment(id: "scan",
                                        symbol: "arrow.triangle.2.circlepath",
                                        title: "最近扫描 · \(scan.mount.name)",
                                        detail: "\(scan.state.mediaCount.formatted()) 项 · \(scan.state.folderCount.formatted()) 目录",
                                        date: scan.state.updatedAt,
                                        tint: LumaBrand.cyan))
        }
        if let recent = cloud.mounts.max(by: { $0.createdAt < $1.createdAt }) {
            items.append(SnapshotMoment(id: "mount",
                                        symbol: "externaldrive.fill.badge.plus",
                                        title: "最近接入 · \(recent.name)",
                                        detail: "\(recent.kind.title) · \(DateText.monthFormatter.string(from: recent.createdAt))",
                                        date: recent.createdAt,
                                        tint: LumaBrand.amber))
        }
        return items.sorted { $0.date > $1.date }
    }

    func momentRow(_ item: SnapshotMoment) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(item.tint.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(item.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(CloudHubFormat.relative(item.date))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    func mountName(for record: CinemaProgressRecord) -> String {
        guard let mountID = record.mountID else { return "本地图库" }
        return cloud.mounts.first { $0.id == mountID }?.name ?? "网络存储"
    }
}

/// 三源构成的一段：图库照片 / 图库视频 / 网络媒体。
struct SnapshotSource: Identifiable {
    let id: String
    let title: String
    let value: Int
    let tint: Color
}

/// 最近动态的一条：符号、标题、说明与时间。
struct SnapshotMoment: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let date: Date
    let tint: Color
}
