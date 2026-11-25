import Foundation
import SwiftUI
import PlaybackCore
import LumaContentCore

/// 网络电视播放：把频道接成查看器里的一个虚拟视频。
/// 直播不看续播、不写进度；关闭查看器即释放上下文。
extension LibraryStore {
    /// 打开频道时把当前列表里的所有频道一起装进查看器：
    /// 顶栏序号变成「当前 / 总数」，← / → 与工具栏的上一台 / 下一台直接换台。
    func openTVChannel(_ channel: TVChannel) {
        finishTVPlayback()
        tvModel.recordRecent(channel)
        let list = tvModel.visibleChannels.isEmpty ? [channel] : tvModel.visibleChannels
        var photos: [PhotoItem] = []
        var channels: [UUID: TVChannel] = [:]
        let siblingIndex = tvModel.channelsByName()
        for item in list {
            var resolved = item
            // 用户在信号详情里锁定的默认线路优先；锁定地址失效时自动回到最佳线路。
            if let preferred = tvModel.preferredStreamURL(for: item) {
                resolved.streamURL = preferred
            }
            // 把其它源里的同名频道并成备用线路：运营商 IPTV 的地址常只在该网络可用，
            // 主线路超时后要能自动顺延到公网源，而不是整个频道报「无可用资源」。
            let siblings = (siblingIndex[TVChannel.normalizedName(resolved.name)] ?? [])
                .filter { $0.id != resolved.id }
            if !siblings.isEmpty {
                var seen = Set([resolved.streamURL])
                resolved.alternateStreamURLs = (resolved.alternateStreamURLs + siblings.map(\.streamURL))
                    .filter { seen.insert($0).inserted }
                resolved.lineCount = 1 + resolved.alternateStreamURLs.count
            }
            // 记录每条线路自己的协议与请求头：并入的线路可能与主线不是同一种协议。
            for sibling in siblings {
                tvLineMetadata[sibling.streamURL] = TVLineMetadata(headers: sibling.headers,
                                                                   isHLS: sibling.isHLS)
            }
            tvLineMetadata[resolved.streamURL] = TVLineMetadata(headers: resolved.headers,
                                                                isHLS: resolved.isHLS)
            for url in resolved.alternateStreamURLs where tvLineMetadata[url] == nil {
                tvLineMetadata[url] = TVLineMetadata(headers: resolved.headers,
                                                     isHLS: TVLineMetadata.inferredHLS(for: url))
            }
            var photo = PhotoItem(filename: "tv-\(resolved.id).m3u8",
                                  originalName: resolved.name,
                                  capturedAt: Date(),
                                  pixelWidth: 1920,
                                  pixelHeight: 1080,
                                  fileSize: 0,
                                  kind: .video)
            photo.title = resolved.name
            photo.source = .cloud
            photo.cloudPath = resolved.streamURL
            photos.append(photo)
            channels[photo.id] = resolved
        }
        guard let target = photos.first(where: { channels[$0.id]?.id == channel.id }) ?? photos.first else {
            return
        }
        tvPlaybackPhotos = photos
        tvPlaybackChannels = channels
        openViewer(target.id, context: photos)
    }

    func tvPlaybackPhoto(for id: UUID) -> PhotoItem? {
        tvPlaybackPhotos.first(where: { $0.id == id })
    }

    /// 频道带 / 数字键换台：沿用当前播放器里的频道上下文，不再重建列表。
    func switchTVChannel(_ channel: TVChannel) {
        guard let target = tvPlaybackChannels.first(where: { $0.value.id == channel.id }) else {
            openTVChannel(channel)
            return
        }
        tvModel.recordRecent(channel)
        viewerIndexCache = nil
        viewerPositionCache = nil
        withAnimation(AppSettings.shared.motion.overlay) {
            viewerID = target.key
        }
        selection = [target.key]
        recordView(target.key)
    }

    func tvPlaybackChannel(for id: UUID) -> TVChannel? {
        tvPlaybackChannels[id]
    }

    func finishTVPlayback() {
        guard !tvPlaybackPhotos.isEmpty || !tvPlaybackChannels.isEmpty else { return }
        tvPlaybackPhotos = []
        tvPlaybackChannels = [:]
        tvCatchupPhotoIDs = []
        tvLineIndexes = [:]
        tvFailedLineIndexes = [:]
        tvLineFailureNotes = [:]
        tvLineMetadata = [:]
    }

    // MARK: - 线路切换

    func tvLineIndex(for photoID: UUID) -> Int {
        guard let channel = tvPlaybackChannels[photoID] else { return 0 }
        return channel.streamLines.firstIndex(of: channel.streamURL) ?? 0
    }

    func tvLineCount(for photoID: UUID) -> Int {
        tvPlaybackChannels[photoID]?.streamLines.count ?? 1
    }

    /// ← / → 或 OSD 线路按钮：在候选线路间循环。
    @discardableResult
    func switchTVLine(for photoID: UUID, delta: Int) -> Bool {
        guard let channel = tvPlaybackChannels[photoID] else { return false }
        let lines = channel.streamLines
        guard lines.count > 1 else {
            showToast("这个频道只有一条线路")
            return false
        }
        tvFailedLineIndexes[photoID] = []
        tvLineFailureNotes[photoID] = [:]
        let current = lines.firstIndex(of: channel.streamURL) ?? 0
        let next = (current + delta + lines.count) % lines.count
        applyTVLine(next, for: photoID)
        showToast("线路 \(next + 1)/\(lines.count)")
        return true
    }

