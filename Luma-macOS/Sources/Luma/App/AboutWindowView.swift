import SwiftUI
import AppKit

/// 菜单栏「关于拾光」：复用关于页的光之河动效，再补上版本与链接。
/// 用独立小窗口替代系统默认 About 面板，让品牌叙事在菜单入口也成立。
struct AboutWindowView: View {
    @EnvironmentObject private var settings: AppSettings

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "版本 \(short) (\(build))"
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 拾光 Luma"
    }

    var body: some View {
        VStack(spacing: 0) {
            AboutBrandHeroView()
                .padding(.horizontal, 18)
                .padding(.top, 34)

            VStack(spacing: 9) {
                HStack(spacing: 10) {
                    appIcon

                    VStack(alignment: .leading, spacing: 2) {
                        Text("拾光 Luma")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text(versionText)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button {
                        openRepository()
                    } label: {
                        HStack(spacing: 4) {
                            Text("GitHub")
                                .font(.system(size: 10.5, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.5)
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("打开发布页")
                }

                Text("本地优先的照片管理，把散落的时光收好。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)

                Text(copyright)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .frame(width: 520)
        .background(LumaAmbientBackground(intensity: 0.6))
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
    }

    private var appIcon: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                .strokeBorder(LumaBrand.ring, lineWidth: 1.2)
                .padding(-2)
        }
    }

    private func openRepository() {
        guard let url = URL(string: "https://github.com/\(UpdateChecker.repository)") else { return }
        NSWorkspace.shared.open(url)
    }
}
