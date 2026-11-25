import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

struct CompressionSheetView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private var targets: [PhotoItem] {
        store.compressionTargets
            .compactMap { store.photo(id: $0) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    private var estimates: [UUID: CompressionEstimate] { store.compressionEstimates }

    private var supportedCount: Int {
        targets.filter { estimates[$0.id]?.isSupported == true }.count
    }

    private var originalTotal: Int64 {
        targets.reduce(0) { $0 + (estimates[$1.id]?.originalBytes ?? $1.fileSize) }
    }

    private var estimatedTotal: Int64 {
        targets.reduce(0) { partial, photo in
            partial + (estimates[photo.id]?.estimatedBytes ?? photo.fileSize)
        }
    }

    private var estimatedSavings: Int64 { max(0, originalTotal - estimatedTotal) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list
                Divider()
                options
                    .frame(width: 320)
            }
            Divider()
            footer
        }
        .frame(width: 940, height: 640)
        .background(.background)
        .task(id: store.compressionSettings) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            store.refreshCompressionEstimates()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 36, height: 36)
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("原地压缩")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(targets.count) 张照片 · \(store.compressionSettings.mode.title) · 将直接替换图库中的原始文件")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.compressionEstimating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在估算 \(store.compressionEstimates.count)/\(targets.count)…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if supportedCount > 0 {
                Text("预计可节省 \(formatFileSize(estimatedSavings))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(store.isCompressing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(targets) { photo in
                    row(photo)
                    Divider().padding(.leading, 68)
                }
            }
        }
    }

    private func row(_ photo: PhotoItem) -> some View {
        let estimate = estimates[photo.id]
        return HStack(spacing: 12) {
            PhotoThumbnailView(photo: photo, purpose: .cover(42))
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(photo.originalName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let estimate, !estimate.isSupported, let note = estimate.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                } else if let note = estimate?.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(photo.pixelWidth) × \(photo.pixelHeight)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let estimate {
                if estimate.isSupported {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(formatFileSize(estimate.originalBytes) + " → " + formatFileSize(estimate.estimatedBytes))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(estimate.savings > 0
                             ? "节省 \(formatFileSize(estimate.savings))（\(Int((estimate.savingsRatio * 100).rounded()))%）"
                             : "无可节省空间")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(estimate.savings > 0 ? .green : .secondary)
                    }
                } else {
                    Text("跳过")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("估算中…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }

    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("压缩设置")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("压缩方式")
                        .font(.system(size: 12, weight: .medium))
                    Picker("压缩方式", selection: $store.compressionSettings.mode) {
                        ForEach(CompressionSettings.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Text(modeHint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                if store.compressionSettings.mode == .lossy {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("画质")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(Int((store.compressionSettings.quality * 100).rounded()))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $store.compressionSettings.quality, in: 0.3...1.0)
                            .controlSize(.small)
                        Text(qualityHint)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("最大尺寸")
                            .font(.system(size: 12, weight: .medium))
                        Picker("最大尺寸", selection: $store.compressionSettings.maxDimension) {
                            Text("原始尺寸").tag(0)
                            Text("4096 px").tag(4096)
                            Text("2560 px").tag(2560)
                            Text("2048 px").tag(2048)
                            Text("1600 px").tag(1600)
                            Text("1280 px").tag(1280)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Text("缩小长边可显著降低体积。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("输出格式")
                            .font(.system(size: 12, weight: .medium))
                        Picker("输出格式", selection: $store.compressionSettings.format) {
                            ForEach(CompressionSettings.Format.allCases) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        Text(formatHint)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("无损说明")
                            .font(.system(size: 12, weight: .medium))
                        Text("保持像素与尺寸不变：JPEG 只移除 EXIF / XMP / IPTC 等元数据，压缩数据原样保留；PNG / HEIC / TIFF 会重编码为无损 PNG。只有在结果更小时才会替换原文件。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                if store.compressionSettings.mode == .lossy {
                    Toggle(isOn: $store.compressionSettings.preserveMetadata) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("保留元数据")
                                .font(.system(size: 12, weight: .medium))
                            Text("保留 EXIF、拍摄时间与 GPS 信息。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Toggle(isOn: $store.compressionSettings.onlyIfSmaller) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("仅在更小时替换")
                            .font(.system(size: 12, weight: .medium))
                        Text("压缩结果更大时保留原文件。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $store.compressionSettings.keepBackup) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("保留原图备份")
                            .font(.system(size: 12, weight: .medium))
                        Text("备份会占用额外空间，可随时还原。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(18)
            .disabled(store.isCompressing)
        }
    }

    private var modeHint: String {
        switch store.compressionSettings.mode {
        case .lossy:
            return "可调画质与长边，体积最小；画质会有损失。"
        case .lossless:
            return "像素与尺寸完全不变，只做无损优化；体积可能不会减小。"
        }
    }

    private var qualityHint: String {
        switch store.compressionSettings.quality {
        case 0.85...: return "接近原始画质，体积压缩有限。"
        case 0.7..<0.85: return "画质与体积的平衡点，适合日常照片。"
        case 0.5..<0.7: return "明显减小体积，细节会有损失。"
        default: return "最大压缩比，适合分享或预览用途。"
        }
    }

    private var formatHint: String {
        switch store.compressionSettings.format {
        case .original: return "保持 JPEG / PNG / HEIC 等原格式；PNG 需缩放才会明显变小。"
        case .jpeg: return "兼容性最好，透明区域会填充为白色。"
        case .heic: return "同画质下体积最小，macOS 以外设备需确认兼容性。"
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let progress = store.compressionProgress {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    Text("\(progress.completed.formatted()) / \(progress.total.formatted())")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .trailing)
                }
                HStack {
                    Text(progress.currentName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if progress.savedBytes > 0 {
                        Text("已节省 \(formatFileSize(progress.savedBytes))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.green)
                    }
                    Button("取消压缩") {
                        store.cancelCompression()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.leading, 10)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(supportedCount) / \(targets.count) 张可压缩")
                        .font(.system(size: 11, weight: .medium))
                    Text("预计 \(formatFileSize(originalTotal)) → \(formatFileSize(estimatedTotal))，节省 \(formatFileSize(estimatedSavings))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("开始压缩") {
                    store.startCompression()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.compressionEstimating || supportedCount == 0 || store.isCompressing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}
