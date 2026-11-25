import AppKit
import CoreML
import Foundation

/// 本地 SigLIP 2 图文模型：图像打标 + 查询词向量。
/// 图像编码器负责把缩略图映射成 768 维向量，再与预生成的标签向量做余弦匹配；
/// 文本编码器只在你输入搜索词时加载，用来把自然语言扩展成标准标签。
final class SigLIPEngine {
    struct ImageResult {
        let tags: [String]
        /// 归一化后的图像向量（Float32），用于相似照片检索。
        let embedding: Data
    }

    static let shared = SigLIPEngine()

    private let lock = NSLock()
    private var imageLoadAttempted = false
    private var textLoadAttempted = false
    private var imageModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: SigLIPTokenizer?
    private var catalog: PhotoTagCatalog?
    private var tagVectors: [Float] = []
    private var tagVectorCount = 0

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ModelRegistry.isEnabled(.siglip2) else { return false }
        return ensureImageModel() != nil
    }

    /// 设置里启停或重新安装模型后调用：丢弃已加载的编码器，下一次调用重新读盘。
    /// 否则首次加载失败（模型还没下载）会被 `imageLoadAttempted` 永久记住。
    func invalidateModels() {
        lock.lock()
        defer { lock.unlock() }
        imageLoadAttempted = false
        textLoadAttempted = false
        imageModel = nil
        textModel = nil
        tokenizer = nil
        catalog = nil
        tagVectors = []
        tagVectorCount = 0
        PhotoTagCatalog.invalidateShared()
    }

    // MARK: - 图像分析

    /// 返回命中的中文标签与图像向量；模型未启用或不可用时返回 nil，由调用方回退到 Apple Vision。
    func imageResult(cgImage: CGImage) -> ImageResult? {
        lock.lock()
        defer { lock.unlock() }
        guard ModelRegistry.isEnabled(.siglip2) else { return nil }
        guard let data = embeddingLocked(cgImage: cgImage) else { return nil }
        let catalog = ensureCatalog()
        if tagVectors.isEmpty { loadTagVectors() }
        let vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let tags = Self.matchTags(vector,
                                  vectors: tagVectors,
                                  count: tagVectorCount,
                                  catalog: catalog)
        return ImageResult(tags: tags, embedding: data)
    }

    /// 只算图像向量（网盘 / 体检只需要相似检索时比完整打标更轻）。
    func imageEmbedding(cgImage: CGImage) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard ModelRegistry.isEnabled(.siglip2) else { return nil }
        return embeddingLocked(cgImage: cgImage)
    }

    // MARK: - 查询词扩展

    /// 自然语言 → 查询向量（与图像特征同一空间），供跨库检索使用。
    func textEmbedding(for text: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard ModelRegistry.isEnabled(.siglip2) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return textVector(for: trimmed)
    }

    /// 自然语言 → 标签：先保留词表直接命中，再用文本向量找最接近的若干标准标签。
    func expand(query: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard ModelRegistry.isEnabled(.siglip2) else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result = ensureCatalog()?.searchTitles(for: trimmed) ?? []
        // 词表已经给出多个明确标签时，不再让模型扩展引入噪声（例如「宠物」→ 猫 / 狗 / 兔子）。
        if result.count >= 2 { return Array(result.prefix(6)) }
        guard let vector = textVector(for: trimmed),
              let catalog = ensureCatalog(),
              tagVectorCount > 0 else { return Array(result.prefix(6)) }
        var scored: [(title: String, score: Float)] = []
        scored.reserveCapacity(tagVectorCount)
        for index in 0..<tagVectorCount {
            let base = index * catalog.embeddingDim
            guard base + catalog.embeddingDim <= tagVectors.count else { break }
            var dot: Float = 0
            for dimension in 0..<catalog.embeddingDim {
                dot += vector[dimension] * tagVectors[base + dimension]
            }
            scored.append((catalog.tags[index].title, dot))
        }
        scored.sort { $0.score > $1.score }
        var picked: [String] = []
        var previous: Float = 1
        for item in scored.prefix(6) {
            guard item.score >= 0.8 else { break }
            // 相似度出现明显断层时停止，避免「猫」把「老虎 / 兔子」一起带进来。
            if !picked.isEmpty, previous - item.score > 0.035 { break }
            picked.append(item.title)
            previous = item.score
            if picked.count >= 4 { break }
        }
        var seen = Set(result)
        for title in picked where seen.insert(title).inserted { result.append(title) }
        return Array(result.prefix(6))
    }

    /// 把分析结果里的标签按目录顺序整理（供信息面板展示）。
    func canonicalTitles(from labels: Set<String>) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return ensureCatalog()?.canonicalTitles(from: labels) ?? []
    }

    private func embeddingLocked(cgImage: CGImage) -> Data? {
        guard let model = ensureImageModel(),
              let tensor = ImageTensor.make(from: cgImage, size: 256) else { return nil }
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(multiArray: tensor)
            ])
            let output = try model.prediction(from: input)
            guard let array = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
            var vector = Self.floatValues(array)
            guard vector.count >= 32 else { return nil }
            Self.normalize(&vector)
            return vector.withUnsafeBufferPointer { Data(buffer: $0) }
        } catch {
            NSLog("LumaSigLIP: embedding failed %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - 懒加载

    private func ensureImageModel() -> MLModel? {
        if imageLoadAttempted { return imageModel }
        imageLoadAttempted = true
        guard let url = LumaModelResources.directory("SigLIP2/ImageEncoder.mlmodelc") else {
            NSLog("LumaSigLIP: image encoder not found")
            return nil
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        imageModel = try? MLModel(contentsOf: url, configuration: configuration)
        if imageModel == nil { NSLog("LumaSigLIP: image encoder failed to load") }
        return imageModel
    }

    private func ensureTextModel() -> MLModel? {
        if textLoadAttempted { return textModel }
        textLoadAttempted = true
        guard let url = LumaModelResources.directory("SigLIP2/TextEncoder.mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        textModel = try? MLModel(contentsOf: url, configuration: configuration)
        if textModel == nil { NSLog("LumaSigLIP: text encoder failed to load") }
        tokenizer = LumaModelResources.directory("SigLIP2").flatMap { SigLIPTokenizer(directory: $0) }
        return textModel
    }

    private func ensureCatalog() -> PhotoTagCatalog? {
        if catalog == nil {
            catalog = PhotoTagCatalog.shared
            loadTagVectors()
        }
        return catalog
    }

    private func loadTagVectors() {
        guard tagVectors.isEmpty,
              let catalog,
              let url = LumaModelResources.file("SigLIP2/tag_embeddings.bin"),
              let data = try? Data(contentsOf: url) else { return }
        let dimension = catalog.embeddingDim
        let count = data.count / (dimension * 2)
        guard count > 0 else { return }
        var vectors = [Float](repeating: 0, count: count * dimension)
        data.withUnsafeBytes { raw in
            let half = raw.bindMemory(to: UInt16.self)
            for index in 0..<(count * dimension) {
                vectors[index] = Float(Float16(bitPattern: half[index]))
            }
        }
        tagVectors = vectors
        tagVectorCount = min(count, catalog.tags.count)
    }

    private func textVector(for text: String) -> [Float]? {
        guard let model = ensureTextModel(), let tokenizer else { return nil }
        do {
            let tokens = tokenizer.encode(text)
            let array = try MLMultiArray(shape: [1, NSNumber(value: tokenizer.maxLength)], dataType: .int32)
            let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: tokenizer.maxLength)
            for index in 0..<tokenizer.maxLength {
                pointer[index] = index < tokens.count ? tokens[index] : tokenizer.padID
            }
            let input = try MLDictionaryFeatureProvider(dictionary: ["tokens": MLFeatureValue(multiArray: array)])
            let output = try model.prediction(from: input)
            guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
            var vector = Self.floatValues(embedding)
            guard !vector.isEmpty else { return nil }
            Self.normalize(&vector)
            return vector
        } catch {
            NSLog("LumaSigLIP: text prediction failed %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - 工具

    private static func matchTags(_ vector: [Float],
                                  vectors: [Float],
                                  count: Int,
                                  catalog: PhotoTagCatalog?) -> [String] {
        guard let catalog, count > 0, vector.count >= catalog.embeddingDim else { return [] }
        let dimension = catalog.embeddingDim
        var scored: [(index: Int, score: Float)] = []
        scored.reserveCapacity(count)
        for index in 0..<count {
            let base = index * dimension
            guard base + dimension <= vectors.count else { break }
            var dot: Float = 0
            for offset in 0..<dimension {
                dot += vector[offset] * vectors[base + offset]
            }
            let tag = catalog.tags[index]
            let threshold = Float(tag.threshold > 0 ? tag.threshold : catalog.defaultThreshold)
            if dot >= threshold { scored.append((index, dot)) }
        }
        scored.sort { $0.score > $1.score }
        var used: [String: Int] = [:]
        var result: [String] = []
        for item in scored {
            let tag = catalog.tags[item.index]
            let limit = catalog.groupLimits[tag.group] ?? 99
            let current = used[tag.group, default: 0]
            if current >= limit { continue }
            used[tag.group] = current + 1
            result.append(tag.title)
            if result.count >= 12 { break }
        }
        return result
    }

    private static func floatValues(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        guard count > 0 else { return [] }
        switch array.dataType {
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: UInt16.self, capacity: count)
            var result = [Float](repeating: 0, count: count)
            for index in 0..<count { result[index] = Float(Float16(bitPattern: pointer[index])) }
            return result
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            return (0..<count).map { Float(pointer[$0]) }
        default:
            return (0..<count).map { Float(truncating: array[$0]) }
        }
    }

    private static func normalize(_ vector: inout [Float]) {
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum > 0 else { return }
        let scale = 1 / sqrt(sum)
        for index in vector.indices { vector[index] *= scale }
    }

}

/// 把 CGImage 转成模型需要的 NCHW 浮点张量（RGB，0…255）。
/// 不走 Core ML 的 ImageType 通道：该通道会把像素归一化到 0…1，
/// 而模型图内部已经按 0…255 做了 (x/127.5-1) 预处理，会得到近乎全黑的输入。
enum ImageTensor {
    static func make(from image: CGImage, size: Int) -> MLMultiArray? {
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer,
              let array = try? MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
                                            dataType: .float32) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                      width: size,
                                      height: size,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue),
              let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.bindMemory(to: UInt8.self,
                                                                             capacity: size * size * 4) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let plane = size * size
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: plane * 3)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<size {
            for x in 0..<size {
                let source = y * stride + x * 4
                let target = y * size + x
                pointer[target] = Float(base[source + 2])
                pointer[plane + target] = Float(base[source + 1])
                pointer[plane * 2 + target] = Float(base[source])
            }
        }
        return array
    }
}
