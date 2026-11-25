import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumaContentCore

/// 接入面板的两种来源：直接填地址，或从磁盘导入文件。
/// 三个模块（网络资源 / 网络影院 / 网络电视）共用同一套分段样式。
enum SourceEntryMode: String, CaseIterable, Identifiable {
    case address
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .address: return "地址"
        case .file: return "文件"
        }
    }

    var symbol: String {
        switch self {
        case .address: return "link"
        case .file: return "doc.badge.plus"
        }
    }
}

/// 「地址 / 文件」分段胶囊：与各页工具栏的胶囊风格一致。
struct SourceEntryModeTab: View {
    @Binding var mode: SourceEntryMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SourceEntryMode.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { mode = item }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(mode == item ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 25)
                    .background {
                        if mode == item {
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("按\(item.title)接入")
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
        .fixedSize()
    }
}

/// 三类来源共用的「导出」入口：把当前这一类来源写成一个 JSON 分享文件。
/// 导入统一收进「接入」面板，这里只负责导出，避免同一页面出现两套导入入口。
struct SourceExportButton: View {
    @EnvironmentObject private var store: LibraryStore
    let scope: SourceTransferScope
    /// 当前这一类来源的数量：为 0 时禁用。
    let count: Int
    let exportData: () -> Data?

    var body: some View {
        Button {
            exportBundle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                Text("导出")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.primary.opacity(count == 0 ? 0.32 : 0.78))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .fixedSize()
        .help(count == 0
              ? "还没有可导出的\(scope.title)配置"
              : "把 \(count) 个\(scope.title)配置导出成分享文件，方便给其他人接入")
    }

    // MARK: - 面板

    private func exportBundle() {
        store.exportSourceConfig(scope: scope, count: count, data: exportData)
    }
}

extension SourceTransferScope {
    /// 三类来源在任务中心里的来源标识。
    var jobSourceID: SourceID {
        switch self {
        case .catalogResource: return .catalogHub
        case .networkCinema: return .networkCinema
        case .television: return SourceID("tv:hub")
        }
    }
}

extension LibraryStore {
    /// 导出配置：选文件 → 写盘，并登记一条「导出」任务。
    /// 即使只写几百字节，任务记录里也会留下这次导出与耗时。
    func exportSourceConfig(scope: SourceTransferScope,
                            count: Int,
                            data: () -> Data?) {
        guard let payload = data() else {
            showToast("还没有可导出的\(scope.title)配置")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(scope.fileNamePrefix)-\(Self.sourceExportDayStamp).json"
        panel.title = "导出\(scope.title)配置"
        panel.message = "文件里只有\(scope.title)的来源配置，不包含照片、播放记录或本机缓存。"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let jobID = beginSourceJob(SourceJob(sourceID: scope.jobSourceID,
                                             kind: .export,
                                             title: "导出\(scope.title)配置",
                                             isCancellable: false))
        do {
            try payload.write(to: url, options: .atomic)
            finishSourceJob(jobID, message: "已导出 \(count) 个\(scope.title)配置")
            showToast("已导出 \(count) 个\(scope.title)配置：\(url.lastPathComponent)")
        } catch {
            failSourceJob(jobID, message: error.localizedDescription)
            showToast("导出失败：\(error.localizedDescription)")
        }
    }

    private static let sourceExportDayStamp: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }()
}
