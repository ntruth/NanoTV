import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    private var trashRetentionMessage: String {
        settings.trashRetentionDays > 0
            ? "删除的照片会在这里保留 \(settings.trashRetentionDays) 天。"
            : "删除的照片会一直保留，直到你手动清空最近删除。"
    }

    private var content: (icon: String, title: String, message: String) {
        if store.photoFilter != .all || store.keywordFilter != nil {
            return ("line.3.horizontal.decrease.circle", "没有匹配的照片", "当前筛选条件下没有照片，试试清除筛选。")
        }
        if !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return ("magnifyingglass", "没有找到结果",
                    "试试「去年 海边」「2024年5月」「小猫」「有文字的截图」，或输入人物名字。")
        }
        switch store.sidebarItem {
        case .library:
            return ("photo.on.rectangle.angled", "图库中没有照片", "将照片拖到这里，或点按「导入照片」。")
        case .collections:
            return ("square.stack.3d.up", "还没有精选集", "导入照片后，这里会自动汇总收藏、视频、截屏等精选内容。")
        case .trash:
            return ("trash", "最近删除为空", trashRetentionMessage)
        case .favorites:
            return ("heart", "没有个人收藏", "点按照片上的心形按钮即可收藏。")
        case .hidden:
            return ("eye.slash", "没有隐藏的照片", "")
        case .map:
            return ("map", "没有位置信息", "带有 GPS 信息的照片会显示在地图上。")
        case .people:
            return ("person.crop.square", "人物", "设备端人物识别暂未启用，你的照片不会被上传。")
        case .allAlbums:
            return ("rectangle.stack", "还没有相簿", "点按侧边栏中的「+」新建相簿或文件夹。")
        case .recentlySaved:
            return ("square.and.arrow.down", "最近没有保存的照片", "最近 7 天导入的照片会显示在这里。")
        case .album:
            return ("rectangle.stack", "相簿是空的", "选择照片后，使用「添加到相簿」整理它们。")
        case .folder:
            return ("folder", "文件夹是空的", "这个文件夹及其子文件夹中还没有照片。")
        case .videos:
            return ("video", "没有视频", "")
        case .selfies:
            return ("person.crop.square", "没有自拍", "")
        case .panoramas:
            return ("pano", "没有全景照片", "")
        case .screenshots:
            return ("camera.viewfinder", "没有截屏", "")
        case .systemLibrary:
            return ("photo.stack", "系统图库中没有照片", "连接一个 .photoslibrary 后，会以只读方式显示其中的照片与相簿。")
        case .systemAlbum:
            return ("rectangle.stack", "系统相簿是空的", "该相簿在系统照片图库中没有照片。")
        case .systemFolder:
            return ("folder", "系统文件夹是空的", "该文件夹中的相簿没有照片。")
        case .systemFavorites:
            return ("heart", "系统图库没有个人收藏", "在「照片」中标记为个人收藏的照片会显示在这里。")
        case .systemVideos:
            return ("video", "系统图库没有视频", "")
        case .systemScreenshots:
            return ("camera.viewfinder", "系统图库没有截屏", "")
        case .systemHidden:
            return ("eye.slash", "没有隐藏的照片", "")
        case .systemTrash:
            return ("trash", "最近删除为空", "系统图库中删除的照片会显示在这里。")
        case .systemCollections:
            return ("square.stack.3d.up", "还没有精选集", "连接系统图库后，这里会汇总它自己的收藏、视频、截屏等精选内容。")
        case .systemPortraits:
            return ("person.crop.rectangle", "没有人像照片", "带景深信息的人像照片会显示在这里。")
        case .systemDuplicates:
            return ("square.on.square", "没有重复项目", "")
        case .systemRecentlySaved:
            return ("square.and.arrow.down", "最近没有保存的项目", "最近 30 天保存到图库的项目会显示在这里。")
        case .systemImports:
            return ("square.and.arrow.down.on.square", "没有导入项目", "从相机或存储卡导入的项目会显示在这里。")
        case .systemRevisit:
            return ("clock.arrow.circlepath", "没有值得重看的照片", "拍摄超过两年、且最近一年没有查看过的照片会出现在这里。")
        case .systemScenes, .systemScene:
            return ("sparkles", "还没有识别照片内容", "在侧边栏「场景」里点「识别照片内容…」，结果只保存在内存，不写回「照片」。")
        case .systemOcrTexts:
            return ("text.viewfinder", "没有包含文字的照片", "先识别照片内容，图内文字会汇总到这里。")
        case .systemMap:
            return ("map", "没有位置信息", "带有 GPS 信息的照片会显示在地图上。")
        case .systemHealth:
            return ("stethoscope", "还没有体检结果", "体检会用缩略图检查清晰度与相似连拍，结果只保存在内存，不写回「照片」。")
        case .cloudMount:
            switch store.cloudScope {
            case .map, .places:
                return ("map", "没有位置信息", "点「读取照片信息」后，带 GPS 的网盘照片会显示在地图上。")
            case .people:
                return ("person.crop.square", "还没有识别到人物", "在「人物」页开始端侧分析，结果只保存在内存，不会上传或写回网盘。")
            case .duplicates:
                return ("square.on.square", "没有重复项目", "文件大小与像素尺寸相同的网盘项目会显示在这里；网盘只读，请到网盘 App 中合并。")
            case .revisit:
                return ("clock.arrow.circlepath", "没有值得重看的照片", "拍摄超过两年、且最近一年没有查看过的网盘照片会出现在这里。")
            default:
                return ("externaldrive.connected.to.line.below", "此文件夹没有照片", "当前目录中没有支持的照片或视频，可返回上一级或点按刷新重新读取。")
            }
        default:
            return ("photo.on.rectangle.angled", "没有照片", "")
        }
    }

    private var emptyActions: [LumaEmptyAction] {
        if store.photoFilter != .all || store.keywordFilter != nil {
            return [LumaEmptyAction(title: "清除筛选",
                                    symbol: "line.3.horizontal.decrease.circle") {
                store.clearFilter()
            }]
        }
        if store.sidebarItem == .trash, store.trashCount > 0 {
            return [LumaEmptyAction(title: "清空最近删除", symbol: "trash") {
                store.confirmEmptyTrash()
            }]
        }
        if store.sidebarItem == .library {
            return [LumaEmptyAction(title: "导入照片",
                                    symbol: "square.and.arrow.down",
                                    filled: true) {
                store.presentImportPanel()
            }]
        }
        if store.isCloudScope {
            return [LumaEmptyAction(title: "刷新", symbol: "arrow.clockwise") {
                store.refreshCloudDirectory()
            }]
        }
        return []
    }

    var body: some View {
        LumaEmptyState(symbol: content.icon,
                       title: content.title,
                       message: content.message,
                       actions: emptyActions)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 空状态不再铺一层实心底色：让环境光与一团强调色光晕透出来，和网站主视觉一致。
            .background {
                Circle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 340, height: 340)
                    .blur(radius: 100)
                    .offset(y: -70)
                    .allowsHitTesting(false)
            }
            .animation(settings.motion.overlay, value: content.title)
    }
}

