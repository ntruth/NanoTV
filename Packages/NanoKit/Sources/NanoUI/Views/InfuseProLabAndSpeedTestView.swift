import NanoCore
import NanoDesignSystem
import NanoPlayerKit
import NanoSync
import NanoVFS
import SwiftUI

/// Infuse Pro 专属高阶功能中心（存储源流式测速波形仪 + Trakt.tv 双向打点授权 + 在线字幕源配置 + 家庭儿童分级家长锁）
public struct InfuseProLabAndSpeedTestView: View {
    @Bindable public var appVM: NanoAppViewModel
    @Bindable private var speedService = StorageSpeedBenchmarkService.shared
    @Bindable private var traktService = TraktSyncService.shared

    @State private var selectedSourceIDForTest: UUID?
    @State private var customBenchmarkURL: String = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"

    // Trakt 扫码绑定状态
    @State private var traktClientIDInput: String = ""
    @State private var traktClientSecretInput: String = ""
    @State private var traktSession: TraktDeviceAuthSession?
    @State private var traktStatusMsg: String = ""
    @State private var traktPollTask: Task<Void, Never>?

    // 在线字幕 Key 配置
    @State private var openSubKey: String = ""
    @State private var assrtToken: String = ""
    @State private var subtitleSavedHint: String = ""

