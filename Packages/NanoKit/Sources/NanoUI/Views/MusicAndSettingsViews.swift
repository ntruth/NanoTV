import NanoCore
import NanoDesignSystem
import NanoMusic
import NanoSync
import SwiftUI

// MARK: - 1. 高解析度无损音乐中心（支持 CUE 分轨列表 + Apple TV 沉浸流体歌词大屏）

public struct MusicCenterView: View {
    @Bindable public var appVM: NanoAppViewModel
    @State private var selectedTrack: MusicTrack?

    public init(appVM: NanoAppViewModel) {
        self.appVM = appVM
    }

    private var activeTrack: MusicTrack {
        selectedTrack ?? appVM.musicTracks.first ?? MusicTrack(sourceID: UUID(), vfsPath: "", title: "暂无曲目", artist: "-", album: "-")
    }

    private var parsedLyrics: [LyricTimedLine] {
        HiFiMusicEngine.parseLRCLyrics(activeTrack.lrcContent ?? "")
    }

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: Color.purple) {
            HStack(spacing: 26) {
                // 左侧曲库列表
                VStack(alignment: .leading, spacing: 16) {
                    Text("Hi-Fi 无损音乐中心")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(NanoPalette.textPrimary)
                    Text("直连 NAS / 115 / 夸克 / 百度网盘音频目录，原生支持 FLAC / DSD / 整轨 CUE 分轨")
                        .font(.system(size: 12))
                        .foregroundStyle(NanoPalette.textSecondary)

                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(appVM.musicTracks) { track in
                                NanoGlassCard(cornerRadius: 12, padding: 14, isHighlighted: activeTrack.id == track.id) {
                                    selectedTrack = track
                                    let demoAudioURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")!
                                    let ticket = PlayableStreamTicket(
                                        title: track.title,
                                        subtitle: "\(track.artist) · \(track.album)",
                                        streamURL: demoAudioURL,
                                        startPositionSec: track.startOffsetSec
                                    )
                                    Task { await appVM.player.startPlayback(ticket: ticket) }
                                } content: {
                                    HStack {
                                        Image(systemName: "waveform.circle.fill")
                                            .font(.system(size: 26))
                                            .foregroundStyle(NanoPalette.amberGold)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(track.title)
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundStyle(NanoPalette.textPrimary)
                                            Text("\(track.artist) · 《\(track.album)》")
                                                .font(.system(size: 12))
                                                .foregroundStyle(NanoPalette.textSecondary)
                                        }
                                        Spacer()
                                        Text(track.formatTag)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(NanoPalette.amberGold)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(NanoPalette.amberGold.opacity(0.15)))
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 440)

                // 右侧：Apple Music TV 风格流体专辑背景 + 时间轴滚动大字歌词
                NanoGlassCard(cornerRadius: 22, padding: 28) {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 18) {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(
                                    LinearGradient(
                                        colors: [.purple.opacity(0.75), NanoPalette.electricBlue.opacity(0.65)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 96, height: 96)
                                .overlay(Image(systemName: "music.quarternote.3").font(.system(size: 36)).foregroundStyle(.white))

                            VStack(alignment: .leading, spacing: 6) {
                                Text(activeTrack.title)
                                    .font(.system(size: 24, weight: .heavy))
                                    .foregroundStyle(.white)
                                Text("\(activeTrack.artist) — \(activeTrack.album)")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(NanoPalette.textSecondary)
                                Text(activeTrack.formatTag)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(NanoPalette.onlineGreen)
                            }
                            Spacer()
                        }

                        Divider().overlay(NanoPalette.subtleBorder)

                        ScrollView {
                            let activeIdx = HiFiMusicEngine.activeLyricIndex(in: parsedLyrics, at: appVM.player.currentTimeSec)
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(Array(parsedLyrics.enumerated()), id: \.element.id) { idx, line in
                                    let isCurrent = (idx == activeIdx)
                                    Text(line.content)
                                        .font(.system(size: isCurrent ? 26 : 18, weight: isCurrent ? .heavy : .semibold))
                                        .foregroundStyle(isCurrent ? .white : NanoPalette.textMuted)
                                        .animation(.easeInOut(duration: 0.25), value: activeIdx)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(26)
        }
    }
}

// MARK: - 2. 多端同步、Apple TV 局域网快传助手与隐私保险箱设置页

public struct SyncAndPrivacySettingsView: View {
    @Bindable public var appVM: NanoAppViewModel

    @State private var webdavURL: String = "https://dav.jianguoyun.com/dav/NanoBackup"
    @State private var webdavUser: String = ""
    @State private var webdavPassword: String = ""
    @State private var pinInput: String = ""
    @State private var feedbackMessage: String = ""

    public init(appVM: NanoAppViewModel) {
        self.appVM = appVM
    }

    public var body: some View {
        NanoDeepSpaceBackground(accentGlowColor: NanoPalette.electricBlue) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("同步、快传与隐私中心")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(NanoPalette.textPrimary)

                    // 1. Apple TV 局域网扫码免输快传卡片
                    NanoGlassCard(cornerRadius: 16, padding: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("局域网网页快传助手（Apple TV 免遥控器输入神器）", systemImage: "qrcode.viewfinder")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(NanoPalette.amberGold)
                                Spacer()
                                Button {
                                    appVM.startLanQuickDropHelper()
                                } label: {
                                    Text(appVM.lanHelperURL.isEmpty ? "启动局域网快传服务" : "运行中")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(NanoPalette.amberGold))
                                }
                                .buttonStyle(.plain)
                            }

                            Text("在同一局域网下使用手机或 Mac 浏览器访问下方地址，即可直接粘贴 M3U 链接、小雅地址、FongMi JSON 订阅或 115/夸克/百度 Cookie 秒推入库。")
                                .font(.system(size: 13))
                                .foregroundStyle(NanoPalette.textSecondary)

                            if !appVM.lanHelperURL.isEmpty {
                                Text("局域网管理入口：\(appVM.lanHelperURL)")
                                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                                    .foregroundStyle(NanoPalette.onlineGreen)
                            }
                        }
                    }

                    // 2. iCloud Keychain + WebDAV 全量配置快照同步
                    NanoGlassCard(cornerRadius: 16, padding: 20) {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("iCloud 钥匙串 + WebDAV 跨设备同步", systemImage: "icloud.and.arrow.up.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(NanoPalette.electricBlue)

                            Text("• 网盘 Cookie / OpenAPI Token 已默认通过 iCloud Keychain 在同 Apple ID 的 Mac 与 Apple TV 间自动加密共享。")
                                .font(.system(size: 13))
                                .foregroundStyle(NanoPalette.textSecondary)

                            TextField("WebDAV 备份目录地址", text: $webdavURL)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                TextField("WebDAV 账号", text: $webdavUser)
                                    .textFieldStyle(.roundedBorder)
                                SecureField("WebDAV 应用密码", text: $webdavPassword)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack(spacing: 12) {
                                Button("上传配置快照至 WebDAV") {
                                    let svc = WebDAVBackupSyncService(endpointURL: webdavURL, username: webdavUser, password: webdavPassword)
                                    Task {
                                        do {
                                            try await svc.uploadSnapshotToWebDAV()
                                            await MainActor.run { feedbackMessage = "WebDAV 备份上传成功" }
                                        } catch {
                                            await MainActor.run { feedbackMessage = "WebDAV 上传失败：\(error.localizedDescription)" }
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)

                                Button("从 WebDAV 恢复到本地") {
                                    let svc = WebDAVBackupSyncService(endpointURL: webdavURL, username: webdavUser, password: webdavPassword)
                                    Task {
                                        do {
                                            try await svc.downloadAndRestoreFromWebDAV()
                                            await MainActor.run { feedbackMessage = "WebDAV 快照恢复成功" }
                                        } catch {
                                            await MainActor.run { feedbackMessage = "WebDAV 恢复失败：\(error.localizedDescription)" }
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)

                                if !feedbackMessage.isEmpty {
                                    Text(feedbackMessage)
                                        .font(.system(size: 12))
                                        .foregroundStyle(NanoPalette.amberGold)
                                }
                            }
                        }
                    }

                    // 3. 隐私保险箱锁（Touch ID / PIN 解锁隐藏分区）
                    NanoGlassCard(cornerRadius: 16, padding: 20) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label("隐私资源保险箱（客厅防社死隐身模式）", systemImage: appVM.privacyGuard.isUnlocked ? "lock.open.fill" : "lock.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(appVM.privacyGuard.isUnlocked ? NanoPalette.onlineGreen : NanoPalette.liveRed)
                                Spacer()
                                Text(appVM.privacyGuard.isUnlocked ? "当前状态：已解锁显示私密源" : "当前状态：已隐藏所有私密源")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(NanoPalette.textSecondary)
                            }

                            HStack(spacing: 12) {
                                SecureField("输入 PIN 码（默认 8888）", text: $pinInput)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 220)

                                Button("PIN 码解锁") {
                                    if appVM.privacyGuard.verifyPIN(pinInput) {
                                        pinInput = ""
                                    }
                                }
                                .buttonStyle(.borderedProminent)

                                #if os(macOS)
                                Button("Touch ID 解锁") {
                                    Task { _ = await appVM.privacyGuard.unlockWithBiometricsIfAvailable() }
                                }
                                .buttonStyle(.bordered)
                                #endif

                                if appVM.privacyGuard.isUnlocked {
                                    Button("立即上锁隐身") {
                                        appVM.privacyGuard.lockImmediately()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                .padding(26)
            }
        }
    }
}
