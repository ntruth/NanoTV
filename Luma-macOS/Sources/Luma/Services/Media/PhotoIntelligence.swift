import AppKit
import Foundation
import LumaCore
import Vision

/// 端侧照片内容分析：场景分类标签 + OCR 文字 + 二维码 / 条码 + 图像特征向量。
/// 全部在本机 Vision 框架内完成，不上传任何照片。
enum PhotoIntelligence {
    struct Result {
        /// 空格分隔的 Vision 分类标签（小写英文），以及拾光补的合成标签：
        /// `qrcode` / `barcode`（检测到码）、`idphoto`（单人竖幅人像）、
        /// `invoice`（发票强特征 + 号码规则）、`idcard`（身份证字段或合法号码）。
        let labels: String
        /// OCR 识别出的文字与二维码 / 条码内容，可能为空。
        let text: String
        /// 归一化后的图像特征向量（Float32），用于相似照片检索。
        let feature: Data?
    }

    static func analyze(_ photo: PhotoItem) -> Result? {
        // 用 CGImageSource 现场解码出一份独立缩略图（而不是 NSImage(contentsOf:) 的惰性映射）。
        // 系统图库的缩略图缓存可能在后台被并发重建，Vision 直接持有映射内存时会出现 SIGBUS；
        // 这里始终给它一块已经解码完成的位图，避免分析线程读到失效的文件映射。
        guard !photo.isVideo,
              let image = ImageLoader.gridThumbnail(for: photo, maxPixel: 1200),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width > 0, cgImage.height > 0 else {
            return nil
        }
        guard var result = analyze(cgImage: cgImage) else { return nil }
        // 媒体类型本身就是可靠信号：截图 / 自拍直接补标签，避免模型漏判。
        var extra: [String] = []
        if photo.kind == .screenshot { extra.append("截图") }
        if photo.kind == .selfie { extra.append("自拍") }
        if !extra.isEmpty {
            var pieces = result.labels.split(separator: " ").map(String.init)
            let sentinel = PhotoTagCatalog.sentinel
            let hadSentinel = pieces.contains(sentinel)
            pieces.removeAll { $0 == sentinel }
            for tag in extra where !pieces.contains(tag) { pieces.append(tag) }
            // 版本标记保持原样：只有底层真的跑过 SigLIP2 时才继续携带。
            if hadSentinel { pieces.append(sentinel) }
            result = Result(labels: pieces.joined(separator: " "),
                            text: result.text,
                            feature: result.feature)
        }
        return result
    }

    /// 直接分析一张已解码的图像（网络存储按需取缩略图后复用这条路径）。
    static func analyze(cgImage input: CGImage) -> Result? {
        guard input.width > 0, input.height > 0,
              let cgImage = materialized(input) else { return nil }
        let recognize = VNRecognizeTextRequest()
        recognize.recognitionLevel = .accurate
        recognize.usesLanguageCorrection = true
        recognize.recognitionLanguages = ["zh-Hans", "en-US"]
        // 不指定 symbologies：默认扫描全部支持的条码（二维码、Code128、EAN、PDF417 等）。
        let barcodes = VNDetectBarcodesRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let pose = VNDetectHumanBodyPoseRequest()
        // 证件 / 票据的翻拍：先把文档区域裁出来，再对裁切图做 OCR，小字命中率明显更高。
        let segmentation = VNDetectDocumentSegmentationRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([barcodes, faces, pose, segmentation])
        } catch {
            return nil
        }

        let crop = documentCrop(from: cgImage, observations: segmentation.results ?? [])
        let ocrHandler = crop.map { VNImageRequestHandler(cgImage: $0, options: [:]) } ?? handler
        // OCR 失败不影响场景标签与特征向量，只是拿不到文字与码内容。
        try? ocrHandler.perform([recognize])

        let size = CGSize(width: cgImage.width, height: cgImage.height)
        var tags: [String] = []
        var feature: Data?
        var legacy: [String] = []
        var usedSigLIP = false

