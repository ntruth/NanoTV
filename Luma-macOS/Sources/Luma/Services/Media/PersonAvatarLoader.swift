import AppKit
import ImageIO
import LumaCore

/// 人物 / 宠物头像的取图请求：优先官方裁切图；缺失时按关键人脸几何从
/// 关键照片现算脸部特写（与官方「照片」的人物头像口径一致）；再退回整张缩略图。
///
/// 视图层只能在 `.task` 里异步取用——解码放进后台，主线程 body 里不再做
/// 图片解码或按 ID 查库（大图库里这两件事都会让头像列表滚动时掉帧）。
struct PersonAvatarRequest: Hashable {
    let cacheKey: String
    let cropData: Data?
    let fallbackPhotoID: UUID?
    /// 关键人脸几何（0-1 归一化：cx 相对图宽、cy 相对图高且原点在左下、size 相对图对角线）。
    /// 官方图库里绝大多数人物没有现成裁切 BLOB，「照片」App 的头像就是按这组几何现算的。
    let faceGeometry: (centerX: Double, centerY: Double, size: Double)?
    /// 解码边长（像素，已收敛到固定档位）。
    let maxPixel: CGFloat

    init(identity: String, cropData: Data?, fallbackPhotoID: UUID?,
         faceGeometry: (centerX: Double, centerY: Double, size: Double)? = nil, size: CGFloat) {
        let bucket = ThumbnailSizing.bucket(for: size * ThumbnailPurpose.scale)
        let geometryKey = faceGeometry
            .map { String(format: "%.4f|%.4f|%.4f", $0.centerX, $0.centerY, $0.size) } ?? "-"
        cacheKey = "\(identity)|\(bucket)|\(cropData?.count ?? 0)|\(fallbackPhotoID?.uuidString ?? "-")|\(geometryKey)"
        self.cropData = cropData
        self.fallbackPhotoID = fallbackPhotoID
        self.faceGeometry = faceGeometry
        maxPixel = CGFloat(bucket)
    }

    static func == (lhs: PersonAvatarRequest, rhs: PersonAvatarRequest) -> Bool {
        lhs.cacheKey == rhs.cacheKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(cacheKey)
    }
}

/// 脸部特写相对人脸框每边外扩 0.35（脸框 ×1.7），与本地聚类 `FaceClustering.cropFace`
/// 的裁切观感一致，保证系统人物与本地图库人物的头像风格统一。
private let faceCropExpansion: Double = 1.7

/// 人物头像解码与缓存：同一人物按档位只解码一次，之后直接命中内存缓存。
@MainActor
enum PersonAvatarLoader {
    private static let cache = MemoryImageCache(totalCostLimit: 64 * 1024 * 1024)

    static func request(for person: SystemPersonInfo, size: CGFloat) -> PersonAvatarRequest {
        let geometry: (centerX: Double, centerY: Double, size: Double)?
        if let cx = person.faceCenterX, let cy = person.faceCenterY, let faceSize = person.faceSize {
            geometry = (cx, cy, faceSize)
        } else {
            geometry = nil
        }
        return PersonAvatarRequest(identity: "system-\(person.id)",
                                    cropData: person.cropData,
                                    fallbackPhotoID: person.keyAssetID ?? person.assetIDs.first,
                                    faceGeometry: geometry,
                                    size: size)
    }

    static func request(for person: LocalPerson, size: CGFloat) -> PersonAvatarRequest {
        PersonAvatarRequest(identity: "local-\(person.id.uuidString)",
                            cropData: person.coverImageData,
                            fallbackPhotoID: person.assetIDs.first,
                            size: size)
    }

    static func request(for companion: PersonInsight.Companion, size: CGFloat) -> PersonAvatarRequest {
        PersonAvatarRequest(identity: "companion-\(companion.id)",
                            cropData: companion.coverData,
                            fallbackPhotoID: companion.coverPhotoID,
                            size: size)
    }

    static func cached(_ request: PersonAvatarRequest) -> NSImage? {
        cache.object(forKey: request.cacheKey as NSString)
    }

    static func load(_ request: PersonAvatarRequest, store: LibraryStore) async -> NSImage? {
        if let cached = cached(request) { return cached }

        var image: NSImage?
        if let data = request.cropData {
            let maxPixel = request.maxPixel
            image = await Task.detached(priority: .userInitiated) {
                decode(data: data, maxPixel: maxPixel)
            }.value
        }
        // 裁切图缺失或损坏时退回关键照片：有关键人脸几何时按官方「照片」的
        // 口径裁出脸部特写，没有几何才退回整张缩略图。
        if image == nil, let id = request.fallbackPhotoID, let photo = store.anyPhoto(id: id) {
            if photo.isCloud {
                // 网盘人物：直接走云端缩略图，与网格 / 人物卡片使用同一份缓存。
                image = await store.cloudThumbnail(for: photo)
            } else {
                let face = request.faceGeometry
                let maxPixel = request.maxPixel
                image = await Task.detached(priority: .utility) {
                    // 脸部特写只占照片的一小块，直接用头像档位解码会糊：
                    // 按几何反推「裁切边长 ≥ 显示档位」所需的解码长边。
                    let neededPixel: CGFloat = face.map { geometry in
                        let needed = Double(maxPixel)
                            / (faceCropExpansion * max(geometry.size, 0.01) * 1.1)
                        return CGFloat(min(needed, 2600))
                    } ?? maxPixel
                    // 网格缩略图长边最多 1200px，小脸（约四成人物）裁出的特写不够显示档位，
                    // 这类情况直接从原图解码；视频或原图不可用时退回缩略图。
                    var source = neededPixel > 1200
                        ? ImageLoader.displayImage(for: photo, maxPixel: neededPixel)
                        : nil
                    if source == nil {
                        source = ImageLoader.gridThumbnail(for: photo, maxPixel: min(neededPixel, 1024))
                    }
                    guard let thumbnail = source else { return nil }
                    guard let face else { return thumbnail }
                    return faceCropped(thumbnail, face: face) ?? thumbnail
                }.value
            }
        }

        if let image {
            let rep = image.representations.first
            let pixels = (rep?.pixelsWide ?? 0) * (rep?.pixelsHigh ?? 0)
            cache.setObject(image, forKey: request.cacheKey as NSString, cost: max(1, pixels * 4))
        }
        return image
    }

    nonisolated private static func decode(data: Data, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// 按官方几何从缩略图裁出脸部特写：
    /// 中心 = (cx×宽, (1−cy)×高)（官方 Y 原点在左下，转为左上原点），
    /// 边长 = size×√(宽²+高²) 再整体 ×1.7；越界的边按图像边界截断。
    nonisolated private static func faceCropped(_ image: NSImage,
                                                face: (centerX: Double, centerY: Double, size: Double)) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let side = CGFloat(face.size) * sqrt(width * width + height * height) * CGFloat(faceCropExpansion)
        let centerX = CGFloat(face.centerX) * width
        let centerY = (1 - CGFloat(face.centerY)) * height
        // 贴边人物（约一成）的裁切框会越界，而 cropping 对超出右 / 下边界的矩形直接返回 nil，
        // 这里先夹到图像范围内，保证仍能裁出脸部特写（非正方形时视图层 scaledToFill 自行填满）。
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let rect = CGRect(x: centerX - side / 2, y: centerY - side / 2,
                          width: side, height: side).integral.intersection(bounds)
        guard !rect.isEmpty,
              let cropped = cgImage.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}
