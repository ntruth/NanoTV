import Foundation
import NanoCore
import Observation

/// 单次连接测速采样点与诊断报告（对齐 Infuse Pro 测速仪）
public struct SpeedBenchmarkReport: Sendable {
    public var sourceName: String
    public var currentMbps: Double
    public var averageMbps: Double
    public var peakMbps: Double
    public var minimumMbps: Double
    public var downloadedBytes: Int64
    public var samplesMbps: [Double]
    public var isRunning: Bool

    /// 根据最低与平均吞吐带宽给出 4K 原盘播放流畅度诊断
    public var qualityVerdict: String {
        if averageMbps >= 100 {
            return "极佳 · 轻松流畅播放 4K UHD 蓝光原盘 REMUX (80~120 Mbps)"
        } else if averageMbps >= 40 {
            return "优秀 · 稳定流畅播放 4K Dolby Vision / HDR 流媒体高码率片源"
        } else if averageMbps >= 18 {
            return "良好 · 满足 1080P 高码率原画，高码 4K REMUX 可能偶发缓冲"
        } else if averageMbps > 0 {
            return "受限 · 当前链路带宽较低，建议检查局域网 Wi-Fi 或切换网盘方案 A/B 线路"
        }
        return "等待开始测速..."
    }

    public init(
        sourceName: String = "",
        currentMbps: Double = 0,
        averageMbps: Double = 0,
        peakMbps: Double = 0,
        minimumMbps: Double = 0,
        downloadedBytes: Int64 = 0,
        samplesMbps: [Double] = [],
        isRunning: Bool = false
    ) {
        self.sourceName = sourceName
        self.currentMbps = currentMbps
        self.averageMbps = averageMbps
        self.peakMbps = peakMbps
        self.minimumMbps = minimumMbps
        self.downloadedBytes = downloadedBytes
        self.samplesMbps = samplesMbps
        self.isRunning = isRunning
    }
}

/// Infuse Pro 级存储源连接速度压测仪（支持对 NAS SMB / WebDAV / 小雅 302 / 115 / 夸克 / 百度直链进行真实吞吐波形测速）
@Observable
public final class StorageSpeedBenchmarkService: @unchecked Sendable {
    public static let shared = StorageSpeedBenchmarkService()

    public private(set) var report = SpeedBenchmarkReport()
    private var activeTask: Task<Void, Never>?

    public init() {}

    @MainActor
    public func startBenchmark(
        sourceName: String,
        streamURL: URL,
        headers: [String: String] = [:],
        durationSeconds: Double = 6.0
    ) {
        activeTask?.cancel()
        report = SpeedBenchmarkReport(sourceName: sourceName, isRunning: true)

        activeTask = Task {
            var req = URLRequest(url: streamURL)
            req.httpMethod = "GET"
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }

            let startClock = ContinuousClock.now
            var lastSampleClock = startClock
            var totalBytes: Int64 = 0
            var windowBytes: Int64 = 0
            var samples: [Double] = []

            do {
                let (byteStream, _) = try await URLSession.shared.bytes(for: req)
                for try await _ in byteStream {
                    if Task.isCancelled { break }
                    totalBytes += 1
                    windowBytes += 1

                    // 每累计 64 KB 检查一次时间间隔，达到 0.35s 输出一个波形采样点
                    if windowBytes >= 65536 {
                        let now = ContinuousClock.now
                        let windowElapsed = Self.seconds(from: lastSampleClock, to: now)
                        let totalElapsed = Self.seconds(from: startClock, to: now)

                        if windowElapsed >= 0.35 {
                            let instantMbps = (Double(windowBytes) * 8.0) / (windowElapsed * 1_000_000.0)
                            let avgMbps = (Double(totalBytes) * 8.0) / (max(0.01, totalElapsed) * 1_000_000.0)
                            samples.append(instantMbps)
                            let peak = samples.max() ?? instantMbps
                            let minVal = samples.min() ?? instantMbps
                            let snapBytes = totalBytes
                            let snapSamples = samples

                            await MainActor.run {
                                self.report = SpeedBenchmarkReport(
                                    sourceName: sourceName,
                                    currentMbps: instantMbps,
                                    averageMbps: avgMbps,
                                    peakMbps: peak,
                                    minimumMbps: minVal,
                                    downloadedBytes: snapBytes,
                                    samplesMbps: snapSamples,
                                    isRunning: true
                                )
                            }
                            windowBytes = 0
                            lastSampleClock = now
                        }

                        if totalElapsed >= durationSeconds {
                            break
                        }
                    }
                }
            } catch {
                // 网络不可达或测试中断时安全结束
            }

            await MainActor.run {
                self.report.isRunning = false
            }
        }
    }

    @MainActor
    public func cancelBenchmark() {
        activeTask?.cancel()
        report.isRunning = false
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: end)
        return Double(d.components.seconds) + (Double(d.components.attoseconds) / 1e18)
    }
}
