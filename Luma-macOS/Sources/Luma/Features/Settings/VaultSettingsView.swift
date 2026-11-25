import SwiftUI

/// 设置 › 图库 › 图库保险库：备份、校验、恢复。
/// 与设置页其他分组共用同一套行式卡片：30pt 图标底 + 标题 / 说明 + 右侧动作。
struct VaultSettingsView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            if !store.canUseVault {
                noticeRow
            } else {
                backupRow
                divider
                verifyRow
                if let progress = store.vaultProgress {
                    divider
                    progressSection(progress)
                }
                if let report = store.vaultReport {
                    divider
                    reportSection(report)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .onAppear { store.refreshVaultState() }
    }

    // MARK: - 行

    private var noticeRow: some View {
        row(icon: "info.circle",
            tint: .secondary,
            title: "系统「照片」图库无需保险库",
            subtitle: "请继续使用「照片」App 的 iCloud / 时间机器备份；保险库面向拾光自建图库。") {
            EmptyView()
        }
    }

    private var backupRow: some View {
        row(icon: "shippingbox",
            tint: .accentColor,
            title: "备份到外置盘 / NAS",
            subtitle: backupSubtitle) {
            HStack(spacing: 8) {
                Button("创建备份…") { store.createVaultBackup() }
                    .buttonStyle(.borderedProminent)
                Button("选择备份…") { store.chooseVaultBackup() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .disabled(store.vaultProgress != nil)
        }
    }

    private var verifyRow: some View {
        row(icon: "checkmark.shield",
            tint: .accentColor,
            title: "完整性校验",
            subtitle: verifySubtitle) {
            Button("重新校验") {
                if let path = store.vaultBackupPath {
                    store.verifyVault(backupRoot: URL(fileURLWithPath: path))
                } else {
                    store.chooseVaultBackup()
                }
            }
            .controlSize(.small)
            .disabled(store.vaultProgress != nil)
        }
    }

    private func progressSection(_ progress: VaultProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress.fraction)
            HStack(spacing: 6) {
                Text(progress.phase.rawValue)
                    .font(.system(size: 10.5, weight: .medium))
                Text(progress.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(progress.completed) / \(progress.total)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func reportSection(_ report: VaultReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: report.isHealthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(report.isHealthy ? .green : .orange)
                Text(report.isHealthy
                     ? "校验通过：\(report.checked) 个文件完整"
                     : "\(report.missingCount) 缺失 · \(report.modifiedCount) 损坏 · \(report.extraCount) 多余")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 8)
                if !report.isHealthy {
                    Button("恢复缺失 / 损坏文件") { store.restoreVault() }
                        .controlSize(.small)
                }
            }

            if !report.isHealthy {
                ForEach(report.issues.prefix(6)) { issue in
                    HStack(spacing: 6) {
                        Text(issue.kind.title)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Text(issue.path)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(issue.detail)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if report.issues.count > 6 {
                    Text("还有 \(report.issues.count - 6) 项…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 组件

    private func row<Trailing: View>(icon: String,
                                     tint: Color,
                                     title: String,
                                     subtitle: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var divider: some View {
        Divider().padding(.leading, 56)
    }

    private var backupSubtitle: String {
        guard let path = store.vaultBackupPath else {
            return "还没有备份。备份包含 originals、数据库与渲染结果。"
        }
        let date = store.vaultLastBackupDate.map { DateText.fullFormatter.string(from: $0) }
        return [path, date].compactMap { $0 }.joined(separator: " · ")
    }

    private var verifySubtitle: String {
        if store.vaultBackupPath == nil {
            return "选择一份备份后会读取只读清单，比对文件是否缺失或损坏。"
        }
        return store.vaultReport == nil ? "尚未校验这份备份。" : "已校验，只读比对，不会修改备份内容。"
    }
}
