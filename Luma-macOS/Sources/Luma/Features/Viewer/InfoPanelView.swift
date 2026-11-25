import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InfoPanelView: View {
    @EnvironmentObject private var viewer: ViewerModel
    let photo: PhotoItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: photo.isVideo ? "video" : "photo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("信息")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    viewer.showInfoPanel = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                PhotoInfoContent(photo: photo)
                    .padding(18)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5)
        }
        .foregroundStyle(.primary)
    }
}

/// 单张照片的完整信息分区。
/// 查看器右侧信息面板与网格浮动信息卡共用这一份实现，避免两套详情各自缺字段。
struct PhotoInfoContent: View {
    @EnvironmentObject private var store: LibraryStore
    let photo: PhotoItem

    private var typeDescription: String {
        let ext = (photo.displayFilename as NSString).pathExtension
        var description = LibraryStore.kindTitle(photo.kind)
        if let type = UTType(filenameExtension: ext), let localized = type.localizedDescription {
            description = localized
        } else if !ext.isEmpty {
            description = ext.uppercased()
        }
        return photo.isRAWFile ? "\(description)（RAW）" : description
    }

    private var locationText: String? {
        guard photo.hasLocation, let latitude = photo.latitude, let longitude = photo.longitude else { return nil }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }

    private var hasCameraInfo: Bool {
        photo.make != nil || photo.model != nil || photo.lens != nil
            || photo.focalLength != nil || photo.aperture != nil
            || photo.shutterSpeed != nil || photo.iso != nil
    }

