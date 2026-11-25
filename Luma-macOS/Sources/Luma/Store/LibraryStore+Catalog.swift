import Foundation
import AppKit
import Combine
import LumaContentCore

extension LibraryStore {
    /// 网络资源（影视源）的浏览状态。
    var catalog: CatalogBrowserModel { catalogModel }

    func presentCatalogWizard(domain: CatalogDomain = .networkResource) {
        catalogModel.wizardDomain = domain
        catalogModel.showWizard = true
    }

    /// 从侧边栏打开某个资源：先切换源，再走统一导航。
    func openCatalogSource(_ id: UUID) {
        catalogModel.focus(id)
        navigate(to: .catalogSource(id))
    }

    // MARK: - 卡片操作

    /// 在浏览器打开站点首页：403 / WAF / 人机验证时，
    /// 用户先在系统浏览器完成验证，回到应用再重试即可复用同一会话。
    func openCatalogSourceInBrowser(_ source: CatalogSource) {
        guard let url = URL(string: source.baseURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 在浏览器打开条目对应的站点原始详情页。
    /// 各站点的详情地址规则不同，直接问适配器要（拿不到就退回站点首页）。
    func openCatalogItemInBrowser(source: CatalogSource, item: CatalogItem) {
        guard let provider = CatalogProviders.provider(for: source.kind) else { return }
        Task {
            let detail = try? await provider.detail(source: source, itemID: item.id)
            if let page = detail?.episodes.first?.pageURL, let url = URL(string: page) {
                NSWorkspace.shared.open(url)
            } else if let url = URL(string: source.baseURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 把网络视频收进图库：转封装与导入交给统一入库服务。
    func saveCatalogVideoToLibrary(source: CatalogSource, item: CatalogItem) {
        guard catalogModel.savingItemID == nil,
              let provider = CatalogProviders.provider(for: source.kind) else { return }
        catalogModel.savingItemID = item.id
        Task { [weak self] in
            guard let self else { return }
            defer { catalogModel.savingItemID = nil }
            do {
                let detail = try await provider.detail(source: source, itemID: item.id)
                guard let episode = detail.episodes.first else {
                    throw CatalogError.parse("该条目没有可播放的视频")
                }
                let stream = try await provider.stream(source: source, episode: episode)
                let result = try await ingestService.ingest(
                    IngestRequest(
                        payload: .remoteVideo(RemoteMedia(url: stream.url,
                                                          headers: stream.headers,
                                                          trustSelfSigned: source.trustsInsecureCertificate)),
                        title: item.title.isEmpty ? nil : item.title
                    )
                )
                catalogModel.showNotice("已保存到图库：\(result.title)")
            } catch {
                Diagnostics.record("保存网络视频失败 \(item.title)：\(error.localizedDescription)")
                catalogModel.showNotice("保存失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 播放

    /// 把一次网络资源播放接进查看器：每一集映射成一个虚拟视频，
    /// 这样左右翻页就是切集，播放控件与影院完全一致。
    func playCatalog(_ request: CatalogPlaybackRequest) {
        finishCatalogPlayback()

        var photos: [PhotoItem] = []
        var contexts: [UUID: CatalogPlaybackContext] = [:]
        for episode in request.episodes {
            let label = episode.name ?? "第 \(episode.index) 集"
            var photo = PhotoItem(
                filename: "catalog-\(request.item.id)-ep\(episode.index).m3u8",
                originalName: "\(request.item.title) \(label)",
                capturedAt: Date(),
                pixelWidth: 1920,
                pixelHeight: 1080,
                fileSize: 0,
                kind: .video
            )
            photo.title = "\(request.item.title) · \(label)"
            photo.source = .cloud
            photo.cloudPath = episode.pageURL
            photos.append(photo)
            contexts[photo.id] = CatalogPlaybackContext(source: request.source,
                                                        item: request.item,
                                                        episode: episode)
        }
        guard !photos.isEmpty else { return }

        catalogPlaybackPhotos = photos
        catalogPlaybackContexts = contexts
        // 从详情页起的播：记住返回目标，退出播放器后回到那一页详情。
        // 这里用详情页点播放时留下的标记，而不是比较 catalog.detail——
        // 详情刚打开还没加载完就点播放时，detail 可能仍然是 nil。
        if let returnItem = catalogModel.takePlaybackReturnItem(), returnItem.id == request.item.id {
            catalogReturnSourceID = request.source.id
            catalogReturnItem = returnItem
        } else {
            catalogReturnSourceID = nil
            catalogReturnItem = nil
        }
        catalogPendingSeek = request.startSeconds > 3 ? request.startSeconds : nil

        let start = min(request.startIndex, photos.count - 1)
        // 详情是页内视图，不再需要等弹层收起；立刻铺开查看器，点播放不再有半秒空窗。
        openViewer(photos[start].id, context: photos)
    }

    /// 自定义片单整单连播：把每部片的第一集铺成同一个查看器会话。
    func playCatalogPlaylist(_ items: [CatalogPlaylistPlaybackItem]) {
        finishCatalogPlayback()
        catalogReturnSourceID = nil
        catalogReturnItem = nil
        _ = catalogModel.takePlaybackReturnItem()

        var photos: [PhotoItem] = []
        var contexts: [UUID: CatalogPlaybackContext] = [:]
        for entry in items {
            var photo = PhotoItem(
                filename: "catalog-\(entry.item.id)-ep\(entry.episode.index).m3u8",
                originalName: entry.item.title,
                capturedAt: Date(),
                pixelWidth: 1920,
                pixelHeight: 1080,
                fileSize: 0,
                kind: .video
            )
            photo.title = entry.item.title
            photo.source = .cloud
            photo.cloudPath = entry.episode.pageURL
            photos.append(photo)
            contexts[photo.id] = CatalogPlaybackContext(source: entry.source,
                                                        item: entry.item,
                                                        episode: entry.episode)
        }
        guard let first = photos.first else { return }

        catalogPlaybackPhotos = photos
        catalogPlaybackContexts = contexts
        catalogPendingSeek = nil

        openViewer(first.id, context: photos)
    }

    /// 查看器当前的虚拟分集（非图库内容）。
    func catalogPlaybackPhoto(for id: UUID) -> PhotoItem? {
        catalogPlaybackPhotos.first(where: { $0.id == id })
    }

    func catalogPlaybackContext(for id: UUID) -> CatalogPlaybackContext? {
        catalogPlaybackContexts[id]
    }

    /// 关闭查看器 / 切走时落盘并释放虚拟分集。
    func finishCatalogPlayback() {
        if let viewerID, let context = catalogPlaybackContexts[viewerID] {
            let current = viewerModel.videoPlayer.currentTime
            let duration = viewerModel.videoPlayer.duration
            if duration > 0, current > 3 {
                playbackProgressStore.recordCatalogProgress(source: context.source,
                                                            item: context.item,
                                                            episode: context.episode.index,
                                                            seconds: current,
                                                            duration: duration)
            }
        }
        catalogPlaybackPhotos = []
        catalogPlaybackContexts = [:]
        catalogPendingSeek = nil
    }

    /// 关闭播放器后回到刚才的详情页：把条目交给频道页恢复内联详情。
    func restoreCatalogDetailIfNeeded() {
        guard let item = catalogReturnItem, let sourceID = catalogReturnSourceID else { return }
        catalogReturnItem = nil
        catalogReturnSourceID = nil
        catalogModel.pendingInlineItem = item
        catalogModel.focus(sourceID)
        navigate(to: .catalogSource(sourceID))
    }
}
