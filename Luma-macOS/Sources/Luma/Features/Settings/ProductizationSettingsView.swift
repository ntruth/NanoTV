import SwiftUI
import AppKit

/// 产品化：把「关于」「检查更新」「导出诊断」整合成一张卡片。
/// 顶部是应用身份与更新状态，底部是维护动作；所有状态都在卡内完成反馈。
struct ProductizationSettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.colorScheme) private var scheme

    @State private var checking = false
    @State private var latest: UpdateInfo?
    @State private var status: Status = .idle
    @State private var exportMessage: String?

    private var currentVersion: String { UpdateChecker.currentVersion }

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? currentVersion
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.primary.opacity(0.06))
            if let latest {
                updatePanel(latest)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                Divider().overlay(Color.primary.opacity(0.06))
            }
            footnote
        }
        .background(cardBackground)
        .animation(.easeOut(duration: 0.2), value: latest?.version)
        .animation(.easeOut(duration: 0.18), value: exportMessage)
    }

    // MARK: - 身份与状态

    private var header: some View {
        HStack(spacing: 14) {
            appIcon

            VStack(alignment: .leading, spacing: 3) {
                Text("拾光 Luma")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("版本 \(versionText)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("本地优先的照片管理 · 更新只读取版本信息")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    checkUpdateButton
                    exportButton
                }
                HStack(spacing: 6) {
                    if let exportMessage {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9.5))
                            Text(exportMessage)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                    }
                    statusPill
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background {
            GeometryReader { proxy in
                ZStack {
                    Circle()
                        .fill(LumaBrand.violet.opacity(scheme == .dark ? 0.26 : 0.14))
                        .frame(width: 190)
                        .blur(radius: 64)
                        .offset(x: proxy.size.width * 0.72, y: -46)
                    Circle()
                        .fill(LumaBrand.amber.opacity(scheme == .dark ? 0.18 : 0.10))
                        .frame(width: 150)
                        .blur(radius: 60)
                        .offset(x: -60, y: 54)
                }
            }
            .allowsHitTesting(false)
            .clipped()
        }
    }

    private var appIcon: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13.5, style: .continuous)
                .strokeBorder(LumaBrand.ring, lineWidth: 1.4)
                .padding(-2.5)
        }
        .shadow(color: LumaBrand.violet.opacity(0.35), radius: 10, y: 3)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
                .shadow(color: status.color.opacity(0.6), radius: 3)
            Text(status.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(status.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(status.color.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(status.color.opacity(0.24), lineWidth: 0.5)
        }
        .animation(.easeOut(duration: 0.2), value: status.title)
    }

    // MARK: - 维护动作

    /// 两个动作收进卡片右上角，与状态胶囊同列，给正文留出完整宽度。
    private var checkUpdateButton: some View {
        Button {
            checkForUpdates()
        } label: {
            HStack(spacing: 5) {
                if checking {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(checking ? "检查中…" : "检查更新")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.accentColor.opacity(0.26), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(checking)
        .help("从 GitHub Releases 读取最新版本")
    }

    private var exportButton: some View {
        Button {
            exportDiagnostics()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                Text("导出诊断报告")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("导出到桌面，便于附在问题反馈里")
    }

    private func updatePanel(_ info: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("发现新版本 v\(info.version)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Button {
                    NSWorkspace.shared.open(info.pageURL)
                } label: {
                    HStack(spacing: 3) {
                        Text("前往发布页")
                            .font(.system(size: 10.5, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8.5, weight: .bold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if !info.notes.isEmpty {
                Text(info.notes)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.10),
                                              Color.accentColor.opacity(0.03)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.6)
        }
    }

    private var footnote: some View {
        Text("更新检查只读取 GitHub Releases 的版本信息，不上传图库内容。诊断报告只包含版本、系统、图库路径与最近日志，不包含照片或 API Key。")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }

    // MARK: - 动作

    private func checkForUpdates() {
        guard !checking else { return }
        checking = true
        latest = nil
        status = .checking
        exportMessage = nil
        Task {
            do {
                let info = try await UpdateChecker.fetchLatest()
                await MainActor.run {
                    checking = false
                    guard let info else {
                        status = .failed("没有找到发布信息")
                        return
                    }
                    if UpdateChecker.isNewer(info.version, than: currentVersion) {
                        latest = info
                        status = .available(info.version)
                    } else {
                        status = .upToDate
                    }
                }
            } catch {
                await MainActor.run {
                    checking = false
                    status = .failed("检查失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func exportDiagnostics() {
        let url = Diagnostics.exportReport(libraryPath: store.containerLibraryPath)
        exportMessage = url == nil ? "导出失败，请查看日志" : "已导出到桌面"
    }

    // MARK: - 状态

    private enum Status {
        case idle
        case checking
        case upToDate
        case available(String)
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "未检查"
            case .checking: return "检查中"
            case .upToDate: return "已是最新"
            case .available(let version): return "可更新 v\(version)"
            case .failed(let message): return message
            }
        }

        var color: Color {
            switch self {
            case .idle: return .secondary
            case .checking: return .accentColor
            case .upToDate: return .green
            case .available: return .accentColor
            case .failed: return .orange
            }
        }
    }
}
