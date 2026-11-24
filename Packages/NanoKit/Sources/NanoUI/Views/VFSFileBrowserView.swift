import NanoCore
import NanoDesignSystem
import NanoMusic
import NanoSync
import NanoVFS
import SwiftUI

/// 面包屑目录层级帧
private struct DirectoryCrumb: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let fileID: String?
}

/// 真实虚拟目录文件树浏览器（直连小雅 OpenList / 115 / 夸克 / 百度 / SMB / WebDAV 目录秒开秒播）
public struct VFSFileBrowserView: View {
    @Bindable public var appVM: NanoAppViewModel
    public let source: StorageSource

    @State private var crumbs: [DirectoryCrumb] = []
    @State private var nodes: [VFSNode] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var searchKeyword: String = ""
    @State private var progressLookup: [String: PlaybackProgressRecord] = [:]
    @State private var scrapingStatusBanner: String?

    public init(appVM: NanoAppViewModel, source: StorageSource) {
        self.appVM = appVM
        self.source = source
    }

    private var currentCrumb: DirectoryCrumb {
        crumbs.last ?? DirectoryCrumb(name: source.name, path: source.rootPath.isEmpty ? "/" : source.rootPath, fileID: nil)
    }

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: NanoPalette.electricBlue) {
            VStack(alignment: .leading, spacing: 16) {
                // 1. 顶部操作与搜索栏
                topToolbarSection
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                // 2. 面包屑路径导航条
                breadcrumbBar
                    .padding(.horizontal, 24)

                if let banner = scrapingStatusBanner {
                    Text(banner)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NanoPalette.amberGold)
                        .padding(.horizontal, 24)
                }

                // 3. 文件/文件夹列表主体
                if isLoading {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView("正在读取 \(source.name) 目录...")
                            .foregroundStyle(NanoPalette.textSecondary)
                        Spacer()
                    }
                    Spacer()
                } else if let err = errorMessage {
                    errorStateView(err)
                } else if nodes.isEmpty {
                    emptyDirectoryView
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(nodes) { node in
                                fileRowView(node)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 30)
                    }
                }
            }
        }
        .task(id: source.id) {
            crumbs = [DirectoryCrumb(name: source.name, path: source.rootPath.isEmpty ? "/" : source.rootPath, fileID: nil)]
            await loadCurrentDirectory()
        }
    }

    private var topToolbarSection: some View {
        HStack(spacing: 12) {
            Button {
                if crumbs.count > 1 {
                    crumbs.removeLast()
                    Task { await loadCurrentDirectory() }
                } else {
                    appVM.selectedSection = .storageHub
                }
            } label: {
                Label(crumbs.count > 1 ? "上级目录" : "返回存储中心", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NanoPalette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)

            Text(source.name)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(NanoPalette.textPrimary)

            Spacer()

            // 目录内 / 小雅全局秒搜框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(NanoPalette.textMuted)
                TextField(source.type == .xiaoyaOpenList ? "小雅全局秒搜影片..." : "筛选文件名...", text: $searchKeyword)
                    .textFieldStyle(.plain)
                    .foregroundStyle(NanoPalette.textPrimary)
                    .frame(width: 190)
                    .onSubmit {
                        Task { await performSearch() }
                    }
                if !searchKeyword.isEmpty {
                    Button {
                        searchKeyword = ""
                        Task { await loadCurrentDirectory() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NanoPalette.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.06)))

            // 一键刮削当前文件夹入库海报墙
            Button {
                let currentNodes = nodes
                scrapingStatusBanner = "正在后台刮削当前目录中的影视文件并生成海报墙..."
                Task {
                    let count = await appVM.scrapeDirectoryNodesIntoCinema(nodes: currentNodes, source: source)
                    await MainActor.run {
                        scrapingStatusBanner = "刮削完成！新增/更新 \(count) 部影视至「影院海报墙」"
                    }
                }
            } label: {
                Label("刮削入库影院", systemImage: "wand.and.stars")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(NanoPalette.amberGold))
            }
            .buttonStyle(.plain)
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { idx, crumb in
                    Button {
                        guard idx < crumbs.count - 1 else { return }
                        crumbs = Array(crumbs.prefix(idx + 1))
                        Task { await loadCurrentDirectory() }
                    } label: {
                        Text(crumb.name)
                            .font(.system(size: 12, weight: idx == crumbs.count - 1 ? .bold : .medium))
                            .foregroundStyle(idx == crumbs.count - 1 ? NanoPalette.electricBlue : NanoPalette.textSecondary)
                    }
                    .buttonStyle(.plain)

                    if idx < crumbs.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(NanoPalette.textMuted)
                    }
                }
            }
        }
    }

    private func fileRowView(_ node: VFSNode) -> some View {
        let pKey = "\(source.id.uuidString)_\(node.path)"
        let progress = progressLookup[pKey]

        return NanoGlassCard(cornerRadius: 12, padding: 12) {
            handleTap(on: node)
        } content: {
            HStack(spacing: 14) {
                Image(systemName: iconForNode(node))
                    .font(.system(size: 20))
                    .foregroundStyle(colorForNode(node))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NanoPalette.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        if node.kind != .folder && node.sizeBytes > 0 {
                            Text(DiskCacheQuotaManager.formatBytes(node.sizeBytes))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(NanoPalette.textMuted)
                        }
                        if let prog = progress, prog.percentage > 0 {
                            Text("上次看到 \(prog.percentage)%")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(NanoPalette.amberGold))
                        }
                    }
                }

                Spacer()

                Image(systemName: node.kind == .folder ? "chevron.right" : "play.circle.fill")
                    .font(.system(size: node.kind == .folder ? 13 : 20))
                    .foregroundStyle(node.kind == .folder ? NanoPalette.textMuted : NanoPalette.electricBlue)
            }
        }
    }

    private var emptyDirectoryView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 42))
                .foregroundStyle(NanoPalette.textMuted)
            Text("当前目录为空，或需要在存储设置中刷新扫码登录凭证")
                .font(.system(size: 14))
                .foregroundStyle(NanoPalette.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorStateView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(NanoPalette.warningAmber)
            Text(msg)
                .font(.system(size: 14))
                .foregroundStyle(NanoPalette.textSecondary)
            Button("重试加载") {
                Task { await loadCurrentDirectory() }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - VFS 交互与同目录外挂字幕自动发现

    private func makeCoordinator() -> DualTrackCloudDriveCoordinator {
        let openToken = iCloudKeychainVault.shared.readSecret(forKey: "\(source.keychainCredentialID)_openapi")
        let secret = iCloudKeychainVault.shared.readSecret(forKey: "\(source.keychainCredentialID)_secret") ?? ""
        let user = iCloudKeychainVault.shared.readSecret(forKey: "\(source.keychainCredentialID)_user") ?? ""
        return VFSDriverRegistry.makeDualTrackCoordinator(
            for: source,
            openAPIToken: openToken,
            cookieHeader: secret,
            basicUsername: user
        )
    }

    @MainActor
    private func loadCurrentDirectory() async {
        isLoading = true
        errorMessage = nil
        let coord = makeCoordinator()
        let target = currentCrumb

        do {
            let fetched = try await coord.listDirectory(at: target.path, parentFileID: target.fileID)
            let records = await NanoDatabaseStore.shared.fetchAll(namespace: "playback_history", as: PlaybackProgressRecord.self)
            var dict: [String: PlaybackProgressRecord] = [:]
            for r in records { dict[r.id] = r }
            self.progressLookup = dict
            self.nodes = fetched
        } catch {
            self.errorMessage = "读取目录失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    @MainActor
    private func performSearch() async {
        let kw = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            await loadCurrentDirectory()
            return
        }
        isLoading = true
        if source.type == .xiaoyaOpenList {
            let token = iCloudKeychainVault.shared.readSecret(forKey: "\(source.keychainCredentialID)_secret")
            let xiaoya = XiaoyaOpenListDriver(source: source, apiToken: token)
            self.nodes = (try? await xiaoya.searchFiles(keyword: kw)) ?? []
        } else {
            self.nodes = nodes.filter { $0.name.localizedCaseInsensitiveContains(kw) }
        }
        isLoading = false
    }

    private func handleTap(on node: VFSNode) {
        switch node.kind {
        case .folder:
            crumbs.append(DirectoryCrumb(name: node.name, path: node.path, fileID: node.fileID))
            Task { await loadCurrentDirectory() }

        case .video, .audio:
            Task {
                let coord = makeCoordinator()
                guard let ticket = try? await coord.resolvePlayableTicket(for: node) else { return }

                // 自动匹配同目录下前缀一致的 .ass / .srt 外挂字幕文件
                let basePrefix = (node.name as NSString).deletingPathExtension.lowercased()
                let matchingSubNodes = nodes.filter {
                    $0.kind == .subtitle && $0.name.lowercased().hasPrefix(basePrefix)
                }
                var subURLs: [URL] = []
                for subNode in matchingSubNodes {
                    if let subTicket = try? await coord.resolvePlayableTicket(for: subNode) {
                        subURLs.append(subTicket.streamURL)
                    }
                }

                let pKey = "\(source.id.uuidString)_\(node.path)"
                await appVM.player.startPlayback(ticket: ticket, persistenceKey: pKey, externalSubtitles: subURLs)
                if node.kind == .video {
                    await MainActor.run { appVM.isPresentingFullPlayer = true }
                }
            }

        default:
            break
        }
    }

    private func iconForNode(_ node: VFSNode) -> String {
        switch node.kind {
        case .folder: return "folder.fill"
        case .video: return "film.fill"
        case .audio: return "waveform"
        case .subtitle: return "captions.bubble.fill"
        case .metadataNFO: return "doc.text.fill"
        case .cueSheet: return "opticaldisc.fill"
        case .other: return "doc.fill"
        }
    }

    private func colorForNode(_ node: VFSNode) -> Color {
        switch node.kind {
        case .folder: return NanoPalette.amberGold
        case .video: return NanoPalette.electricBlue
        case .audio: return Color.purple
        case .subtitle: return NanoPalette.onlineGreen
        default: return NanoPalette.textMuted
        }
    }
}
