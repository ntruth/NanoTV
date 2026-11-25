import Foundation
import AppKit
import Vision
import CoreGraphics

/// 本地图库的人物聚类结果（端侧 Vision 分析，不上传任何照片）。
struct LocalPerson: Identifiable, Hashable {
    var id: UUID
    var name: String
    var assetIDs: [UUID]
    var coverImageData: Data?
    var faceCount: Int
    var centroid: [Float]

    /// 聚类生成时默认叫「人物 N」，用户没改过名就视为未命名。
    var isUnnamed: Bool {
        name.hasPrefix("人物 ") && Int(name.dropFirst(3)) != nil
    }
}

struct FaceClusterProgress {
    var processed: Int
    var total: Int
    var faces: Int
    var people: Int

    var fraction: Double {
        total > 0 ? min(1, Double(processed) / Double(total)) : 0
    }
}

/// 基于 Vision 的端侧人脸检测与特征聚类。
enum FaceClusterEngine {
    struct FaceSample {
        let assetID: UUID
        let vector: [Float]
        let cover: Data?
        let quality: CGFloat
    }

    /// 分析单张照片中的所有人脸。
    static func analyze(photo: PhotoItem) -> [FaceSample] {
        guard !photo.isVideo, let thumbnail = ImageLoader.thumbnail(for: photo) else { return [] }
        guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        return analyze(cgImage: cgImage, assetID: photo.id)
    }

    /// 分析任意已解码图像（网盘缩略图也走同一条端侧管线）。
    static func analyze(cgImage: CGImage, assetID: UUID) -> [FaceSample] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let faces = (request.results ?? []).sorted {
            $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
        }
        var samples: [FaceSample] = []
        for face in faces.prefix(4) {
            let area = face.boundingBox.width * face.boundingBox.height
            guard area > 0.008 else { continue }
            guard let crop = cropFace(cgImage, boundingBox: face.boundingBox),
                  let vector = featurePrint(cgImage: crop) else { continue }
            samples.append(FaceSample(assetID: assetID,
                                      vector: vector,
                                      cover: jpegData(crop, maxSide: 180),
                                      quality: area))
        }
        return samples
    }

    /// 将一张人脸的向量并入已有聚类；相似度不足时新建一个聚类。
    static func assign(_ sample: FaceSample, to people: inout [LocalPerson], threshold: Float = 0.60) {
        var bestIndex: Int?
        var bestScore: Float = -1
        for index in people.indices where !people[index].centroid.isEmpty {
            let score = dot(people[index].centroid, sample.vector)
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        if let index = bestIndex, bestScore >= threshold {
            var person = people[index]
            let weight = Float(max(1, person.faceCount))
            var centroid = [Float](repeating: 0, count: sample.vector.count)
            let count = min(centroid.count, person.centroid.count)
            for i in 0..<count {
                centroid[i] = person.centroid[i] * weight + sample.vector[i]
            }
            person.centroid = normalize(centroid)
            person.faceCount += 1
            if !person.assetIDs.contains(sample.assetID) {
                person.assetIDs.append(sample.assetID)
                if person.coverImageData == nil, let cover = sample.cover {
                    person.coverImageData = cover
                }
            }
            people[index] = person
        } else {
            let person = LocalPerson(id: UUID(),
                                     name: "人物 \(people.count + 1)",
                                     assetIDs: [sample.assetID],
                                     coverImageData: sample.cover,
                                     faceCount: 1,
                                     centroid: sample.vector)
            people.append(person)
        }
    }

    /// 过滤掉样本过少的聚类，降低误识别。
    static func refined(_ people: [LocalPerson], minimumFaces: Int = 3) -> [LocalPerson] {
        people
            .filter { $0.faceCount >= minimumFaces }
            .sorted {
                if $0.faceCount != $1.faceCount { return $0.faceCount > $1.faceCount }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    // MARK: - Vision

    private static func cropFace(_ image: CGImage, boundingBox: CGRect) -> CGImage? {
        let padding: CGFloat = 0.35
        var box = boundingBox
        box = box.insetBy(dx: -box.width * padding, dy: -box.height * padding)
        box = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard box.width > 0.02, box.height > 0.02 else { return nil }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(x: box.minX * width,
                          y: (1 - box.maxY) * height,
                          width: box.width * width,
                          height: box.height * height).integral
        return image.cropping(to: rect)
    }

    private static func featurePrint(cgImage: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNFeaturePrintObservation,
              observation.elementType == .float,
              observation.elementCount > 0 else { return nil }

        let count = observation.elementCount
        var vector = [Float](repeating: 0, count: count)
        vector.withUnsafeMutableBytes { buffer in
            observation.data.copyBytes(to: buffer, count: min(buffer.count, observation.data.count))
        }
        return normalize(vector)
    }

    private static func jpegData(_ image: CGImage, maxSide: CGFloat) -> Data? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxSide / max(width, height))
        if scale >= 1 {
            return NSBitmapImageRep(cgImage: image)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        }
        let newWidth = max(1, Int(width * scale))
        let newHeight = max(1, Int(height * scale))
        guard let context = CGContext(data: nil,
                                      width: newWidth,
                                      height: newHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    // MARK: - 向量运算

    private static func normalize(_ vector: [Float]) -> [Float] {
        var result = vector
        var sum: Float = 0
        for value in result {
            sum += value * value
        }
        let length = sqrt(sum)
        guard length > 0.0001 else { return result }
        for index in result.indices {
            result[index] /= length
        }
        return result
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let count = min(lhs.count, rhs.count)
        var sum: Float = 0
        for index in 0..<count {
            sum += lhs[index] * rhs[index]
        }
        return sum
    }
}
