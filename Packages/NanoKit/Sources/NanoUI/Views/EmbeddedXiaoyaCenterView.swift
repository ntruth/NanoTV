import NanoCore
import NanoDesignSystem
import NanoSync
import NanoVFS
import SwiftUI

/// 内置小雅 (`xiaoya-alist`) 一键部署控制台 & 局域网现成服务雷达中心
public struct EmbeddedXiaoyaCenterView: View {
    @Bindable public var appVM: NanoAppViewModel
    @Bindable private var manager = EmbeddedXiaoyaManager.shared

    @State private var statusBanner: String = ""
    @State private var isBusy: Bool = false

    public init(appVM: NanoAppViewModel) {
        self.appVM = appVM
    }

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: NanoPalette.amberGold) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 1. 顶部标题与实时运行状态胶囊
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("小雅服务中心（局域网自动发现 + 免 Docker 内置部署）")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(NanoPalette.textPrimary)
                            Text("Apple TV 启动时优先探测并直接复用局域网内现成的小雅服务；无现成服务时可在 macOS 一键部署共享给全屋设备")
                                .font(.system(size: 13))
                                .foregroundStyle(NanoPalette.textSecondary)
                        }
                        Spacer()
                        statusBadgePill
                    }

                    if !statusBanner.isEmpty {
                        Text(statusBanner)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NanoPalette.amberGold)
                    }

                    // 2. 卡片一：局域网现成小雅雷达扫描（Apple TV 首选零配置复用）
                    lanDiscoveryRadarCard

                    // 3. 卡片二：免 Docker 一键配置凭证向导（自动生成 mytoken.txt / myopentoken.txt / 转存目录 ID）
                    credentialsConfigCard

                    // 4. 卡片三：守护进程启停、离线索引包更新与实时终端日志窗
                    daemonControlAndConsoleCard
                }
                .padding(26)
            }
        }
    }

    private var statusBadgePill: some View {
        let isRunningOrReused = (manager.state == .runningLocal || manager.state == .reusingLAN)
        return HStack(spacing: 7) {
            Circle()
                .fill(isRunningOrReused ? NanoPalette.onlineGreen : NanoPalette.warningAmber)
                .frame(width: 8, height: 8)
            Text(manager.state.rawValue)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isRunningOrReused ? NanoPalette.onlineGreen : NanoPalette.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.07))
                .overlay(Capsule().strokeBorder(NanoPalette.subtleBorder, lineWidth: 1))
        )
    }

    // MARK: - 局域网现成小雅雷达发现面板

    private var lanDiscoveryRadarCard: some View {
        NanoGlassCard(cornerRadius: 16, padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("局域网现成小雅服务雷达（支持 NAS Docker 5678 与 Mac 内置共享）", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NanoPalette.electricBlue)

                    Spacer()

                    Button {
                        Task {
                            await appVM.scanAndMountExistingLANXiaoya()
                        }
                    } label: {
                        Label(manager.isScanningLAN ? "正在扫描子网..." : "重新扫描局域网", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(NanoPalette.electricBlue))
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.isScanningLAN)
                }

                if manager.discoveredLANInstances.isEmpty {
                    Text(manager.isScanningLAN ? "正在并发探测当前局域网 5678 / 5244 端口..." : "当前局域网尚未检测到运行中的小雅服务；若家里没有 NAS，可在下方一键启动内置小雅。")
                        .font(.system(size: 13))
                        .foregroundStyle(NanoPalette.textMuted)
                } else {
                    ForEach(manager.discoveredLANInstances) { inst in
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(NanoPalette.onlineGreen)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(inst.name) (\(inst.version))")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(NanoPalette.textPrimary)
                                Text("\(inst.endpointURL)  ·  发现方式：\(inst.discoveryMethod)  ·  延迟 \(inst.latencyMs) ms")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(NanoPalette.textSecondary)
                            }
                            Spacer()
                            Button("直接复用并浏览") {
                                let mounted = appVM.mountOrUpdateXiaoyaSource(name: inst.name, endpointURL: inst.endpointURL, latencyMs: inst.latencyMs)
                                appVM.selectedSection = .storageDetail(mounted.id)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                    }
                }
            }
        }
    }

    // MARK: - 免手动建 txt 凭证配置向导

    private var credentialsConfigCard: some View {
        NanoGlassCard(cornerRadius: 16, padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("内置小雅免 Docker 参数配置（自动写入 data/*.txt）", systemImage: "key.radiowaves.forward.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NanoPalette.amberGold)

                    Spacer()

                    Button {
                        syncCookiesFromMountedDrives()
                    } label: {
                        Label("一键同步已登录的夸克 / 115 凭证", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(NanoPalette.amberGold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(NanoPalette.amberGold.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("阿里云盘 RefreshToken")
                            .font(.system(size: 12))
                            .foregroundStyle(NanoPalette.textSecondary)
                        TextField("对应 mytoken.txt（32位 RefreshToken）", text: $manager.config.aliyunRefreshToken)
                            .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        Text("阿里云盘 OpenToken")
                            .font(.system(size: 12))
                            .foregroundStyle(NanoPalette.textSecondary)
                        TextField("对应 myopentoken.txt（用于 302 原画直链与创建转存目录）", text: $manager.config.aliyunOpenToken)
                            .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        Text("转存缓存目录 ID")
                            .font(.system(size: 12))
                            .foregroundStyle(NanoPalette.textSecondary)
                        HStack {
                            TextField("对应 temp_transfer_folder_id.txt", text: $manager.config.tempTransferFolderID)
                                .textFieldStyle(.roundedBorder)
                            Button("自动在云盘创建转存目录") {
                                Task {
                                    do {
                                        let fid = try await manager.autoCreateAliyunTempTransferFolder()
                                        statusBanner = "自动创建成功！文件夹 ID：\(fid)"
                                    } catch {
                                        statusBanner = "自动创建失败：\(error.localizedDescription)"
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    GridRow {
                        Text("夸克网盘 Cookie")
                            .font(.system(size: 12))
                            .foregroundStyle(NanoPalette.textSecondary)
                        TextField("可选：对应 quark_cookie.txt（点右上角可从已登录夸克一键同步）", text: $manager.config.quarkCookie)
                            .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        Text("数据包镜像源")
                            .font(.system(size: 12))
                            .foregroundStyle(NanoPalette.textSecondary)
                        TextField("update.zip 镜像站地址", text: $manager.config.dataMirrorBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    // MARK: - 守护控制与控制台实时日志

    private var daemonControlAndConsoleCard: some View {
        NanoGlassCard(cornerRadius: 16, padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本地守护引擎控制  ·  端口 \(manager.config.listenPort)  ·  索引库版本：\(manager.localDataVersion)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(NanoPalette.textPrimary)
                        if !manager.activeEndpointURL.isEmpty {
                            Text("当前生效地址：\(manager.activeEndpointURL)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(NanoPalette.onlineGreen)
                        }
                    }

                    Spacer()

                    Button {
                        isBusy = true
                        Task {
                            do {
                                try await manager.syncXiaoyaOfflineIndexBundle()
                                statusBanner = "离线索引数据包 update.zip 同步完成！"
                            } catch {
                                statusBanner = error.localizedDescription
                            }
                            isBusy = false
                        }
                    } label: {
                        Label("下载/更新小雅数据包", systemImage: "arrow.down.doc.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(NanoPalette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)

                    if manager.state == .runningLocal {
                        Button {
                            manager.stopEmbeddedService()
                        } label: {
                            Label("停止内置服务", systemImage: "stop.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(NanoPalette.liveRed))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            isBusy = true
                            Task {
                                do {
                                    try await manager.startEmbeddedService()
                                    if !manager.activeEndpointURL.isEmpty {
                                        _ = appVM.mountOrUpdateXiaoyaSource(
                                            name: "本机内置小雅 · OpenList",
                                            endpointURL: manager.activeEndpointURL,
                                            latencyMs: 1
                                        )
                                    }
                                } catch {
                                    statusBanner = "启动失败：\(error.localizedDescription)"
                                }
                                isBusy = false
                            }
                        } label: {
                            Label("一键启动内置小雅", systemImage: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(NanoPalette.amberGold))
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                    }
                }

                // 终端黑底日志窗
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if manager.consoleLogs.isEmpty {
                            Text("[就绪] 等待扫描局域网或启动内置小雅守护服务...")
                                .foregroundStyle(NanoPalette.textMuted)
                        } else {
                            ForEach(Array(manager.consoleLogs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .foregroundStyle(NanoPalette.onlineGreen.opacity(0.9))
                            }
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(height: 150)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.48))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NanoPalette.subtleBorder, lineWidth: 1))
                )
            }
        }
    }

    private func syncCookiesFromMountedDrives() {
        var syncedNames: [String] = []
        if let quarkSrc = appVM.storageSources.first(where: { $0.type == .quark }),
           let cookie = iCloudKeychainVault.shared.readSecret(forKey: "\(quarkSrc.keychainCredentialID)_secret"),
           !cookie.isEmpty {
            manager.config.quarkCookie = cookie
            syncedNames.append("夸克网盘")
        }
        if let src115 = appVM.storageSources.first(where: { $0.type == .drive115 }),
           let cookie = iCloudKeychainVault.shared.readSecret(forKey: "\(src115.keychainCredentialID)_secret"),
           !cookie.isEmpty {
            manager.config.cookie115 = cookie
            syncedNames.append("115网盘")
        }
        try? manager.persistConfigAndWriteXiaoyaFiles()
        statusBanner = syncedNames.isEmpty
            ? "未检测到已扫码的夸克或 115 Cookie，请先在「网络存储」扫码登录"
            : "已成功同步 [\(syncedNames.joined(separator: "、"))] 凭证至内置小雅配置！"
    }
}
