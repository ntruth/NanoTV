import SwiftUI

/// 系统图库文件夹的整理面板：提取确认 → 执行中 → 清理空文件夹。
/// 三步共用一个 sheet，操作完成后面板原地切换，不打断连续操作。
struct SystemFolderOrganizeSheet: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Group {
            switch store.systemFolderPrompt {
            case .extract(let request):
                extractView(request)
            case .working(let title, let message):
                workingView(title: title, message: message)
            case .cleanupEmptyFolders(let request):
                cleanupView(request)
            case nil:
                EmptyView()
            }
        }
        .padding(22)
        .frame(width: 430)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                LinearGradient(colors: [Color.accentColor.opacity(0.06), .clear],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            }
        }
    }

    // MARK: - 确认提取

    private func extractView(_ request: ExtractAlbumsRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                iconTile(symbol: "folder.fill", badge: "arrow.up.right", tint: .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("把相簿提到这一层")
                        .font(.system(size: 16, weight: .semibold))
                    Text("「\(request.folderName)」")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                statCard(value: request.albumCount, unit: "个相簿", tint: .accentColor)
                statCard(value: request.subfolderCount, unit: "个子文件夹", tint: .orange)
            }

            VStack(alignment: .leading, spacing: 7) {
                tip("arrow.left.arrow.right", "只调整相簿位置，照片和相簿内容都不变")
                tip("sparkles", "完成后自动刷新目录与缩略图")
                tip("folder.badge.minus", "随后可决定是否清理空出来的子文件夹")
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    store.dismissSystemFolderPrompt()
                }
                .keyboardShortcut(.cancelAction)
                Button("提取 \(request.albumCount) 个相簿") {
                    store.confirmExtractSystemFolderAlbums(request)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 执行中

    private func workingView(title: String, message: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - 清理空文件夹

    private func cleanupView(_ request: EmptyFoldersCleanupRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                iconTile(symbol: "folder.fill", badge: "minus", tint: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("要清理空文件夹吗？")
                        .font(.system(size: 16, weight: .semibold))
                    Text("「\(request.folderName)」")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }

            Text("\(request.folderCount) 个子文件夹里的相簿都已经提到了上一层。删除它们只是去掉空壳，照片与相簿不受影响；选择「不删除」则会保留为空文件夹。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(request.folders.prefix(3)) { folder in
                    chip(folder.name)
                }
                if request.folderCount > 3 {
                    chip("+\(request.folderCount - 3)")
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("不删除，保留") {
                    store.dismissSystemFolderPrompt()
                }
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    store.confirmEmptyFoldersCleanup(request)
                } label: {
                    Text("删除 \(request.folderCount) 个空文件夹")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    // MARK: - 组件

    private func iconTile(symbol: String, badge: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.6)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
            Image(systemName: badge)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(3.5)
                .background(.black.opacity(0.35), in: Circle())
                .offset(x: 15, y: 15)
        }
    }

    private func statCard(value: Int, unit: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(unit)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.18))
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12),
                        in: Capsule(style: .continuous))
    }
}
