import Foundation
import AVFoundation
import AppKit
import CoreGraphics
import CoreVideo

/// 回忆影片导出失败时给用户看的中文原因。
enum MemoryExportError: LocalizedError {
    case noPhotos
    case imageLoadFailed
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPhotos:
            return "这段回忆没有可导出的照片"
        case .imageLoadFailed:
            return "无法读取回忆中的照片"
        case .writerFailed(let message):
            return "视频写入失败：\(message)"
        }
    }
}

/// 把回忆渲染成无声 H.264 mp4：1280×720、24fps，照片之间交叉淡化。
/// 渲染完全在本机完成，不依赖 ffmpeg。
enum MemoryExporter {
    static let width = 1280
    static let height = 720
    static let fps: Int32 = 24
    static let slideDuration: Double = 3.6
    static let fadeDuration: Double = 0.5

    static func export(memory: PhotoMemory,
                       style: MemoryStyle,
                       to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let photos = memory.photos
        guard !photos.isEmpty else { throw MemoryExportError.noPhotos }

        try await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let images = loadImages(photos, progress: progress)
            guard !images.isEmpty else { throw MemoryExportError.imageLoadFailed }
            try render(images: images, style: style, to: url, progress: progress)
        }.value
    }

    // MARK: - 预载图片

    private static func loadImages(_ photos: [PhotoItem],
                                   progress: @Sendable (Double) -> Void) -> [CGImage] {
        var images: [CGImage] = []
        for (index, photo) in photos.enumerated() {
            autoreleasepool {
                if let image = ImageLoader.displayImage(for: photo, maxPixel: 1600),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    images.append(cgImage)
                }
            }
            progress(Double(index + 1) / Double(photos.count) * 0.15)
        }
        return images
    }

    // MARK: - 视频渲染

    private static func render(images: [CGImage],
                               style: MemoryStyle,
                               to url: URL,
                               progress: @Sendable (Double) -> Void) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: attributes)

        guard writer.canAdd(input) else {
            throw MemoryExportError.writerFailed("无法创建视频轨道")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw MemoryExportError.writerFailed(writer.error?.localizedDescription ?? "未知错误")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int((Double(images.count) * slideDuration * Double(fps)).rounded())
        guard totalFrames > 0 else { throw MemoryExportError.imageLoadFailed }
        let fadeFraction = fadeDuration / slideDuration

        for frame in 0..<totalFrames {
            if Task.isCancelled {
                input.markAsFinished()
                writer.cancelWriting()
                throw CancellationError()
            }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw MemoryExportError.writerFailed(writer.error?.localizedDescription ?? "未知错误")
                }
                Thread.sleep(forTimeInterval: 0.004)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw MemoryExportError.writerFailed("像素缓冲池不可用")
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let pixelBuffer = buffer else {
                throw MemoryExportError.writerFailed("无法分配视频帧")
            }

            let position = Double(frame) / Double(fps) / slideDuration
            let slide = min(images.count - 1, Int(position))
            let local = position - Double(slide)
            var nextSlide: Int?
            var fade: CGFloat = 0
            if slide + 1 < images.count, local > 1 - fadeFraction {
                nextSlide = slide + 1
                fade = CGFloat((local - (1 - fadeFraction)) / fadeFraction)
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let drawn = drawFrame(pixelBuffer: pixelBuffer, images: images,
                                  slide: slide, nextSlide: nextSlide,
                                  fade: fade, local: local, style: style)
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            guard drawn else {
                throw MemoryExportError.writerFailed("无法创建绘制上下文")
            }

            let time = CMTime(value: Int64(frame), timescale: fps)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw MemoryExportError.writerFailed(writer.error?.localizedDescription ?? "写入帧失败")
            }
            if frame % Int(fps) == 0 {
                progress(0.15 + 0.85 * Double(frame) / Double(totalFrames))
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        if writer.status != .completed {
            throw MemoryExportError.writerFailed(writer.error?.localizedDescription ?? "未知错误")
        }
        progress(1)
    }

    /// 把当前张（以及淡入中的下一张）绘制到像素缓冲；返回是否成功。
    private static func drawFrame(pixelBuffer: CVPixelBuffer,
                                  images: [CGImage],
                                  slide: Int,
                                  nextSlide: Int?,
                                  fade: CGFloat,
                                  local: Double,
                                  style: MemoryStyle) -> Bool {
        guard let context = makeContext(for: pixelBuffer) else { return false }
        let frameRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(frameRect)

        draw(image: images[slide], in: context, style: style, index: slide,
             progress: local, alpha: 1)
        if let nextSlide {
            draw(image: images[nextSlide], in: context, style: style, index: nextSlide,
                 progress: 0, alpha: fade)
        }

        if style.showsLetterbox {
            let bar = CGFloat(height) * 0.09
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: bar))
            context.fill(CGRect(x: 0, y: CGFloat(height) - bar, width: CGFloat(width), height: bar))
        }
        return true
    }

    private static func makeContext(for pixelBuffer: CVPixelBuffer) -> CGContext? {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        return CGContext(data: base,
                         width: width,
                         height: height,
                         bitsPerComponent: 8,
                         bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func draw(image: CGImage,
                             in context: CGContext,
                             style: MemoryStyle,
                             index: Int,
                             progress: Double,
                             alpha: CGFloat) {
        let frameW = CGFloat(width)
        let frameH = CGFloat(height)
        let imageW = CGFloat(image.width)
        let imageH = CGFloat(image.height)
        guard imageW > 0, imageH > 0, alpha > 0 else { return }

        let fill = max(frameW / imageW, frameH / imageH)
        let range = style.zoomRange
        let t = CGFloat(min(1, max(0, progress)))
        let zoom = range.start + (range.end - range.start) * t
        let scale = fill * zoom
        let drawW = imageW * scale
        let drawH = imageH * scale
        let horizontal: CGFloat = index % 2 == 0 ? 1 : -1
        let vertical: CGFloat = index % 4 < 2 ? 1 : -1
        let travel = style.panAmount * frameW
        let rect = CGRect(x: (frameW - drawW) / 2 + horizontal * travel * t,
                          y: (frameH - drawH) / 2 + vertical * travel * 0.5 * t,
                          width: drawW,
                          height: drawH)

        context.setAlpha(alpha)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.setAlpha(1)
    }
}
