import SwiftUI
import LumaContentCore

/// 侧边栏里的一个网络存储行：点名称直接进入该网盘的影院，点右侧箭头单独展开 / 收起它的分类。
///
/// 展开状态放在本视图自己的 `@State` 里：它是 `ForEach` 的子视图，
/// 状态若放在外层容易被复用成旧值（典型表现是点了收起、分类又回来）。
struct CloudMountSidebarRow: View {
    let mount: CloudMount
    /// 哪个网盘的层级树是展开的：同一时间只保留一个，点别的接入会收起上一个。
    @Binding var expandedMountID: UUID?

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings

    @State private var isHovering = false
    @State private var showRename = false
    @State private var renameText = ""

    private var isExpanded: Bool { expandedMountID == mount.id }

    private var item: SidebarItem { .cloudMount(mount.id) }
    private var isMountSelected: Bool { store.sidebarItem == item }
    /// 这个网盘正在刮削时给出 0–1 进度，侧边栏行尾直接看到进度环。
    private var scrapeProgress: Double? {
        guard store.cinemaScrapeRunning,
              store.cinemaScrapeScope == .mount(mount.id),
              store.cinemaScrapeTotal > 0 else { return nil }
        return Double(store.cinemaScrapeDone) / Double(store.cinemaScrapeTotal)
    }
    /// 网盘内的分类 / 相簿 / 分区总览被选中时，高亮让给更具体的那一行：
    /// 否则网盘行、全部项目、所有相簿会同时点亮。
    private var showsMountHighlight: Bool {
        guard isMountSelected else { return false }
        // 与拾光一致：分区总览打开时高亮落在分区标题上，网盘行让位。
        return cloud.overview == nil && cloud.scope == .all && cloud.selectedFolderPath == nil
    }
    /// 打开这个网盘的影院时仍算「当前网盘」：分类树保持展开，但高亮只留给真正选中的那一行。
    private var isCurrent: Bool {
        isMountSelected || store.sidebarItem == .cloudCinema(mount.id)
    }

    /// 网盘行的健康：先看当前模型的实时错误（授权失效 / 连不上），没有再用会话快照。
    private var liveHealth: SourceHealth? {
        if cloud.needsCloudReauth {
            return SourceHealth(state: .authRequired, checkedAt: Date(), message: cloud.error)
        }
        if let error = cloud.error {
            return SourceHealth(state: .offline, checkedAt: Date(), message: error)
        }
        return store.sourceHub.health(for: .cloud(mount.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if isCurrent, isExpanded {
                CloudMountDetailView(mountID: mount.id)
            }
        }
    }

    private var row: some View {
        SourceSidebarRow(
            model: SourceRowModel(
                title: mount.name,
                subtitle: nil,
                badge: nil,
                countText: nil,
                isCurrent: showsMountHighlight,
                isEnabled: true,
                isLoading: cloud.loading && isCurrent,
                progress: scrapeProgress,
                health: liveHealth
            ),
            isExpanded: isCurrent && isExpanded,
            showsToggle: true,
            onOpen: {
                openCinema()
            },
            onToggle: toggle,
            onRetry: { store.refreshCloudDirectory() },
            onReauthorize: { store.presentCloudWizard(flow: mount.kind.wizardFlow) }
        ) { _ in
            cover
        } menu: {
            Button("打开整个网盘") {
                store.sourceHub.activate(.cloud(mount.id))
                store.selectCloudFolder(path: nil)
            }
            Button("重新扫描") {
                store.navigate(to: item)
                store.refreshCloudDirectory()
            }
            Divider()
            Button("上移") { store.moveCloudMount(mount.id, by: -1) }
                .disabled(store.cloudMounts.first?.id == mount.id)
            Button("下移") { store.moveCloudMount(mount.id, by: 1) }
                .disabled(store.cloudMounts.last?.id == mount.id)
            Divider()
            Button("打开影院") {
                store.sourceHub.activate(.mountCinema(mount.id))
            }
            Button("刮削这个网盘的视频") {
                store.startCinemaScrape(for: .mount(mount.id))
            }
            Divider()
            Button("重命名…") {
                renameText = mount.name
                showRename = true
            }
            if mount.kind.supportsAccessScope {
                Button("编辑接入范围…") {
                    store.presentCloudWizard(editing: mount)
                }
            }
            if mount.kind == .webdav || mount.kind == .smb {
                Button("编辑连接…") {
                    store.presentCloudSheet(mount)
                }
            } else {
                let alwaysCookie = mount.kind == .quark || mount.kind == .aliyun
                    || mount.kind == .pan115
                Button(alwaysCookie ? "更新 Cookie…" : "重新授权…") {
                    store.presentCloudWizard(flow: mount.kind.wizardFlow)
                }
            }
            Divider()
            Button("断开连接", role: .destructive) {
                store.confirmRemoveCloudMount(mount.id)
            }
        }
        .alert("重命名网络存储", isPresented: $showRename) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                store.renameCloudMount(mount.id, to: renameText)
            }
        } message: {
            Text("只修改侧边栏里的显示名称，不会影响网盘上的内容。")
        }
    }

    /// 与相簿封面同为 20pt 圆角方块：官方网盘直接用产品图标，其余用品牌渐变 + 系统符号。
    private var cover: some View {
        Group {
            if let brand = mount.kind.brand {
                CloudBrandIcon(brand: brand, size: LumaMetrics.sidebarCoverSize)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                        .fill(LinearGradient(colors: coverColors,
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var coverColors: [Color] {
        switch mount.kind {
        case .baidu:
            return [Color(red: 0.26, green: 0.55, blue: 1.00), Color(red: 0.10, green: 0.34, blue: 0.88)]
        case .aliyun:
            return [Color(red: 0.36, green: 0.68, blue: 1.00), Color(red: 0.14, green: 0.42, blue: 0.92)]
        case .quark:
            return [Color(red: 0.42, green: 0.36, blue: 1.00), Color(red: 0.20, green: 0.22, blue: 0.86)]
        case .pan115:
            return [Color(red: 0.24, green: 0.62, blue: 0.98), Color(red: 0.08, green: 0.36, blue: 0.80)]
        case .webdav:
            return [LumaBrand.cyan.opacity(0.95), LumaBrand.violet.opacity(0.90)]
        case .smb:
            return [Color(red: 0.52, green: 0.48, blue: 0.45), Color(red: 0.30, green: 0.27, blue: 0.25)]
        }
    }

    private var icon: String { mount.kind.symbolName }

    /// 点接入 = 进这个网盘自己的影院：与树里的「影院」入口完全一致，
    /// 同时展开它自己的分类树；展开态只有一个，其他接入会自动收起。
    private func openCinema() {
        setExpanded(true)
        store.sourceHub.activate(.mountCinema(mount.id))
    }

    /// 未打开时先切到这个网盘的影院（并展开分类），已打开时切换展开状态。
    private func toggle() {
        if !isCurrent {
            openCinema()
            return
        }
        withAnimation(settings.motion.layout) {
            setExpanded(!isExpanded)
        }
    }

    /// 展开 / 收起这个接入，并持久化「当前只展开哪一个」。
    private func setExpanded(_ expanded: Bool) {
        expandedMountID = expanded ? mount.id : nil
        SidebarStateStorage.save(SidebarStateStorage.Key.expandedCloudMounts,
                                 expanded ? [mount.id] : [])
    }
}
