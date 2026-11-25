import AppKit
import SwiftUI

/// 导出设置：格式、质量、尺寸、文件名规则，对齐官方「文件 › 导出」的能力。
struct ExportOptionsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private var count: Int { store.exportTargets.count }

    private var hasVideosOnly: Bool {
        let items = store.exportTargets.compactMap { store.anyPhoto(id: $0) }
        return !items.isEmpty && items.allSatisfy { $0.isVideo }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("导出")
                    .font(.system(size: 15, weight: .semibold))
                Text("共 \(count) 项 · 视频始终以原文件导出")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("格式")
                        .frame(width: 76, alignment: .leading)
                    Picker("", selection: $store.exportOptions.format) {
                        ForEach(ExportImageFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(hasVideosOnly || store.exportOptions.exportOriginal)
                }

                HStack(spacing: 10) {
                    Text("质量")
                        .frame(width: 76, alignment: .leading)
                    Slider(value: $store.exportOptions.quality, in: 0.3...1.0)
                    Text("\(Int(store.exportOptions.quality * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .disabled(!store.exportOptions.format.supportsQuality || store.exportOptions.exportOriginal)

                HStack(spacing: 10) {
                    Text("尺寸")
                        .frame(width: 76, alignment: .leading)
                    Picker("", selection: $store.exportOptions.maxDimension) {
                        ForEach(ExportOptions.maxDimensionChoices, id: \.self) { value in
                            Text(ExportOptions.maxDimensionTitle(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .disabled(store.exportOptions.exportOriginal)
                }

                HStack(spacing: 10) {
                    Text("文件名")
                        .frame(width: 76, alignment: .leading)
                    Picker("", selection: $store.exportOptions.filenameRule) {
                        ForEach(ExportFilenameRule.allCases) { rule in
                            Text(rule.title).tag(rule)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    Text(store.exportOptions.filenameRule.example)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .disabled(store.exportOptions.exportOriginal)

                Toggle("重新编码时写入基础拍摄信息", isOn: $store.exportOptions.includeMetadata)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .disabled(store.exportOptions.exportOriginal)

                Toggle("导出未修改的原片（忽略裁剪、旋转与调色）",
                       isOn: $store.exportOptions.exportOriginal)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }

            Divider()

            HStack {
                Text("导出后可在访达中查看")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("选择文件夹并导出") {
                    chooseFolderAndExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func chooseFolderAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导出"
        panel.message = "选择导出文件夹（共 \(count) 项）"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        store.performExport(to: folder)
    }
}