        // 主识别：SigLIP 2 图文模型（中文标准标签 + 语义向量）。
        if let siglip = SigLIPEngine.shared.imageResult(cgImage: cgImage) {
            usedSigLIP = true
            tags.append(contentsOf: siglip.tags)
            feature = siglip.embedding
            // 物体检测补充明确主体（猫 / 狗 / 汽车 / 披萨等），与模型标签去重。
            for title in ObjectDetector.shared.detect(cgImage: cgImage) where !tags.contains(title) {
                tags.append(title)
            }
        } else {
            // 模型不可用（例如旧系统）时回退到 Apple Vision 分类器与特征指纹。
            let classify = VNClassifyImageRequest()
            try? handler.perform([classify])
            legacy = (classify.results ?? [])
                .filter { $0.confidence >= 0.12 }
                .prefix(20)
                .map { $0.identifier.lowercased() }
            let featureRequest = VNGenerateImageFeaturePrintRequest()
            if (try? handler.perform([featureRequest])) != nil,
               let observation = featureRequest.results?.first {
                feature = normalizedVectorData(observation)
            }
        }

        // 人脸 / 人体姿态补构图标签：只在模型没有给出同组标签时补充，避免重复。
        let framing = framingTags(faces: faces.results ?? [],
                                  pose: pose.results ?? [])
        let framingTitles: Set<String> = ["脸部特写", "上半身", "全身"]
        if !tags.contains(where: { framingTitles.contains($0) }) {
            tags.append(contentsOf: framing)
        }

        let codes = barcodes.results ?? []
        if !codes.isEmpty {
            tags.append("条码")
            if codes.contains(where: { $0.symbology == .qr }) { tags.append("二维码") }
        }
        if looksLikeIDPhoto(faces.results ?? [], imageSize: size) {
            tags.append("证件照")
        }

        // 码内容并入文字：搜索发票号码、门票编码、网址时也能命中。
        var lines = (recognize.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        for code in codes.prefix(4) {
            guard let payload = code.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !payload.isEmpty else { continue }
            let prefix = code.symbology == .qr ? "二维码：" : "条码："
            lines.append(prefix + String(payload.prefix(400)))
        }
        let trimmedText = String(lines.joined(separator: "\n").prefix(2000))

        // 发票 / 身份证靠规则校验提升精确度：普通票据、聊天截图里出现「发票」二字不会被算进去。
        if DocumentText.looksLikeInvoice(trimmedText) { tags.append("票据") }
        if DocumentText.looksLikeIDCard(trimmedText) { tags.append("证件") }

        var deduped: [String] = []
        for tag in tags + legacy where !tag.isEmpty && !deduped.contains(tag) {
            deduped.append(tag)
        }
        // 只有真正跑过 SigLIP2 才写版本标记：模型未安装时用 Vision 回退，
        // 结果不写标记，安装模型后这些照片会被重新分析，不会永久停留在旧标签。
        if usedSigLIP {
            deduped.append(PhotoTagCatalog.sentinel)
        }
        return Result(labels: deduped.joined(separator: " "), text: trimmedText, feature: feature)
    }

