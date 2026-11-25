// AVPlayer 能力探测：对本地文件或 http(s) 地址输出可播性、轨道、HLS 音轨菜单与实际起播状态。
//
// 用法：
//   swiftc -O -parse-as-library Tools/avplayer_probe.swift -o /tmp/avprobe
//   /tmp/avprobe <path-or-url> [...]
//
// 输出：JSON 数组（每项对应一个输入）。只采集 AVFoundation 公开 API 能读到的事实，
// 不推断「有没有声音」；声音是否输出必须由 App / 系统音频链路实测。

import AppKit
import AVFoundation
import CoreMedia
import Foundation

struct TrackReport: Codable {
    var type: String
    var codecs: [String]
    var size: String?
    var fps: Double?
    var channels: Int?
    var sampleRate: Double?
    var language: String?
    var decodable: Bool
    var colorExtensions: [String: String]?
}

struct AudioOptionReport: Codable {
    var displayName: String
    var language: String?
    var mediaType: String
}

struct ProbeReport: Codable {
    var input: String
    var transport: String
    var isPlayable: Bool?
    var duration: Double?
    var tracks: [TrackReport]
    var audioOptions: [AudioOptionReport]
    var itemStatus: String
    var itemError: String?
    var presentationSize: String?
    var videoRange: String?
    var playedRate: Double?
    var playedSeconds: Double?
    var likelyToKeepUp: Bool?
    var playerError: String?
    var elapsedSeconds: Double
    /// 手动选中的 HLS 音轨（验证多音轨 master 的即时切换）。
    var selectedAudio: String?
    /// AVPlayerItem.tracks：HLS 的 AVURLAsset.tracks 常常为空，
    /// 但播放项轨道能反映「实际装进播放器的是哪些轨」。
    var itemTracks: [String]?
    /// 当前屏幕 EDR 余量：决定 Luma 的 automatic HDR 策略是保留还是映射。
    var displayEDR: Double?
    var displayPotentialEDR: Double?
}

func fourCC(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF)
    ]
    let text = String(bytes: bytes, encoding: .ascii) ?? "????"
    return text.trimmingCharacters(in: .whitespaces)
}

func colorExtensions(_ description: CMFormatDescription) -> [String: String]? {
    guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] else {
        return nil
    }
    // 只保留与 HDR / 色彩 / 杜比视界相关的键，避免输出里塞满无关元数据。
    let wanted = [
        "ColorPrimaries", "TransferFunction", "YCbCrMatrix", "VideoFullRangeFlag",
        "CVImageBufferColorPrimaries", "CVImageBufferTransferFunction",
        "CVImageBufferYCbCrMatrix", "FullRangeVideo", "BitsPerComponent",
        "DolbyVisionRPUData", "DolbyVisionConfiguration", "MasteringDisplayColorVolume",
        "ContentLightLevelInfo", "PixelFormat"
    ]
    var result: [String: String] = [:]
    for (key, value) in extensions where wanted.contains(key) {
        result[key] = "\(value)"
    }
    return result.isEmpty ? nil : result
}

func audioChannels(_ description: CMFormatDescription) -> (Int?, Double?) {
    guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
        return (nil, nil)
    }
    return (Int(stream.mChannelsPerFrame), stream.mSampleRate)
}