    /// OSD 线路面板：直接点选某一条线路。
    @discardableResult
    func selectTVLine(_ index: Int, for photoID: UUID) -> Bool {
        guard let channel = tvPlaybackChannels[photoID],
              channel.streamLines.indices.contains(index),
              index != tvLineIndex(for: photoID) else { return false }
        tvFailedLineIndexes[photoID] = []
        tvLineFailureNotes[photoID] = [:]
        applyTVLine(index, for: photoID)
        showToast("线路 \(index + 1)/\(channel.streamLines.count)")
        return true
    }

    /// 播放失败自动顺延：每条线最多试一次；全部失败返回 false，由播放层展示错误卡片。
    /// `reason` 会记到这一条线路上，失败卡片据此逐条列出原因。
    @discardableResult
    func advanceTVLineAfterFailure(for photoID: UUID, reason: String? = nil) -> Bool {
        guard let channel = tvPlaybackChannels[photoID] else { return false }
        let lines = channel.streamLines
        guard lines.count > 1 else { return false }
        let current = lines.firstIndex(of: channel.streamURL) ?? 0
        var failed = tvFailedLineIndexes[photoID] ?? []
        failed.insert(current)
        tvFailedLineIndexes[photoID] = failed
        var notes = tvLineFailureNotes[photoID] ?? [:]
        notes[current] = reason ?? "无响应"
        tvLineFailureNotes[photoID] = notes
        guard let next = (0..<lines.count).first(where: { !failed.contains($0) }) else {
            return false
        }
        applyTVLine(next, for: photoID)
        showToast("线路 \(current + 1) 失败，已切换到线路 \(next + 1)/\(lines.count)")
        return true
    }

    /// 失败卡片用：把已记下的失败原因拼成「线路 1 超时、线路 2 返回 403」。
    func tvLineFailureSummary(for photoID: UUID) -> String {
        guard let notes = tvLineFailureNotes[photoID], !notes.isEmpty else { return "" }
        return notes.keys.sorted().map { index in
            "线路 \(index + 1) \(notes[index] ?? "无响应")"
        }.joined(separator: "、")
    }

    private func applyTVLine(_ index: Int, for photoID: UUID) {
        guard var channel = tvPlaybackChannels[photoID] else { return }
        let lines = channel.streamLines
        guard lines.indices.contains(index) else { return }
        channel.streamURL = lines[index]
        // 不同线路的协议与请求头可能不同：切到 HTTP-FLV 线路时必须把 isHLS 关掉，
        // 否则播放器会继续按 HLS 交给 AVPlayer，换线后依然播不出来。
        if let meta = tvLineMetadata[lines[index]] {
            channel.headers = meta.headers
            channel.isHLS = meta.isHLS
        } else {
            channel.isHLS = TVLineMetadata.inferredHLS(for: lines[index])
        }
        tvPlaybackChannels[photoID] = channel
        if let photoIndex = tvPlaybackPhotos.firstIndex(where: { $0.id == photoID }) {
            tvPlaybackPhotos[photoIndex].cloudPath = lines[index]
        }
        // 代次自增 → VideoPlayerStage 的 loadKey 变化，重新装片。
        tvLineTokens[photoID, default: 0] += 1
    }

    /// 从节目单 / 回看页打开一档过去的节目。
    /// 回看走单条点播上下文，不把频道列表装进播放器，避免误触换台。
    func openTVCatchup(_ channel: TVChannel, program: TVEPGProgram) {
        guard let template = channel.catchUpSource,
              let url = TVCatchupURL.build(template: template,
                                           program: program,
                                           channel: channel) else {
            return
        }
        finishTVPlayback()

        var catchupChannel = channel
        catchupChannel.streamURL = url.absoluteString
        catchupChannel.isCatchUp = true
        // catchup-source 基本都是 HLS（playseek 模板），地址里不一定带 .m3u8。
        // 不标成 HLS 会被当成直播 FLV 走转封装滑动窗口：回看没有真实时长，
        // 分片很快被挤掉，播放器就会不断重连、跳着播。
        let target = url.absoluteString.lowercased()
        catchupChannel.isHLS = !(target.contains(".flv") || target.contains(".mp4")
                                 || target.contains(".ts"))
        // 回看地址是单独拼出来的，直播线路在这里没有意义：
        // 留着会让「线路 N/M」菜单和失败顺延把回看切回直播地址。
        catchupChannel.alternateStreamURLs = []
        catchupChannel.lineCount = 1

        var photo = PhotoItem(filename: "tv-catchup-\(program.id).m3u8",
                              originalName: program.title,
                              capturedAt: program.start,
                              pixelWidth: 1920,
                              pixelHeight: 1080,
                              fileSize: 0,
                              kind: .video)
        photo.title = program.title
        photo.source = .cloud
        photo.cloudPath = url.absoluteString
        // 节目单时长：播放器还没解析出真实片长时，回看进度条用它兜底，
        // 否则顶栏读数会一直停在 `00:00`，进度条也画不出比例。
        if program.duration > 1 { photo.duration = program.duration }

        tvPlaybackPhotos = [photo]
        tvPlaybackChannels = [photo.id: catchupChannel]
        tvCatchupPhotoIDs = [photo.id]
        openViewer(photo.id, context: [photo])
    }

    /// 直播流：请求头随频道一起带进播放器。
    func resolveTVStream(for photoID: UUID) -> ResolvedStream? {
        guard let channel = tvPlaybackChannel(for: photoID),
              let url = URL(string: channel.streamURL) else { return nil }
        return ResolvedStream(url: url,
                              headers: channel.headers,
                              isHLS: channel.isHLS,
                              mode: tvCatchupPhotoIDs.contains(photoID) ? .vod : .live)
    }
}