    private var sourceDescription: String {
        if photo.isSystem { return "系统照片图库（只读）" }
        if photo.isCloud {
            let kind = store.cloudMount(for: photo.cloudMountID)?.kind.title ?? "网络存储"
            return "\(kind)（只读）"
        }
        return "本地图库"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("照片") {
                if let title = photo.title, !title.isEmpty {
                    row("标题", title)
                }
                row("文件名", photo.originalName)
                row("类型", typeDescription)
                if photo.kind != .photo {
                    row("分类", LibraryStore.kindTitle(photo.kind))
                }
                row("尺寸", "\(photo.displayPixelWidth) × \(photo.displayPixelHeight)")
                row("文件大小", formatFileSize(photo.fileSize))
                if photo.isVideo, let duration = photo.duration {
                    row("时长", formatDuration(duration))
                }
                if photo.isLivePhoto {
                    row("实况照片", "是")
                }
                if photo.isBurstItem {
                    row("连拍项目", "是")
                }
                if photo.isSlowMotion {
                    row("慢动作", "是")
                }
                if photo.isScreenRecording {
                    row("屏幕录制", "是")
                }
                if photo.isAnimated || photo.isAnimatedFile {
                    row("动图", "是")
                }
                if photo.isPortraitCapture {
                    row("人像", "是")
                }
                if photo.isDuplicateItem {
                    row("重复项目", "是")
                }
                if photo.isRotated {
                    row("旋转", "\(photo.rotationAngle)°")
                }
            }

            section("拍摄时间") {
                row("日期", DateText.dayFormatter.string(from: photo.capturedAt))
                row("时间", DateText.secondTimeFormatter.string(from: photo.capturedAt))
                if let viewedAt = photo.viewedAt {
                    row("最近查看", DateText.fullFormatter.string(from: viewedAt))
                }
                if let editedAt = photo.editedAt {
                    row("最近编辑", DateText.fullFormatter.string(from: editedAt))
                }
            }

            section("整理") {
                HStack(spacing: 4) {
                    Text("评分")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    ForEach(1...5, id: \.self) { value in
                        Button {
                            store.setRating(photo.starRating == value ? 0 : value, ids: [photo.id])
                        } label: {
                            Image(systemName: value <= photo.starRating ? "star.fill" : "star")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(value <= photo.starRating ? Color.yellow : Color.secondary.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .help("\(value) 星")
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    Text("旗标")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    ForEach(PhotoFlag.allCases) { flag in
                        Button {
                            store.setFlag(photo.pickFlag == flag ? .none : flag, ids: [photo.id])
                        } label: {
                            Image(systemName: flag.icon)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(photo.pickFlag == flag ? flag.color : Color.secondary)
                                .frame(width: 24, height: 22)
                                .background(
                                    photo.pickFlag == flag ? flag.color.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(flag.title)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    Text("色标")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    ForEach(PhotoColorLabel.allCases) { label in
                        Button {
                            store.setColorLabel(photo.labelColor == label ? .none : label, ids: [photo.id])
                        } label: {
                            Circle()
                                .fill(label.color)
                                .frame(width: 13, height: 13)
                                .overlay {
                                    Circle()
                                        .strokeBorder(
                                            photo.labelColor == label ? Color.primary : Color.white.opacity(0.55),
                                            lineWidth: photo.labelColor == label ? 2 : 0.8
                                        )
                                }
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(label.title)
                        .disabled(label == .none)
                        .opacity(label == .none ? 0 : 1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .disabled(!store.canEditMetadataWorkflow)

            if hasCameraInfo {
                section("相机") {
                    if let make = photo.make, let model = photo.model, !model.hasPrefix(make) {
                        row("相机", "\(make) \(model)")
                    } else {
                        row("相机", photo.model ?? photo.make ?? "—")
                    }
                    if let lens = photo.lens { row("镜头", lens) }
                    if let focal = photo.focalLength { row("焦距", focal) }
                    if let aperture = photo.aperture { row("光圈", aperture) }
                    if let shutter = photo.shutterSpeed { row("快门", shutter) }
                    if let iso = photo.iso { row("ISO", iso) }
                }
            }

            if let locationText, photo.hasLocation {
                section("位置") {
                    // 与查看器顶栏、网格地点标签共用同一套层级与回退顺序。
                    let placeTitle = photo.placeTitle
                    if let placeTitle, placeTitle != locationText {
                        row("地点", placeTitle)
                    }
                    if let country = photo.placeCountry {
                        row("国家/地区", country)
                    }
                    if let province = photo.placeProvince, province != placeTitle {
                        row("省份", province)
                    }
                    if let city = photo.placeCity {
                        row("城市", city)
                    }
                    if let district = photo.placeDistrict {
                        row("区/县", district)
                    }
                    if let poi = photo.placePOI {
                        row("街道", poi)
                    }
                    row("坐标", locationText)
                    MiniPhotoMap(photos: [photo])
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                        .help("拖动平移、滚轮缩放地图")
                        .padding(.top, 2)
                }
            }

            let smartScenes = store.sceneTitles(for: photo)
            let smartTags = store.photoTagTitles(for: photo)
            let smartText = store.ocrText(for: photo.id)
            if !smartScenes.isEmpty || !smartTags.isEmpty || smartText != nil
                || (store.analysisIndex[photo.id] == nil && store.canAnalyzeIntelligence && !photo.isVideo) {
                section("智能标签") {
                    if !smartTags.isEmpty {
                        row("画面", smartTags.prefix(10).joined(separator: " · "))
                    }
                    if !smartScenes.isEmpty {
                        row("场景", smartScenes.joined(separator: " · "))
                    }
                    if let landmark = store.landmarkName(for: photo) {
                        row("地标", landmark)
                    }
                    if let smartText {
                        row("文字", String(smartText.prefix(220)))
                    }
                    if store.analysisIndex[photo.id] == nil, !photo.isVideo {
                        Button("分析此照片") {
                            store.analyzeSinglePhoto(photo.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("在本机识别场景与照片中的文字")
                    }
                }
            }

            if !photo.tags.isEmpty {
                section("关键词") {
                    // 用 `/` 分隔的路径按层级缩进展示；父级只作为结构，不重复写成多个标签。
                    ForEach(photo.tags.sorted(), id: \.self) { path in
                        let depth = PhotoItem.keywordDepth(path)
                        let components = PhotoItem.keywordComponents(path)
                        HStack(spacing: 6) {
                            if depth > 0 {
                                Spacer()
                                    .frame(width: CGFloat(depth) * 12)
                            }
                            Image(systemName: depth == 0 ? "folder" : "tag")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(PhotoItem.keywordLeaf(path))
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                            if components.count > 1 {
                                Text(components.dropLast().joined(separator: " / "))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .help(path)
                    }
                }
            }

            let albums = store.albumsContaining(photo.id)
            let systemAlbumNames = photo.isSystem ? store.systemAlbumNamesContaining(photo.id) : []
            if !albums.isEmpty || !systemAlbumNames.isEmpty {
                section("所属相簿") {
                    ForEach(albums) { album in
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(album.name)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                            Spacer()
                        }
                    }
                    ForEach(systemAlbumNames, id: \.self) { name in
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(name)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                            Spacer()
                        }
                    }
                }
            }

            section("其他") {
                row("添加日期", DateText.dayFormatter.string(from: photo.addedAt))
                row("来源", sourceDescription)
                if photo.isCloud {
                    if let mountName = store.cloudMount(for: photo.cloudMountID)?.name {
                        row("网络位置", mountName + " / " + (photo.cloudPath ?? photo.originalName))
                    }
                }
                if photo.isFavorite {
                    row("收藏", "是")
                }
                if photo.isHidden {
                    row("隐藏", "是")
                }
                if let deletedAt = photo.deletedAt {
                    row("最近删除", DateText.fullFormatter.string(from: deletedAt))
                }
                if photo.hasEdits {
                    row("编辑", "已编辑")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