    /// 构图标签：大脸 → 脸部特写；露出脚踝 → 全身；露出髋部或颈部 → 上半身。
    private static func framingTags(faces: [VNFaceObservation],
                                    pose: [VNHumanBodyPoseObservation]) -> [String] {
        if let face = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }), face.boundingBox.width * face.boundingBox.height >= 0.08 {
            return ["脸部特写"]
        }
        guard let body = pose.first,
              let points = try? body.recognizedPoints(.all) else { return [] }
        func visible(_ joint: VNHumanBodyPoseObservation.JointName, _ threshold: Float = 0.25) -> Bool {
            (points[joint]?.confidence ?? 0) >= threshold
        }
        if visible(.leftAnkle) || visible(.rightAnkle) {
            return ["全身"]
        }
        if visible(.neck) && (visible(.leftHip) || visible(.rightHip)) {
            return ["上半身"]
        }
        return []
    }

    /// 把 CGImage 的像素复制到一块自有位图再交给 Vision。
    /// ImageIO 的缩略图可能仍指向文件映射（系统图库缩略图会被「照片」后台重建 / 截断），
    /// Vision 内部 memmove 读到失效映射就会 SIGBUS（崩溃日志里正是 CIImage initWithCGImage）。
    private static func materialized(_ image: CGImage) -> CGImage? {
        let colorSpace = image.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: image.width,
                                      height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// 文档分割结果里面积最大的四边形；占画面不足 15% 时不裁切，避免把整幅照片当成文档。
    private static func documentCrop(from image: CGImage,
                                     observations: [VNRectangleObservation]) -> CGImage? {
        guard let best = observations.max(by: { boundingArea($0) < boundingArea($1) }),
              boundingArea(best) >= 0.15 else { return nil }
        let corners = [best.topLeft, best.topRight, best.bottomRight, best.bottomLeft]
        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 1
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 1
        let padX = (maxX - minX) * 0.02
        let padY = (maxY - minY) * 0.02
        let x0 = max(0, minX - padX)
        let x1 = min(1, maxX + padX)
        // Vision 坐标原点在左下，CGImage 裁剪坐标原点在左上。
        let y0 = max(0, 1 - maxY - padY)
        let y1 = min(1, 1 - minY + padY)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(x: x0 * width, y: y0 * height,
                          width: (x1 - x0) * width, height: (y1 - y0) * height)
        guard rect.width >= 64, rect.height >= 64 else { return nil }
        return image.cropping(to: rect)
    }

    private static func boundingArea(_ observation: VNRectangleObservation) -> CGFloat {
        let xs = [observation.topLeft.x, observation.topRight.x,
                  observation.bottomLeft.x, observation.bottomRight.x]
        let ys = [observation.topLeft.y, observation.topRight.y,
                  observation.bottomLeft.y, observation.bottomRight.y]
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        return width * height
    }

    /// 证件照启发式：单人脸、脸占比足够大、竖幅或方幅，且人脸大致居中。
    /// Vision 没有人像证件照分类标签，这里只做粗筛，纯色背景的半身人像可能被误判。
    private static func looksLikeIDPhoto(_ faces: [VNFaceObservation], imageSize: CGSize) -> Bool {
        guard faces.count == 1, imageSize.width > 0, imageSize.height > 0 else { return false }
        let ratio = imageSize.width / imageSize.height
        let isPortrait = ratio >= 0.62 && ratio <= 0.82
        let isSquare = ratio >= 0.92 && ratio <= 1.08
        guard isPortrait || isSquare else { return false }
        let box = faces[0].boundingBox
        return box.height >= 0.2 && box.width <= 0.8 && abs(box.midX - 0.5) <= 0.2
    }

    /// 只提取相似检索用的特征向量（比完整分析轻得多，网盘按需对大图列表逐张调用）。
    static func feature(cgImage: CGImage) -> Data? {
        if let embedding = SigLIPEngine.shared.imageEmbedding(cgImage: cgImage) {
            return embedding
        }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }
        return normalizedVectorData(observation)
    }

    /// 把 Vision 特征向量转成归一化后的 Float32 数据，便于直接点积算余弦相似度。
    private static func normalizedVectorData(_ observation: VNFeaturePrintObservation) -> Data? {
        guard observation.elementType == .float else { return nil }
        let count = observation.elementCount
        guard count > 0 else { return nil }
        var values = [Float](repeating: 0, count: count)
        (observation.data as Data).withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Float.self)
            for index in 0..<min(count, source.count) {
                values[index] = source[index]
            }
        }
        var norm: Float = 0
        for value in values { norm += value * value }
        norm = sqrt(norm)
        guard norm > 0 else { return nil }
        for index in values.indices { values[index] /= norm }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
