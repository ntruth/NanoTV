import Foundation
import AppKit
import LumaContentCore

/// 图库保险库的入口：选择目标目录、后台备份 / 校验 / 恢复，并把状态发布给设置页。
extension LibraryStore {
    private static let lastBackupPathKey = "vault.lastBackupPath"
    private static let lastBackupDateKey = "vault.lastBackupDate"

    /// 保险库只面向拾光自建图库；官方「照片」图库请继续使用照片 App / 时间机器。
    var vaultLibraryRoot: URL? {
        guard let path = containerLibraryPath, !isNativeContainer else { return nil }
        return URL(fileURLWithPath: path)
    }

    var canUseVault: Bool { vaultLibraryRoot != nil }

    func refreshVaultState() {
        guard let store = metadataStore else { return }
        vaultBackupPath = store.setting(Self.lastBackupPathKey)
        if let raw = store.setting(Self.lastBackupDateKey), let value = Double(raw) {
            vaultLastBackupDate = Date(timeIntervalSince1970: value)
        } else {
            vaultLastBackupDate = nil
        }
    }

    func createVaultBackup() {
        guard let root = vaultLibraryRoot else {
            showToast("当前图库不支持保险库；系统「照片」图库请使用系统备份")
            return
        }
        guard let destination = chooseVaultDirectory(prompt: "选择备份位置") else { return }
        // 先把内存里的元数据落盘并合并 WAL，避免备份到一半的数据库。
        metadataStore?.flush()
        metadataStore?.checkpoint()
        vaultReport = nil
        vaultProgress = VaultProgress(phase: .scanning, completed: 0, total: 0, bytes: 0,
                                      message: "准备备份…")
        // 备份 / 校验 / 恢复都在后台跑，且没有中断句柄：登记任务但不显示取消。
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(root.path), kind: .backup, title: "备份图库", isCancellable: false)
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try LibraryVaultService.createBackup(libraryRoot: root, destination: destination) { progress in
                        DispatchQueue.main.async {
                            self.vaultProgress = progress
                            self.updateSourceJob(jobID,
                                                 completed: progress.completed,
                                                 total: progress.total > 0 ? progress.total : nil,
                                                 message: "\(progress.phase.rawValue) · \(progress.message)",
                                                 fraction: progress.total > 0 ? progress.fraction : nil)
                        }
                    }
                }.value
                await MainActor.run {
                    self.vaultBackupPath = url.path
                    self.vaultLastBackupDate = Date()
                    self.metadataStore?.setSetting(Self.lastBackupPathKey, url.path)
                    self.metadataStore?.setSetting(Self.lastBackupDateKey,
                                                   String(Date().timeIntervalSince1970))
                    self.vaultProgress = nil
                    self.finishSourceJob(jobID, message: "已备份到 \(url.lastPathComponent)")
                    self.showToast("图库已备份到 \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    self.vaultProgress = nil
                    self.failSourceJob(jobID, message: error.localizedDescription)
                    self.showToast("备份失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func verifyVault(backupRoot: URL? = nil) {
        guard let root = vaultLibraryRoot else {
            showToast("当前图库不支持保险库")
            return
        }
        guard let backup = backupRoot ?? chooseVaultBackup(prompt: "选择要校验的备份") else { return }
        vaultProgress = VaultProgress(phase: .verifying, completed: 0, total: 0, bytes: 0,
                                      message: "准备校验…")
        vaultReport = nil
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(root.path), kind: .backup, title: "校验保险库", isCancellable: false)
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try LibraryVaultService.verify(libraryRoot: root, backupRoot: backup) { progress in
                        DispatchQueue.main.async {
                            self.vaultProgress = progress
                            self.updateSourceJob(jobID,
                                                 completed: progress.completed,
                                                 total: progress.total > 0 ? progress.total : nil,
                                                 message: "\(progress.phase.rawValue) · \(progress.message)",
                                                 fraction: progress.total > 0 ? progress.fraction : nil)
                        }
                    }
                }.value
                await MainActor.run {
                    self.vaultBackupPath = backup.path
                    self.vaultReport = report
                    self.vaultProgress = nil
                    self.finishSourceJob(jobID,
                                         message: report.isHealthy
                                         ? "校验通过 · \(report.checked) 个文件完整"
                                         : "发现 \(report.issues.count) 个问题")
                    self.showToast(report.isHealthy
                                   ? "校验通过：\(report.checked) 个文件完整"
                                   : "发现 \(report.issues.count) 个问题")
                }
            } catch {
                await MainActor.run {
                    self.vaultProgress = nil
                    self.failSourceJob(jobID, message: error.localizedDescription)
                    self.showToast("校验失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func restoreVault(backupRoot: URL? = nil) {
        guard let root = vaultLibraryRoot, let report = vaultReport else { return }
        guard let backup = backupRoot ?? vaultBackupPath.map({ URL(fileURLWithPath: $0) }) else { return }
        guard !report.isHealthy else {
            showToast("图库文件完整，无需恢复")
            return
        }
        vaultProgress = VaultProgress(phase: .restoring, completed: 0, total: 0, bytes: 0,
                                      message: "准备恢复…")
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(root.path), kind: .backup, title: "恢复保险库", isCancellable: false)
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                let restored = try await Task.detached(priority: .userInitiated) {
                    try LibraryVaultService.restore(libraryRoot: root, backupRoot: backup, report: report) { progress in
                        DispatchQueue.main.async {
                            self.vaultProgress = progress
                            self.updateSourceJob(jobID,
                                                 completed: progress.completed,
                                                 total: progress.total > 0 ? progress.total : nil,
                                                 message: "\(progress.phase.rawValue) · \(progress.message)",
                                                 fraction: progress.total > 0 ? progress.fraction : nil)
                        }
                    }
                }.value
                await MainActor.run {
                    self.vaultProgress = nil
                    self.finishSourceJob(jobID, message: "已恢复 \(restored) 个文件")
                    self.showToast("已恢复 \(restored) 个文件；原文件已移入 vault-quarantine")
                    self.verifyVault(backupRoot: backup)
                }
            } catch {
                await MainActor.run {
                    self.vaultProgress = nil
                    self.failSourceJob(jobID, message: error.localizedDescription)
                    self.showToast("恢复失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func chooseVaultBackup() {
        guard let backup = chooseVaultBackup(prompt: "选择备份目录") else { return }
        verifyVault(backupRoot: backup)
    }

    private func chooseVaultDirectory(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseVaultBackup(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}