    public init(appVM: NanoAppViewModel) {
        self.appVM = appVM
    }

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: NanoPalette.amberGold) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // 头部徽章
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) {
                                Text("Infuse Pro 专业增强中心")
                                    .font(.system(size: 28, weight: .heavy))
                                    .foregroundStyle(NanoPalette.textPrimary)
                                Text("PRO")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(NanoPalette.amberGold))
                            }
                            Text("连接吞吐测速仪 · Trakt.tv 自动打点同步 · OpenSubtitles/射手在线字幕 · 儿童分级家长控制")
                                .font(.system(size: 13))
                                .foregroundStyle(NanoPalette.textSecondary)
                        }
                        Spacer()
                    }

                    // 1. 存储源真实流式测速仪卡片
                    speedTesterCard

                    // 2. Trakt.tv 双向云同步与 Scrobble 实时打点卡片
                    traktIntegrationCard

                    // 3. 在线字幕引擎 API 与家庭家长分级控制双栏
                    HStack(alignment: .top, spacing: 18) {
                        onlineSubtitlesConfigCard
                        parentalControlCard
                    }
                }
                .padding(26)
            }
        }
        .onAppear {
            selectedSourceIDForTest = appVM.visibleStorageSources.first?.id
            traktClientIDInput = traktService.clientID
        }
        .onDisappear {
            traktPollTask?.cancel()
        }
    }

    // MARK: - 1. Infuse Pro 存储连接测速波形仪

    private var speedTesterCard: some View {
        NanoGlassCard(cornerRadius: 18, padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("存储源连接测速仪（诊断 4K UHD 原盘 REMUX 播放瓶颈）", systemImage: "speedometer")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NanoPalette.amberGold)

                    Spacer()

                    if speedService.report.isRunning {
                        Button("停止测速") {
                            speedService.cancelBenchmark()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            launchSpeedBenchmark()
                        } label: {
                            Label("开始流式测速", systemImage: "bolt.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(NanoPalette.amberGold))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 14) {
                    Picker("目标存储源", selection: $selectedSourceIDForTest) {
                        ForEach(appVM.visibleStorageSources) { src in
                            Text(src.name).tag(Optional(src.id))
                        }
                    }
                    .frame(maxWidth: 260)

                    TextField("测速样本媒体流直链 URL", text: $customBenchmarkURL)
                        .textFieldStyle(.roundedBorder)
                }

                // 4 大核心速率读数面板
                HStack(spacing: 14) {
                    speedStatBox(title: "实时速率", value: String(format: "%.1f Mbps", speedService.report.currentMbps), tint: NanoPalette.electricBlue)
                    speedStatBox(title: "平均速率", value: String(format: "%.1f Mbps", speedService.report.averageMbps), tint: NanoPalette.onlineGreen)
                    speedStatBox(title: "峰值速率", value: String(format: "%.1f Mbps", speedService.report.peakMbps), tint: NanoPalette.amberGold)
                    speedStatBox(title: "最低谷值", value: String(format: "%.1f Mbps", speedService.report.minimumMbps), tint: .cyan)
                }

                // 动态吞吐波形柱状曲线
                if !speedService.report.samplesMbps.isEmpty {
                    let maxSample = max(10.0, speedService.report.samplesMbps.max() ?? 100.0)
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(speedService.report.samplesMbps.suffix(28).enumerated()), id: \.offset) { _, val in
                            let hRatio = max(0.08, min(1.0, val / maxSample))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        colors: [NanoPalette.amberGold, NanoPalette.electricBlue],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(height: CGFloat(78.0 * hRatio))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 82, alignment: .bottomLeading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.28)))
                }

                Text("诊断结论：\(speedService.report.qualityVerdict)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NanoPalette.onlineGreen)
            }
        }
    }

    private func speedStatBox(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(NanoPalette.textMuted)
            Text(value)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }

    // MARK: - 2. Trakt.tv 双向打点与扫码激活卡片

    private var traktIntegrationCard: some View {
        NanoGlassCard(cornerRadius: 18, padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Trakt.tv 观影进度实时打点 (Scrobble) 与已看记录同步", systemImage: "checkmark.circle.badge.checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NanoPalette.electricBlue)
                    Spacer()
                    Toggle("自动打点上报", isOn: $traktService.isScrobbleEnabled)
                        .toggleStyle(.switch)
                }

                if traktService.isAuthorized {
                    HStack {
                        Text("已连接 Trakt 账号：\(traktService.connectedUsername.isEmpty ? "已授权用户" : traktService.connectedUsername)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(NanoPalette.onlineGreen)
                        Spacer()
                        Button("断开连接") {
                            traktService.disconnect()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        if let session = traktSession {
                            VStack(spacing: 8) {
                                NanoQRCodeView(content: "\(session.verificationURL)/\(session.userCode)", size: 120)
                                Text("激活码：\(session.userCode)")
                                    .font(.system(size: 15, weight: .black, design: .monospaced))
                                    .foregroundStyle(NanoPalette.amberGold)
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("填入 Trakt API Application 的 Client ID 与 Secret 后，点击生成电视端设备激活二维码（进度达 80% 自动标记 Watched）：")
                                .font(.system(size: 12))
                                .foregroundStyle(NanoPalette.textSecondary)

                            HStack {
                                TextField("Trakt Client ID", text: $traktClientIDInput)
                                    .textFieldStyle(.roundedBorder)
                                SecureField("Trakt Client Secret", text: $traktClientSecretInput)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack(spacing: 12) {
                                Button("获取扫码激活码") {
                                    startTraktDeviceActivation()
                                }
                                .buttonStyle(.borderedProminent)

                                if !traktStatusMsg.isEmpty {
                                    Text(traktStatusMsg)
                                        .font(.caption)
                                        .foregroundStyle(NanoPalette.amberGold)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 3. 在线字幕源配置 & 家长分级控制锁

    private var onlineSubtitlesConfigCard: some View {
        NanoGlassCard(cornerRadius: 18, padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Label("在线字幕实时搜索源配置", systemImage: "captions.bubble.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(NanoPalette.textPrimary)

                Text("观影中途无需退出，点击播放器右上角「Pro 控制 / 字幕」即可一键搜索下载中英双语字幕并实时挂载。")
                    .font(.system(size: 12))
                    .foregroundStyle(NanoPalette.textSecondary)

                TextField("OpenSubtitles REST API Key（可选）", text: $openSubKey)
                    .textFieldStyle(.roundedBorder)
                TextField("射手网 ASSrt API Token（可选）", text: $assrtToken)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("保存字幕源凭证") {
                        let osKey = openSubKey
                        let asKey = assrtToken
                        Task {
                            await OnlineSubtitleSearchService.shared.configureKeys(openSubtitlesKey: osKey, assrtToken: asKey)
                            await MainActor.run { subtitleSavedHint = "已生效" }
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if !subtitleSavedHint.isEmpty {
                        Text(subtitleSavedHint)
                            .font(.caption)
                            .foregroundStyle(NanoPalette.onlineGreen)
                    }
                }
            }
        }
    }

    private var parentalControlCard: some View {
        NanoGlassCard(cornerRadius: 18, padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Label("家庭儿童分级家长控制 (Parental Lock)", systemImage: "figure.and.child.holdinghands")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(NanoPalette.textPrimary)

                Text("限制客厅 Apple TV 免密可直接播放的最高影片分级，超出等级自动拦截要求输入 PIN 码。")
                    .font(.system(size: 12))
                    .foregroundStyle(NanoPalette.textSecondary)

                Toggle("启用家庭分级家长锁", isOn: $appVM.parentalControlEnabled)

                Picker("允许免密观看上限", selection: $appVM.allowedMaxRatingTier) {
                    ForEach(ContentRatingTier.allCases) { tier in
                        Text(tier.displayBadge).tag(tier)
                    }
                }
                .disabled(!appVM.parentalControlEnabled)
            }
        }
    }

    private func launchSpeedBenchmark() {
        guard let url = URL(string: customBenchmarkURL) else { return }
        let srcName = appVM.visibleStorageSources.first(where: { $0.id == selectedSourceIDForTest })?.name ?? "自定义流直链"
        speedService.startBenchmark(sourceName: srcName, streamURL: url)
    }

    private func startTraktDeviceActivation() {
        traktPollTask?.cancel()
        traktService.saveClientAppCredentials(clientID: traktClientIDInput, clientSecret: traktClientSecretInput)
        traktStatusMsg = "正在请求 Trakt 激活码..."

        traktPollTask = Task {
            do {
                let session = try await traktService.requestDeviceCode()
                await MainActor.run {
                    self.traktSession = session
                    self.traktStatusMsg = "请手机扫码或访问 \(session.verificationURL) 输入激活码"
                }
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(session.intervalSec) * 1_000_000_000)
                    let ok = try await traktService.pollForAccessToken(deviceCode: session.deviceCode)
                    if ok {
                        await MainActor.run {
                            self.traktStatusMsg = "Trakt 账号绑定成功！"
                        }
                        return
                    }
                }
            } catch {
                await MainActor.run {
                    self.traktStatusMsg = "请先填入有效的 Trakt Client ID"
                }
            }
        }
    }
}
