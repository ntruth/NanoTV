import Foundation
import AppKit
import Combine
import MediaPlayer
import PlaybackCore

/// 系统「正在播放」与媒体键集成：
/// 控制中心 / 耳机 / 键盘媒体键都能看到当前视频并控制播放、前后切换与拖动。
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private weak var model: VideoPlayerModel?
    private var cancellables: Set<AnyCancellable> = []
    private var commandTokens: [(command: MPRemoteCommand, token: Any)] = []
    private var onNext: (() -> Void)?
    private var onPrevious: (() -> Void)?

    private var title = ""
    private var subtitle: String?
    private var artwork: MPMediaItemArtwork?
    private var activated = false

    private init() {}

    func activate(model: VideoPlayerModel,
                  title: String,
                  subtitle: String?,
                  artwork: NSImage?,
                  onNext: (() -> Void)?,
                  onPrevious: (() -> Void)?) {
        if activated, self.model === model {
            updateMetadata(title: title, subtitle: subtitle, artwork: artwork)
            return
        }
        deactivate()
        self.model = model
        self.onNext = onNext
        self.onPrevious = onPrevious
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork.flatMap(makeArtwork)
        installCommands()
        bind()
        updateInfo()
        activated = true
    }

    func deactivate() {
        guard activated else { return }
        cancellables.removeAll()
        for item in commandTokens {
            item.command.removeTarget(item.token)
        }
        commandTokens.removeAll()
        model = nil
        onNext = nil
        onPrevious = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        activated = false
    }

    private func updateMetadata(title: String, subtitle: String?, artwork: NSImage?) {
        self.title = title
        self.subtitle = subtitle
        if let artwork {
            self.artwork = makeArtwork(artwork)
        }
        updateInfo()
    }

    private func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork? {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func bind() {
        guard let model else { return }
        model.$currentTime
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.updateInfo() }
            .store(in: &cancellables)
        model.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateInfo() }
            .store(in: &cancellables)
        model.$duration
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateInfo() }
            .store(in: &cancellables)
    }

    private func updateInfo() {
        guard let model else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: model.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: model.isPlaying ? model.speed : 0
        ]
        if let subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = model.isPlaying ? .playing : .paused
    }

    private func installCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { [weak self] _ in
            Task { @MainActor in self?.model?.play() }
            return .success
        }
        add(center.pauseCommand) { [weak self] _ in
            Task { @MainActor in self?.model?.pause() }
            return .success
        }
        add(center.togglePlayPauseCommand) { [weak self] _ in
            Task { @MainActor in self?.model?.togglePlay() }
            return .success
        }
        add(center.nextTrackCommand) { [weak self] _ in
            Task { @MainActor in self?.onNext?() }
            return .success
        }
        add(center.previousTrackCommand) { [weak self] _ in
            Task { @MainActor in self?.onPrevious?() }
            return .success
        }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.model?.requestSeek(to: event.positionTime) }
            return .success
        }
    }

    private func add(_ command: MPRemoteCommand,
                     handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        let token = command.addTarget(handler: handler)
        commandTokens.append((command, token))
    }
}
