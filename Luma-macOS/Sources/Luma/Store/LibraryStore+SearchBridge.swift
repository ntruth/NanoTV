import Foundation

/// 跨图库搜索的结果打开：先切 / 连到目标图库，等内容就绪后再打开条目。
extension LibraryStore {
    /// 点击其它图库里的搜索结果。
    /// - 官方「照片」图库：只连接浏览，不改变 App 自己的容器；
    /// - 拾光自建图库：只能整体切换过去。
    func openSearchResultInLibrary(path: String, pending: LibraryPendingOpen) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              LibraryPaths.isLibraryContainer(url) else {
            showToast("找不到这个图库，可能已被移动或外置盘未连接")
            return
        }
        pendingLibraryOpen = pending

        if LibraryPaths.isNativeLibrary(url) {
            connectSystemLibrary(url)
            let connected = systemLibraryPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
            guard connected == url.standardizedFileURL.path else {
                pendingLibraryOpen = nil
                return
            }
        } else {
            switchLibraryContainer(url)
            let opened = LibraryPaths.containerLibraryURL?.standardizedFileURL.path
            guard opened == url.standardizedFileURL.path else {
                pendingLibraryOpen = nil
                return
            }
        }
        consumePendingLibraryOpenIfReady()
    }

    /// 目标图库就绪后打开挂起条目；还没加载好就保持挂起，等索引应用完成再调用一次。
    func consumePendingLibraryOpenIfReady() {
        guard let pending = pendingLibraryOpen else { return }
        switch pending {
        case .photo(let id):
            if photos.contains(where: { $0.id == id }) {
                pendingLibraryOpen = nil
                if !isSystemScope { navigate(to: .library) }
                markSearchReturnLanded(isSystemScope ? .systemLibrary : .library)
                openViewer(id)
            } else if isSystemPhotoID(id) {
                pendingLibraryOpen = nil
                if !isSystemScope { navigate(to: .systemLibrary) }
                markSearchReturnLanded(.systemLibrary)
                openViewer(id)
            }

        case .album(let id):
            guard albums.contains(where: { $0.id == id }) else { return }
            pendingLibraryOpen = nil
            navigate(to: .album(id))
            markSearchReturnLanded(.album(id))

        case .folder(let id):
            guard folders.contains(where: { $0.id == id }) else { return }
            pendingLibraryOpen = nil
            navigate(to: .folder(id))
            markSearchReturnLanded(.folder(id))

        case .person(let id):
            guard localPeople.contains(where: { $0.id == id }) else { return }
            pendingLibraryOpen = nil
            navigate(to: .people)
            markSearchReturnLanded(.people)
            selectedLocalPersonID = id

        case .systemAlbum(let id):
            guard systemAlbums.contains(where: { $0.id == id }) else { return }
            pendingLibraryOpen = nil
            navigate(to: .systemAlbum(id))
            markSearchReturnLanded(.systemAlbum(id))

        case .systemFolder(let id):
            guard systemFolders.contains(where: { $0.id == id }) else { return }
            pendingLibraryOpen = nil
            navigate(to: .systemFolder(id))
            markSearchReturnLanded(.systemFolder(id))

        case .systemPerson(let person):
            guard systemPeople.contains(where: { $0.id == person.id }) else { return }
            pendingLibraryOpen = nil
            navigate(to: .systemPeople)
            markSearchReturnLanded(.systemPeople)
            openPerson(person)
        }
    }
}
