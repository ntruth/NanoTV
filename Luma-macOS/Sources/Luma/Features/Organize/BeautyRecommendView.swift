import SwiftUI
import LumaCore

/// 智能美化推荐面板：按画面偏差分组列出可批量处理的照片，全部在本机用缩略图分析。
struct BeautyRecommendView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    private var report: BeautyReport? { store.beautyReport }
    private var cloud: CloudBrowserModel { store.cloudModel }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // 先回填上次落库的结果，再判断是否需要重新分析。
            store.restoreCachedBeautyReportIfNeeded()
            // 本地、系统图库与网盘的推荐结果互不通用：范围变了就重新分析。
            let stale: Bool
            if store.isCloudScope {
                stale = !cloud.beautyReportIsCloud
            } else if store.isSystemScope {
                stale = !store.beautyReportIsSystem
            } else {
                stale = cloud.beautyReportIsCloud || store.beautyReportIsSystem
            }
            if (store.beautyReport == nil || stale), !store.isScanningBeauty {
                store.scanBeautyCandidates()
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("智能美化")
                    .font(.system(size: 20, weight: .bold))
                Text("按画面偏差分组推荐，全部在本机用缩略图分析，不上传照片")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isScanningBeauty {
                Button("停止") { store.cancelBeautyScan() }
                    .controlSize(.small)
            } else {
                Button {
                    store.scanBeautyCandidates()
                } label: {
                    Label(report == nil ? "开始分析" : "重新分析", systemImage: "wand.and.stars")
                        .font(.system(size: 12, weight: .medium))
                }
                .controlSize(.small)
                .disabled(!store.canScanBeauty || store.isApplyingBeauty)
            }
            Button("关闭") { store.showBeautyPanel = false }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if !store.canScanBeauty {
            message("请先打开一个图库",
                    detail: "智能美化需要当前图库或网盘的照片，建库后再试。")
        } else if store.isScanningBeauty {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: store.beautyScanProgress)
                    .progressViewStyle(.linear)
                Text("正在分析画面亮度与色彩… \(Int(store.beautyScanProgress * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let report, !report.groups.isEmpty {
            ScrollView {
                // 每次渲染只建一次索引，避免每个分组各扫一遍整个图库。
                let lookup = photosByID
                VStack(alignment: .leading, spacing: 16) {
                    summary(report, lookup: lookup)
                    ForEach(report.groups) { group in
                        groupCard(group, lookup: lookup)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if report != nil {
            message("没有明显需要美化的照片",
                    detail: "本次分析的画面亮度、对比与白平衡都比较均衡，可以换个范围或稍后再试。")
        } else {
            message("还没有分析结果",
                    detail: "点「开始分析」，拾光会用缩略图逐张检查曝光、对比度、白平衡与清晰度。")
        }
    }

    private func summary(_ report: BeautyReport, lookup: [UUID: PhotoItem]) -> some View {
        let favorites = report.favoriteCount(in: lookup)
        return HStack(spacing: 10) {
            summaryChip("已分析", "\(report.scannedCount) 张", icon: "photo.stack")
            summaryChip("建议处理", "\(report.distinctCount) 张", icon: "wand.and.stars")
            summaryChip("其中收藏", "\(favorites) 张", icon: "heart")
            Spacer()
            Text("按最新拍摄优先")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func summaryChip(_ title: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func groupCard(_ group: BeautyGroup, lookup: [UUID: PhotoItem]) -> some View {
        let photos = group.candidates.compactMap { lookup[$0.photoID] }
        let favorites = photos.filter(\.isFavorite).count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: group.kind.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                Text(group.kind.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(group.count) 张")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if favorites > 0 {
                    Text("含收藏 \(favorites) 张")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("查看") {
                    store.selectBeautyCandidates(group.candidates.map(\.photoID))
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
                .disabled(store.isApplyingBeauty)
                Button("一键美化") {
                    requestApply(group.candidates.map(\.photoID))
                }
                .controlSize(.small)
                .disabled(store.isApplyingBeauty)
            }

            HStack(spacing: 6) {
                ForEach(photos.prefix(6)) { photo in
                    PhotoThumbnailView(photo: photo, purpose: .cover(84))
                        .frame(width: 62, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Spacer(minLength: 0)
            }

            Text(group.kind.hint)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
        .accessibilityIdentifier("beauty-group-\(group.id)")
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - 底部

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 8) {
            if store.isApplyingBeauty {
                ProgressView(value: store.beautyApplyProgress)
                    .progressViewStyle(.linear)
                Text("正在生成美化副本… \(Int(store.beautyApplyProgress * 100))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text(store.isCloudScope
                     ? "网盘只读：美化结果会保存为拾光本地图库的新照片，网盘原图不变。"
                     : (store.isSystemScope
                        ? "系统图库只读：美化结果会保存为拾光本地图库的新照片，「照片」原图不变。"
                        : "美化会生成渲染副本，原图保留；已有编辑会叠加保留。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let report, !report.groups.isEmpty {
                    Button("全部美化（\(report.distinctCount) 张）") {
                        requestApply(Array(Set(report.groups.flatMap { $0.candidates.map(\.photoID) })))
                    }
                    .controlSize(.small)
                    .disabled(store.isApplyingBeauty)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - 动作

    private var photosByID: [UUID: PhotoItem] {
        let source: [PhotoItem]
        if store.isCloudScope {
            source = store.cloudPhotos
        } else if store.isSystemScope {
            source = store.systemLoadedPhotos
        } else {
            source = store.photos
        }
        return Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
    }

    private func requestApply(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        // 官方「照片」图库作为当前图库时，可以选择写回原图（PhotoKit，可撤销）或另存副本。
        if store.canWriteSystemOriginals {
            switch store.confirmSystemBeautyTarget(count: ids.count) {
            case .original:
                Task { await store.applyBeautyToSystemOriginals(ids) }
            case .copy:
                guard store.confirmBeautyApply(count: ids.count) else { return }
                Task { await store.applyBeauty(to: ids) }
            case .cancel:
                break
            }
            return
        }
        guard store.confirmBeautyApply(count: ids.count) else { return }
        Task {
            await store.applyBeauty(to: ids)
        }
    }
}
