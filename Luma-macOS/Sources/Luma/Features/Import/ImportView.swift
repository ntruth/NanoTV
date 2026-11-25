import SwiftUI
import UniformTypeIdentifiers

struct ImportSheetView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selectedIDs: Set<UUID> = []
    @State private var targetAlbumID: UUID?

    private var candidates: [ImportCandidate] { store.importCandidates }
    private var totalFiles: Int { candidates.reduce(0) { $0 + $1.fileCount } }
    private var selectedCount: Int {
        candidates.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.fileCount }
    }
    private var selectedCandidates: [ImportCandidate] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 680, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .background { LumaAmbientBackground(intensity: 0.6) }
        .onAppear {
            guard !candidates.isEmpty else {
                dismissWindow(id: "import")
                return
            }
            if selectedIDs.isEmpty {
                selectedIDs = Set(candidates.map { $0.id })
            }
            // 从相簿里发起导入时，默认就把新项目加进这个相簿，避免「导入完了相簿里看不到」。
            if targetAlbumID == nil, let current = store.currentAlbumID {
                targetAlbumID = current
            }
            // 原生图库先确认「照片」正在用的就是当前这个库，否则提前给出切换引导。
            if store.isNativeContainer {
                store.refreshSystemWriteTargetState()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 36, height: 36)
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("导入")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(candidates.count) 个项目 · \(totalFiles.formatted()) 个文件")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if store.isImporting {
                Text("导入会在后台继续")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            Button {
                dismissWindow(id: "import")
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help("隐藏导入窗口（导入会继续）")

            Button {
                if store.isImporting {
                    dismissWindow(id: "import")
                } else {
                    store.dismissImportSheet()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help(store.isImporting ? "隐藏（导入会继续）" : "关闭")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var content: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text("新项目")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(selectedCount.formatted()) / \(totalFiles.formatted())")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                    ForEach(candidates) { candidate in
                        candidateRow(candidate)
                    }

                    ForEach(selectedCandidates) { candidate in
                        if !candidate.previewURLs.isEmpty {
                            previewSection(candidate)
                        }
                    }
                }
                .padding(.bottom, 16)
            }

            Divider()

            optionsPanel
                .frame(minWidth: 250, idealWidth: 272, maxWidth: 300)
        }
    }

    private func candidateRow(_ candidate: ImportCandidate) -> some View {
        let isSelected = selectedIDs.contains(candidate.id)
        return Button {
            if isSelected {
                selectedIDs.remove(candidate.id)
            } else {
                selectedIDs.insert(candidate.id)
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if isSelected {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                    }
                }
                .frame(width: 18, height: 18)

                coverView(candidate)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(candidate.fileCount.formatted()) 个项目")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if candidate.isDirectory {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
        .disabled(store.isImporting)
    }

    @ViewBuilder
    private func coverView(_ candidate: ImportCandidate) -> some View {
        if let cover = candidate.cover {
            Image(nsImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.14))
                .overlay {
                    Image(systemName: candidate.isDirectory ? "folder.fill" : "photo")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func previewSection(_ candidate: ImportCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("预览")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(candidate.previewURLs.count.formatted()) 个文件")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(candidate.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 100), spacing: 6)], spacing: 6) {
                ForEach(candidate.previewURLs, id: \.self) { url in
                    FileThumbnailView(url: url)
                        .frame(height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    /// 原生图库：明确告诉用户写入目标与边界，避免误以为在复制文件。
    private var nativeTargetNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "photo.badge.checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("写入系统「照片」图库")
                    .font(.system(size: 12, weight: .semibold))
                Text("通过 PhotoKit 新增项目，只做新增：不改动已有照片、相册与 Photos.sqlite。拍摄时间与位置会一并写入；可按文件夹创建相簿与文件夹，失败会逐条给出原因。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.6))
    }

    /// 当前打开的是挂载的其它「照片」图库：PhotoKit 只能写「照片」正在用的那个库。
    private var targetMismatchNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("这个图库还不是「照片」当前图库")
                        .font(.system(size: 12, weight: .semibold))
                    Text("「照片」同一时间只允许写入它自己打开的那个图库。在「照片」中打开「\(store.systemLibraryName ?? "这个图库")」后，就能导入照片、创建相簿与文件夹。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("在「照片」中打开图库…") {
                    store.openCurrentLibraryInPhotosForImport()
                }
                .controlSize(.small)
                Button("重新检测") {
                    store.refreshSystemWriteTargetState()
                }
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.6))
    }

    private var optionsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("导入选项")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if store.isNativeContainer {
                    nativeTargetNotice
                    if store.systemWriteTargetState == .mismatch {
                        targetMismatchNotice
                    }
                    Divider()
                }

                if !store.isNativeContainer {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("相簿")
                            .font(.system(size: 12, weight: .medium))
                        Picker("相簿", selection: $targetAlbumID) {
                            Text("无").tag(UUID?.none)
                            ForEach(store.albumsSorted) { album in
                                Text(album.name).tag(UUID?.some(album.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Text("未按文件夹整理的文件会添加到该相簿。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()
                }

                Toggle(isOn: $settings.importCreateAlbumsFromFolders) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.isNativeContainer
                             ? "将最后一层文件夹创建为「照片」相簿"
                             : "将最后一层文件夹创建为相簿")
                            .font(.system(size: 12, weight: .medium))
                        Text("每个文件夹的最末一级目录会成为相簿名称。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $settings.importPreserveFolderStructure) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.isNativeContainer
                             ? "保留上层文件夹结构（「照片」文件夹）"
                             : "保留上层文件夹结构")
                            .font(.system(size: 12, weight: .medium))
                        Text(store.isNativeContainer
                             ? "上层目录会创建为「照片」里的文件夹，相簿放进去；关闭后只保留末级相簿。"
                             : "上层目录会创建为可展开的文件夹。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!settings.importCreateAlbumsFromFolders)
                .opacity(settings.importCreateAlbumsFromFolders ? 1 : 0.45)

                Divider()

                Toggle(isOn: $settings.importSkipExactDuplicates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("跳过完全重复的文件")
                            .font(.system(size: 12, weight: .medium))
                        Text(store.isNativeContainer
                             ? "导入前计算 SHA-256；拾光写入过的相同文件不会重复写进「照片」。"
                             : "导入前计算 SHA-256；与图库或本批次已有文件完全相同时不复制。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if !store.isNativeContainer {
                    Toggle(isOn: $settings.importVerifyCopies) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("导入后校验文件完整性")
                                .font(.system(size: 12, weight: .medium))
                            Text("复制完成后重新计算目标文件哈希，确认写入没有损坏。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    if candidates.contains(where: { !$0.isDirectory }) {
                        Divider()
                        Text("直接选择的照片会导入图库，不会创建相簿。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                Text("提示")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("开始导入后可隐藏此窗口，导入会在后台继续。随时可从这里、侧边栏或主窗口的进度条重新打开。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .disabled(store.isImporting)
        }
    }

    /// 当前库不是「照片」正在使用的图库：先引导切换，避免导入到一半才失败。
    private var systemTargetBlocked: Bool {
        store.isNativeContainer && store.systemWriteTargetState == .mismatch
    }

    @ViewBuilder
    private var footer: some View {
        if let progress = store.importProgress {
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
                    Text(store.isNativeContainer
                         ? "已写入 \(progress.importedCount.formatted()) 项"
                         : "已导入 \(progress.importedCount.formatted()) 项")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if progress.skippedDuplicates > 0 {
                        Text("· 跳过重复 \(progress.skippedDuplicates)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                    }
                    if progress.failedCount > 0 {
                        Text("· 失败 \(progress.failedCount)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.red)
                    }
                    if progress.verifiedCount > 0 {
                        Text("· 已校验 \(progress.verifiedCount)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.green)
                    }
                    Button("隐藏窗口") {
                        dismissWindow(id: "import")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.leading, 10)
                    Button("取消导入") {
                        store.cancelImport()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.leading, 6)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        } else {
            HStack(spacing: 10) {
                Button("取消") {
                    store.dismissImportSheet()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("导入所选（\(selectedCount.formatted())）") {
                    beginImport(importAll: false)
                }
                .disabled(selectedIDs.isEmpty || systemTargetBlocked)
                .help(systemTargetBlocked ? "需要先在「照片」中打开这个图库" : "只导入当前勾选的项目")

                Button("导入全部") {
                    beginImport(importAll: true)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(systemTargetBlocked)
                .help(systemTargetBlocked ? "需要先在「照片」中打开这个图库" : "导入全部项目")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func beginImport(importAll: Bool) {
        var options = ImportOptions()
        options.createAlbumsFromFolders = settings.importCreateAlbumsFromFolders
        options.preserveFolderStructure = settings.importPreserveFolderStructure
        options.targetAlbumID = targetAlbumID
        options.skipExactDuplicates = settings.importSkipExactDuplicates
        options.verifyCopies = settings.importVerifyCopies
        store.startImport(selectedIDs: selectedIDs, importAll: importAll, options: options)
    }
}

struct FileThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    private static let cache = MemoryImageCache(totalCostLimit: 128 * 1024 * 1024)

    private var isMovie: Bool {
        VideoFormats.isVideo(url)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .quaternaryLabelColor).opacity(0.18)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: isMovie ? "video" : "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            if isMovie {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "play.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.4), in: Circle())
                        Spacer()
                    }
                    .padding(4)
                }
            }
        }
        .clipped()
        .task(id: url) {
            let key = url.path as NSString
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            let target = url
            let movie = isMovie
            let loaded = await Task.detached(priority: .utility) {
                ImportService.previewThumbnail(url: target, isMovie: movie, maxPixel: 220)
            }.value
            if let loaded {
                let rep = loaded.representations.first
                let cost = max(1, (rep?.pixelsWide ?? 220) * (rep?.pixelsHigh ?? 220) * 4)
                Self.cache.setObject(loaded, forKey: key, cost: cost)
            }
            image = loaded
        }
    }
}