func describe(_ url: URL, headers: [String: String],
              audioIndex: Int? = nil) async -> ProbeReport {
    let started = Date()
    let options: [String: Any] = headers.isEmpty
        ? [:]
        : ["AVURLAssetHTTPHeaderFieldsKey": headers]
    let asset = AVURLAsset(url: url, options: options)
    var report = ProbeReport(
        input: url.isFileURL ? url.path : url.absoluteString,
        transport: url.isFileURL ? "file" : (url.scheme ?? ""),
        isPlayable: nil,
        duration: nil,
        tracks: [],
        audioOptions: [],
        itemStatus: "unknown",
        itemError: nil,
        presentationSize: nil,
        videoRange: nil,
        playedRate: nil,
        playedSeconds: nil,
        likelyToKeepUp: nil,
        playerError: nil,
        elapsedSeconds: 0,
        selectedAudio: nil,
        itemTracks: nil,
        displayEDR: NSScreen.main.map { Double($0.maximumExtendedDynamicRangeColorComponentValue) },
        displayPotentialEDR: NSScreen.main.map { Double($0.maximumPotentialExtendedDynamicRangeColorComponentValue) }
    )

    report.isPlayable = (try? await asset.load(.isPlayable)) ?? false
    if let duration = try? await asset.load(.duration), duration.isNumeric {
        report.duration = duration.seconds
    }

    if let tracks = try? await asset.load(.tracks) {
        for track in tracks {
            var entry = TrackReport(type: track.mediaType.rawValue,
                                    codecs: [],
                                    size: nil,
                                    fps: nil,
                                    channels: nil,
                                    sampleRate: nil,
                                    language: nil,
                                    decodable: false,
                                    colorExtensions: nil)
            if let descriptions = try? await track.load(.formatDescriptions) {
                entry.codecs = descriptions.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
                for description in descriptions {
                    if track.mediaType == .audio {
                        let (channels, rate) = audioChannels(description)
                        entry.channels = entry.channels ?? channels
                        entry.sampleRate = entry.sampleRate ?? rate
                    }
                    if track.mediaType == .video, entry.colorExtensions == nil {
                        entry.colorExtensions = colorExtensions(description)
                    }
                }
            }
            if track.mediaType == .video {
                if let size = try? await track.load(.naturalSize) {
                    entry.size = "\(Int(size.width))x\(Int(size.height))"
                }
                if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
                    entry.fps = Double(fps)
                }
            }
            entry.language = try? await track.load(.languageCode)
            entry.decodable = (try? await track.load(.isDecodable)) ?? false
            report.tracks.append(entry)
        }
    }

    if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
        report.audioOptions = group.options.map { option in
            AudioOptionReport(displayName: option.displayName,
                              language: option.extendedLanguageTag ?? option.locale?.identifier,
                              mediaType: option.mediaType.rawValue)
        }
    }

    // 真正起播：AVPlayerItem 进入 readyToPlay 后 play 1.5 秒，记录速率与错误。
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.automaticallyWaitsToMinimizeStalling = true

    let deadline = Date().addingTimeInterval(15)
    while item.status == .unknown, Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    switch item.status {
    case .readyToPlay: report.itemStatus = "readyToPlay"
    case .failed: report.itemStatus = "failed"
    case .unknown: report.itemStatus = "timeout"
    @unknown default: report.itemStatus = "unknown"
    }
    if let error = item.error {
        report.itemError = "\(error)"
    }
    report.presentationSize = "\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))"
    // macOS 的 AVPlayerItem 没有 videoRange 属性：从视频轨的 CMFormatDescription
    // 扩展里读 TransferFunction / ColorPrimaries，自己归类。
    if let videoTrack = report.tracks.first(where: { $0.type == AVMediaType.video.rawValue }),
       let extensions = videoTrack.colorExtensions {
        let transfer = (extensions["CVImageBufferTransferFunction"]
                        ?? extensions["TransferFunction"] ?? "").lowercased()
        let primaries = (extensions["CVImageBufferColorPrimaries"]
                         ?? extensions["ColorPrimaries"] ?? "").lowercased()
        if transfer.contains("2084") || transfer.contains("pq") {
            report.videoRange = "HDR10/PQ"
        } else if transfer.contains("hlg") || transfer.contains("2100") {
            report.videoRange = "HLG"
        } else if primaries.contains("2020") {
            report.videoRange = "BT2020"
        } else {
            report.videoRange = "SDR"
        }
    }

    if item.status == .readyToPlay {
        if let audioIndex,
           let group = try? await asset.loadMediaSelectionGroup(for: .audible),
           audioIndex >= 0, audioIndex < group.options.count {
            let option = group.options[audioIndex]
            item.select(option, in: group)
            report.selectedAudio = option.displayName
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        var itemTracks: [String] = []
        for itemTrack in item.tracks {
            let mediaType = itemTrack.assetTrack?.mediaType.rawValue ?? "unknown"
            var codecs: [String] = []
            if let assetTrack = itemTrack.assetTrack,
               let descriptions = try? await assetTrack.load(.formatDescriptions) {
                codecs = descriptions.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
            }
            itemTracks.append("\(mediaType):\(codecs.joined(separator: ","))"
                              + ":enabled=\(itemTrack.isEnabled)")
        }
        report.itemTracks = itemTracks
        player.play()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        report.playedRate = Double(player.rate)
        let seconds = player.currentTime().seconds
        report.playedSeconds = seconds.isFinite ? seconds : nil
        report.likelyToKeepUp = item.isPlaybackLikelyToKeepUp
        if let error = player.error {
            report.playerError = "\(error)"
        }
        player.pause()
    }
    // 不等待 AVPlayer 内部线程退出：测完直接返回，由进程结束回收。
    report.elapsedSeconds = Date().timeIntervalSince(started)
    return report
}

@main
struct ProbeMain {
    static func main() async {
        let inputs = Array(CommandLine.arguments.dropFirst())
        guard !inputs.isEmpty else {
            FileHandle.standardError.write(Data("usage: avprobe <path-or-url> [...]\n".utf8))
            exit(2)
        }
        // 鉴权头由环境变量注入：模拟 App 的 AVURLAssetHTTPHeaderFieldsKey。
        var headers: [String: String] = [:]
        if let raw = ProcessInfo.processInfo.environment["AVPROBE_HEADERS"],
           let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            headers = parsed
        }
        var results: [ProbeReport] = []
        let audioIndex = ProcessInfo.processInfo.environment["AVPROBE_AUDIO_INDEX"]
            .flatMap { Int($0) }
        for input in inputs {
            let url: URL
            if input.hasPrefix("http://") || input.hasPrefix("https://") {
                guard let parsed = URL(string: input) else { continue }
                url = parsed
            } else {
                url = URL(fileURLWithPath: input)
            }
            results.append(await describe(url, headers: headers, audioIndex: audioIndex))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(results) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
