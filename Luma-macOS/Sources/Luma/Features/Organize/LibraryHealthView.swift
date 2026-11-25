import SwiftUI

/// 图库体检：把「模糊、相似连拍、过大视频、待分析」集中成一张可操作的清单。
struct LibraryHealthView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmDeleteDuplicates = false
    @State private var confirmDeleteSystemDuplicates = false

    private var report: LibraryHealthReport? {
        guard store.healthReportMatchesCurrentScope else { return nil }
        return store.healthReport
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 20) {
                    if store.isScanningHealth {
                        scanProgress
                    }

                    if let report {
                        // 扫描过程中就展示已产出的结果，完成后自动补齐相似连拍。
                        summary(report)
                        if store.isSystemScope {
                            systemCards(report)
                        } else {
                            cards(report)
                        }
                        similarSection(report)
                        if !store.isScanningHealth && !store.isFinalizingHealth {
                            footer(report)
                        }
                    } else if !store.isScanningHealth {
                        emptyState
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { store.restoreCachedHealthReportIfNeeded() }
        .confirmationDialog("把相似备选移入最近删除？",
                            isPresented: $confirmDeleteDuplicates,
                            titleVisibility: .visible) {
            Button("移入最近删除", role: .destructive) {
                store.delete(Set(store.similarDuplicatePhotos.map(\.id)))
                store.scanLibraryHealth()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会保留每组里最清晰的一张，其余 \(store.similarDuplicatePhotos.count) 张移入「最近删除」，可在 30 天内恢复。")
        }
        .confirmationDialog("把相似备选移入「照片」的最近删除？",
                            isPresented: $confirmDeleteSystemDuplicates,
                            titleVisibility: .visible) {
            Button("移入最近删除", role: .destructive) {
                Task { await store.deleteSystemDuplicatesViaPhotoKit() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会保留每组里最清晰的一张，其余 \(store.similarDuplicatePhotos.count) 张移入系统「照片」的最近删除，30 天内可在「照片」中恢复。")
        }
    }

    // MARK: - 头部

    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: store.healthScanProgress)
                .progressViewStyle(.linear)
            Text("正在检查照片清晰度… \(Int(store.healthScanProgress * 100))% · 结果会实时更新")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有体检结果")
                .font(.system(size: 16, weight: .semibold))
            Text("体检会用缩略图评估清晰度，并结合端侧分析结果归并连拍。首次扫描需要逐张读取缩略图，稍等片刻。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("开始体检") { store.scanLibraryHealth() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }

    // MARK: - 总览与卡片

    private func summary(_ report: LibraryHealthReport) -> some View {
        let analyzing = store.isScanningHealth || store.isFinalizingHealth
        return HStack(spacing: 12) {
            metric(title: "可腾出空间",
                   value: analyzing ? "分析中" : formatFileSize(report.reclaimableBytes),
                   icon: "internaldrive")
            metric(title: "可能模糊",
                   value: "\(report.blurry.count) 张",
                   icon: "camera.metering.unknown")
            metric(title: "相似备选",
                   value: analyzing ? "分析中" : "\(report.similarDuplicatePhotos.count) 张",
                   icon: "square.on.square")
            metric(title: "已检查",
                   value: "\(report.scannedCount) 张",
                   icon: "checkmark.seal")
        }
    }

    private func metric(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
    }

    private func cards(_ report: LibraryHealthReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 14)],
                  alignment: .leading, spacing: 14) {
            healthCard(id: "blurry",
                       title: "可能模糊",
                       count: report.blurry.count,
                       subtitle: store.isScanningHealth
                           ? "已发现 \(report.blurry.count) 张，仍在检查…"
                           : (report.blurry.isEmpty ? "没有发现明显模糊的照片" : "清晰度偏低，建议逐张确认"),
                       icon: "camera.metering.unknown",
                       samples: Array(report.blurry.prefix(4).map(\.photo)),
                       action: report.blurry.isEmpty ? nil : { store.navigate(to: .blurry) })

            healthCard(id: "similar",
                       title: "相似连拍",
                       count: report.similarGroups.count,
                       subtitle: (store.isScanningHealth || store.isFinalizingHealth)
                           ? "正在归并相似连拍，完成后自动更新"
                           : (report.similarGroups.isEmpty
                              ? "需要先在「场景」里分析照片内容"
                              : "\(report.similarDuplicatePhotos.count) 张备选，可腾出 \(formatFileSize(report.reclaimableBytes))"),
                       icon: "square.on.square",
                       samples: Array(report.similarDuplicatePhotos.prefix(4)),
                       action: report.similarGroups.isEmpty ? nil : { store.navigate(to: .similarDuplicates) })

            healthCard(id: "videos",
                       title: "过大视频",
                       count: report.largeVideos.count,
                       subtitle: "单个视频超过 \(formatFileSize(LibraryHealthTuning.largeVideoBytes))",
                       icon: "film.stack",
                       samples: Array(report.largeVideos.prefix(4)),
                       action: report.largeVideos.isEmpty ? nil : { store.navigate(to: .largeVideos) })

            healthCard(id: "screenshots",
                       title: "截屏",
                       count: store.photos(for: .screenshots).count,
                       subtitle: "系统截屏，可考虑归档或压缩",
                       icon: "camera.viewfinder",
                       samples: Array(store.photos(for: .screenshots).prefix(4)),
                       action: { store.navigate(to: .screenshots) })

            healthCard(id: "analysis",
                       title: "待分析内容",
                       count: store.pendingAnalysisCount,
                       subtitle: store.pendingAnalysisCount == 0
                           ? "全部照片都已识别场景与文字"
                           : "分析后可按场景浏览、搜索图内文字",
                       icon: "sparkles",
                       samples: [],
                       action: store.pendingAnalysisCount == 0 ? nil : { store.analyzeIntelligence() })
        }
    }

    /// 系统图库只读：只展示检查结果，不提供清理 / 删除入口。
    private func systemCards(_ report: LibraryHealthReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 14)],
                  alignment: .leading, spacing: 14) {
            healthCard(id: "blurry",
                       title: "可能模糊",
                       count: report.blurry.count,
                       subtitle: store.isScanningHealth
                           ? "已发现 \(report.blurry.count) 张，仍在检查…"
                           : (report.blurry.isEmpty ? "没有发现明显模糊的照片" : "清晰度偏低，建议到「照片」中确认"),
                       icon: "camera.metering.unknown",
                       samples: Array(report.blurry.prefix(4).map(\.photo)),
                       action: nil)

            healthCard(id: "similar",
                       title: "相似连拍",
                       count: report.similarGroups.count,
                       subtitle: (store.isScanningHealth || store.isFinalizingHealth)
                           ? "正在归并相似连拍，完成后自动更新"
                           : (report.similarGroups.isEmpty
                              ? "没有发现相似连拍"
                              : (store.canDeleteSystemPhotos
                                 ? "\(report.similarDuplicatePhotos.count) 张备选，可移入「照片」的最近删除"
                                 : "\(report.similarDuplicatePhotos.count) 张备选，可在「照片」中合并")),
                       icon: "square.on.square",
                       samples: Array(report.similarDuplicatePhotos.prefix(4)),
                       action: (store.canDeleteSystemPhotos && !report.similarDuplicatePhotos.isEmpty)
                           ? { confirmDeleteSystemDuplicates = true }
                           : nil)

            healthCard(id: "videos",
                       title: "过大视频",
                       count: report.largeVideos.count,
                       subtitle: "单个视频超过 \(formatFileSize(LibraryHealthTuning.largeVideoBytes))",
                       icon: "film.stack",
                       samples: Array(report.largeVideos.prefix(4)),
                       action: nil)
        }
    }

    private func healthCard(id: String,
                            title: String,
                            count: Int,
                            subtitle: String,
                            icon: String,
                            samples: [PhotoItem],
                            action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.accentColor)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(count > 0 ? .primary : .secondary)
                }

                if !samples.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(samples) { photo in
                            PhotoThumbnailView(photo: photo, purpose: .cover(72))
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        Spacer(minLength: 0)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityIdentifier("health-\(id)")
        .help(action == nil ? subtitle : "查看「\(title)」")
    }

    // MARK: - 相似分组预览

    @ViewBuilder
    private func similarSection(_ report: LibraryHealthReport) -> some View {
        if !report.similarGroups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("相似连拍分组")
                        .font(.system(size: 15, weight: .semibold))
                    Text("每组保留最清晰的一张")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !store.isSystemScope {
                        Button("查看全部备选") { store.navigate(to: .similarDuplicates) }
                            .buttonStyle(.link)
                            .font(.system(size: 11.5))
                    }
                }

                VStack(spacing: 8) {
                    ForEach(report.similarGroups.prefix(6)) { group in
                        similarGroupRow(group)
                    }
                }
            }
        } else if store.isScanningHealth || store.isFinalizingHealth {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在归并相似连拍，完成后会在这里按组列出保留项")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private func similarGroupRow(_ group: LibraryHealthReport.SimilarGroup) -> some View {
        HStack(spacing: 10) {
            PhotoThumbnailView(photo: group.best, purpose: .cover(96))
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1.5)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("保留：\(group.best.displayTitle)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(group.duplicates.count) 张备选 · 相似度 \(Int(group.similarity * 100))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            ForEach(group.duplicates.prefix(4)) { photo in
                PhotoThumbnailView(photo: photo, purpose: .cover(56))
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(0.75)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 底部操作

    private func footer(_ report: LibraryHealthReport) -> some View {
        HStack(spacing: 10) {
            Text("体检于 \(DateText.fullFormatter.string(from: report.scannedAt))")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            if store.isSystemScope {
                Text("系统图库只读：只做检查与预览，清理请到「照片」中操作。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else if !store.similarDuplicatePhotos.isEmpty {
                Button {
                    confirmDeleteDuplicates = true
                } label: {
                    Label("把相似备选移入最近删除…", systemImage: "trash")
                        .font(.system(size: 11.5))
                }
                .controlSize(.small)
                .help("保留每组最佳一张，其余移入最近删除")
            }
        }
    }
}