struct ToastView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    /// 轻量识别提示语义：失败类给橙色警告，其余给绿色完成。
    private var style: (icon: String, tint: Color) {
        let text = store.toast ?? ""
        let errorHints = ["失败", "无法", "请先", "错误", "不能", "找不到", "不支持", "已取消"]
        if errorHints.contains(where: { text.contains($0) }) {
            return ("exclamationmark.triangle.fill", .orange)
        }
        return ("checkmark.circle.fill", .green)
    }

    var body: some View {
        VStack {
            Spacer()
            if let toast = store.toast {
                HStack(spacing: 8) {
                    Image(systemName: style.icon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(style.tint)
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .lumaGlassCapsule()
                .padding(.bottom, 84)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(settings.motion.overlay, value: store.toast)
        .allowsHitTesting(false)
    }
}

struct KeywordManagerView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var selectionModel: SelectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var newKeyword = ""

    private var hint: String {
        if selectionModel.ids.isEmpty {
            return "在图库中选择照片后，可为它们添加关键词。"
        }
        return "已将关键词应用到所选 \(selectionModel.ids.count) 项照片。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("关键词")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
            }

            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("输入关键词；用 / 表示层级，如 旅行/日本/京都", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addKeyword)
                Button("添加") {
                    addKeyword()
                }
                .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty || selectionModel.ids.isEmpty)
            }

            Divider()

            if store.keywordOptions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag")
                        .font(.system(size: 30, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("还没有关键词")
                        .font(.system(size: 13, weight: .medium))
                    Text("为照片添加关键词，之后可按关键词快速筛选。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.keywordOptions.sorted {
                            $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }) { option in
                            keywordRow(option)
                        }
                    }
                }
            }

            HStack {
                Text("\(store.keywordOptions.count) 个关键词")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430, height: 500)
    }

    private func keywordRow(_ option: KeywordOption) -> some View {
        let depth = PhotoItem.keywordDepth(option.name)
        let leaf = PhotoItem.keywordLeaf(option.name)
        let parent = PhotoItem.keywordComponents(option.name).dropLast().joined(separator: " / ")
        return HStack(spacing: 8) {
            Button {
                store.keywordFilter = option.name
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    if depth > 0 {
                        Spacer()
                            .frame(width: CGFloat(depth) * 12)
                    }
                    Image(systemName: depth == 0 ? "folder" : "tag")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(leaf)
                        .font(.system(size: 12.5))
                    if !parent.isEmpty {
                        Text(parent)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(option.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(option.name)

            if !selectionModel.ids.isEmpty {
                Button {
                    store.addKeyword(option.name, to: selectionModel.ids)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("添加到所选照片")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(store.keywordFilter == option.name ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .contextMenu {
            Button("筛选此关键词") {
                store.keywordFilter = option.name
                dismiss()
            }
            Button("从所有照片中删除", role: .destructive) {
                store.deleteKeyword(option.name)
            }
        }
    }

    private func addKeyword() {
        let parts = newKeyword.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for part in parts {
            store.addKeyword(part, to: selectionModel.ids)
        }
        newKeyword = ""
    }
}

struct NewAlbumSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建相簿")
                .font(.headline)
            TextField("相簿名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commit() }
            Text("创建的相簿会显示在侧边栏中。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.createAlbum(named: trimmed)
        dismiss()
    }
}
