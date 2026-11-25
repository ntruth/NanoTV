import Foundation
import PlaybackCore

/// 影院 / 目录的播放钩子：内核负责「什么时候取续播、什么时候落盘、什么时候预热」，
/// 这里只提供具体记录与数据落点。
extension LibraryStore: PlaybackHooks {
    func resumePosition(for photoID: UUID) -> Double? {
        // 影院：优先续播记录，其次片头。
        if let entry = cinemaPlaybackEntry, entry.file.photoID == photoID {
            let shouldResume = UserDefaults.standard.object(forKey: "cinema_resume_playback") as? Bool ?? true
            if shouldResume,
               let record = cinemaProgress[entry.id],
               record.isTrustworthy(realDuration: entry.file.duration),
               !record.isFinished,
               record.position > 3,
               record.duration > record.position {
                return min(record.position, max(0, record.duration - 3))
            }
            if entry.kind == .tv {
                let intro = cinemaIntroMark(for: entry).introSeconds
                if intro > 0 { return Double(intro) }
            }
            return nil
        }
        // 网络资源：详情页点播放时带上的起播秒数。
        if catalogPlaybackContexts[photoID] != nil {
            return catalogPendingSeek
        }
        return nil
    }

    func resumeConsumed(for photoID: UUID) {
        // 目录的起播秒数来自详情页这一次点击：只生效一次，切集后不能重复使用。
        if catalogPlaybackContexts[photoID] != nil {
            catalogPendingSeek = nil
        }
    }

    func hasResumeProgress(for photoID: UUID) -> Bool {
        if let entry = cinemaPlaybackEntry, entry.file.photoID == photoID {
            let shouldResume = UserDefaults.standard.object(forKey: "cinema_resume_playback") as? Bool ?? true
            guard shouldResume,
                  let record = cinemaProgress[entry.id],
                  record.isTrustworthy(realDuration: entry.file.duration),
                  !record.isFinished,
                  record.position > 3,
                  record.duration > record.position else { return false }
            return true
        }
        if catalogPlaybackContexts[photoID] != nil {
            return (catalogPendingSeek ?? 0) > 3
        }
        return false
    }

    func introSeconds(for photoID: UUID) -> Double {
        guard let entry = cinemaPlaybackEntry,
              entry.file.photoID == photoID,
              entry.kind == .tv else { return 0 }
        return Double(cinemaIntroMark(for: entry).introSeconds)
    }

    func outroSeconds(for photoID: UUID) -> Double {
        guard let entry = cinemaPlaybackEntry,
              entry.file.photoID == photoID,
              entry.kind == .tv else { return 0 }
        return Double(cinemaIntroMark(for: entry).outroSeconds)
    }

    func playbackProgress(photoID: UUID, position: Double, duration: Double) {
        if let entry = cinemaPlaybackEntry, entry.file.photoID == photoID {
            saveCinemaProgress(position: position, duration: duration, entry: entry)
            return
        }
        if let context = catalogPlaybackContexts[photoID] {
            playbackProgressStore.recordCatalogProgress(source: context.source,
                                                        item: context.item,
                                                        episode: context.episode.index,
                                                        seconds: position,
                                                        duration: duration)
        }
    }

    func playbackNearEnd(photoID: UUID) {
        guard let entry = cinemaPlaybackEntry, entry.file.photoID == photoID else { return }
        prewarmCinemaNextEpisode(after: entry)
    }

    func playbackFinished(photoID: UUID, position: Double, duration: Double) {
        if let entry = cinemaPlaybackEntry, entry.file.photoID == photoID {
            saveCinemaProgress(position: duration, duration: duration, entry: entry)
            return
        }
        if let context = catalogPlaybackContexts[photoID] {
            playbackProgressStore.recordCatalogProgress(source: context.source,
                                                        item: context.item,
                                                        episode: context.episode.index,
                                                        seconds: duration,
                                                        duration: duration)
        }
    }
}
