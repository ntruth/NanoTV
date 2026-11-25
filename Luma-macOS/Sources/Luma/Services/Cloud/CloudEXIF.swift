import Foundation
import AppKit
import CoreGraphics

/// 网盘照片的 EXIF / GPS 元数据。
///
/// 网盘文件同样带有 EXIF（拍摄时间、相机、镜头、曝光参数、GPS），
/// 只是需要用 Range 请求读取文件头部（WebDAV / 官方网盘）或直接读挂载文件（SMB）。
/// 这里只解析元数据，不下载原图，也不写回网盘。
struct CloudPhotoEXIF: Codable {
    var capturedAt: Date?
    var make: String?
    var model: String?
    var lens: String?
    var iso: String?
    var aperture: String?
    var shutterSpeed: String?
    var focalLength: String?
    var latitude: Double?
    var longitude: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?

    var isEmpty: Bool {
        capturedAt == nil && make == nil && model == nil && lens == nil
            && iso == nil && aperture == nil && shutterSpeed == nil && focalLength == nil
            && latitude == nil && longitude == nil
    }
}

enum CloudEXIF {
    /// 头部探测区间：EXIF（APP1）与 HEIC 的 meta box 都在文件最前面。
    static let probeRange = 0...262_143

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    /// 从本地文件（SMB 挂载点）读取元数据。只读文件头，不解码整张图。
    static func metadata(fromFile url: URL) -> CloudPhotoEXIF? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: probeRange.upperBound + 1)) ?? Data()
        guard !data.isEmpty else { return nil }
        return metadata(from: data)
    }

    /// 从文件头部字节解析；JPEG 用 ImageIO，解析不到时回退到手写 EXIF 解析（截断数据也能读）。
    static func metadata(from data: Data) -> CloudPhotoEXIF? {
        guard !data.isEmpty else { return nil }
        var result = CloudPhotoEXIF()
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            result = metadata(fromProperties: props)
        }
        if result.isEmpty || result.pixelWidth == nil {
            if let fallback = JPEGEXIFParser.parse(data) {
                result.merge(fallback)
            }
        }
        return result.isEmpty && result.pixelWidth == nil ? nil : result
    }

    static func metadata(fromProperties props: [CFString: Any]) -> CloudPhotoEXIF {
        var result = CloudPhotoEXIF()
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        if let width = props[kCGImagePropertyPixelWidth] as? Int, width > 0 {
            result.pixelWidth = width
        }
        if let height = props[kCGImagePropertyPixelHeight] as? Int, height > 0 {
            result.pixelHeight = height
        }

        let dateKeys = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized]
        for key in dateKeys {
            if let string = exif?[key] as? String, let date = dateFormatter.date(from: string) {
                result.capturedAt = date
                break
            }
        }

        result.make = trimmed(tiff?[kCGImagePropertyTIFFMake] as? String)
        result.model = trimmed(tiff?[kCGImagePropertyTIFFModel] as? String)
        result.lens = trimmed(exif?[kCGImagePropertyExifLensModel] as? String)

        if let focal = exif?[kCGImagePropertyExifFocalLength] as? Double, focal > 0 {
            result.focalLength = String(format: "%.0f mm", focal)
        }
        if let fnumber = exif?[kCGImagePropertyExifFNumber] as? Double, fnumber > 0 {
            result.aperture = String(format: "ƒ/%.1f", fnumber)
        }
        if let exposure = exif?[kCGImagePropertyExifExposureTime] as? Double {
            if exposure > 0, exposure < 1 {
                result.shutterSpeed = String(format: "1/%d 秒", Int((1 / exposure).rounded()))
            } else if exposure >= 1 {
                result.shutterSpeed = String(format: "%.1f 秒", exposure)
            }
        }
        if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArray.first {
            result.iso = "\(first)"
        } else if let iso = exif?[kCGImagePropertyExifISOSpeedRatings] as? Int {
            result.iso = "\(iso)"
        }

        if let gps,
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            let longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            if CoordinateValidator.isValid(latitude: latitude, longitude: longitude) {
                result.latitude = latitude
                result.longitude = longitude
            }
        }
        return result
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension CloudPhotoEXIF {
    /// 合并两份解析结果，保留已有的非空字段。
    mutating func merge(_ other: CloudPhotoEXIF) {
        capturedAt = capturedAt ?? other.capturedAt
        make = make ?? other.make
        model = model ?? other.model
        lens = lens ?? other.lens
        iso = iso ?? other.iso
        aperture = aperture ?? other.aperture
        shutterSpeed = shutterSpeed ?? other.shutterSpeed
        focalLength = focalLength ?? other.focalLength
        latitude = latitude ?? other.latitude
        longitude = longitude ?? other.longitude
        if pixelWidth == nil { pixelWidth = other.pixelWidth }
        if pixelHeight == nil { pixelHeight = other.pixelHeight }
    }
}

// MARK: - JPEG EXIF 回退解析

/// 直接读取 JPEG 的 APP1 / TIFF 结构，支持只拿到文件头部（Range 请求）的情况。
private enum JPEGEXIFParser {
    static func parse(_ data: Data) -> CloudPhotoEXIF? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var index = 2
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else {
                index += 1
                continue
            }
            let marker = bytes[index + 1]
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                index += 2
                continue
            }
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2, index + 2 + length <= bytes.count else { break }
            let payloadStart = index + 4
            let payloadEnd = index + 2 + length
            if marker == 0xE1, payloadEnd - payloadStart > 6,
               bytes[payloadStart] == 0x45, bytes[payloadStart + 1] == 0x78,
               bytes[payloadStart + 2] == 0x69, bytes[payloadStart + 3] == 0x66 {
                var result = CloudPhotoEXIF()
                TIFFParser.parse(Array(bytes[(payloadStart + 6)..<payloadEnd]), into: &result)
                if !result.isEmpty { return result }
            }
            index = payloadEnd
        }
        return nil
    }
}

/// 最小 TIFF / IFD 解析：只取 App 需要的相机、曝光与 GPS 字段。
private enum TIFFParser {
    private static func u16(_ bytes: [UInt8], _ offset: Int, _ little: Bool) -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return little
            ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            : Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int, _ little: Bool) -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        if little {
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    private struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        let valueOffset: Int
    }

    private static func entries(_ bytes: [UInt8], ifd offset: Int, little: Bool) -> [Entry] {
        let count = u16(bytes, offset, little)
        guard count > 0, count < 512 else { return [] }
        var result: [Entry] = []
        for index in 0..<count {
            let base = offset + 2 + index * 12
            guard base + 12 <= bytes.count else { break }
            result.append(Entry(tag: u16(bytes, base, little),
                                type: u16(bytes, base + 2, little),
                                count: u32(bytes, base + 4, little),
                                valueOffset: u32(bytes, base + 8, little)))
        }
        return result
    }

    /// count <= 4 时值直接内联在 12 字节条目的值字段（最后 4 字节）里。
    private static func inlineBytes(_ entry: Entry, little: Bool) -> [UInt8] {
        let value = entry.valueOffset
        let raw = [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                   UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        return little ? raw : Array(raw.reversed())
    }

    private static func ascii(_ bytes: [UInt8], _ entry: Entry, little: Bool) -> String? {
        let slice: ArraySlice<UInt8>
        if entry.count <= 4 {
            slice = inlineBytes(entry, little: little).prefix(max(1, entry.count))[...]
        } else {
            let start = entry.valueOffset
            guard start >= 0, start < bytes.count else { return nil }
            let end = min(bytes.count, start + max(1, entry.count))
            slice = bytes[start..<end]
        }
        let value = slice.prefix { $0 != 0 }
        guard !value.isEmpty else { return nil }
        let text = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func rational(_ bytes: [UInt8], at offset: Int, little: Bool) -> Double? {
        let numerator = u32(bytes, offset, little)
        let denominator = u32(bytes, offset + 4, little)
        guard denominator != 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    private static func double(_ bytes: [UInt8], _ entry: Entry, little: Bool) -> Double? {
        switch entry.type {
        case 5: // RATIONAL
            return rational(bytes, at: entry.valueOffset, little: little)
        case 3: // SHORT
            return Double(integer(bytes, entry, little: little) ?? 0)
        case 4: // LONG
            return Double(entry.valueOffset)
        default:
            return nil
        }
    }

    private static func integer(_ bytes: [UInt8], _ entry: Entry, little: Bool) -> Int? {
        switch entry.type {
        case 3:
            if entry.count <= 2 {
                let raw = inlineBytes(entry, little: little)
                return little
                    ? Int(raw[1]) << 8 | Int(raw[0])
                    : Int(raw[0]) << 8 | Int(raw[1])
            }
            return u16(bytes, entry.valueOffset, little)
        case 4:
            return entry.valueOffset
        default:
            return nil
        }
    }

    static func parse(_ tiff: [UInt8], into result: inout CloudPhotoEXIF) {
        guard tiff.count > 8 else { return }
        let little: Bool
        if tiff[0] == 0x49, tiff[1] == 0x49 {
            little = true
        } else if tiff[0] == 0x4D, tiff[1] == 0x4D {
            little = false
        } else {
            return
        }
        guard u16(tiff, 2, little) == 42 else { return }
        let ifd0 = u32(tiff, 4, little)
        guard ifd0 >= 8, ifd0 < tiff.count else { return }

        let first = entries(tiff, ifd: ifd0, little: little)
        var exifOffset = 0
        var gpsOffset = 0
        for entry in first {
            switch entry.tag {
            case 0x010F: result.make = result.make ?? ascii(tiff, entry, little: little)
            case 0x0110: result.model = result.model ?? ascii(tiff, entry, little: little)
            case 0x8769: exifOffset = integer(tiff, entry, little: little) ?? 0
            case 0x8825: gpsOffset = integer(tiff, entry, little: little) ?? 0
            default: break
            }
        }

        if exifOffset > 0, exifOffset < tiff.count {
            for entry in entries(tiff, ifd: exifOffset, little: little) {
                switch entry.tag {
                case 0x9003:
                    if let text = ascii(tiff, entry, little: little) {
                        let formatter = DateFormatter()
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                        result.capturedAt = result.capturedAt ?? formatter.date(from: text)
                    }
                case 0x920A:
                    if result.focalLength == nil, let value = double(tiff, entry, little: little), value > 0 {
                        result.focalLength = String(format: "%.0f mm", value)
                    }
                case 0x829D:
                    if result.aperture == nil, let value = double(tiff, entry, little: little), value > 0 {
                        result.aperture = String(format: "ƒ/%.1f", value)
                    }
                case 0x829A:
                    if result.shutterSpeed == nil, let value = double(tiff, entry, little: little), value > 0 {
                        if value < 1 {
                            result.shutterSpeed = String(format: "1/%d 秒", Int((1 / value).rounded()))
                        } else {
                            result.shutterSpeed = String(format: "%.1f 秒", value)
                        }
                    }
                case 0x8827:
                    if result.iso == nil, let value = integer(tiff, entry, little: little) {
                        result.iso = "\(value)"
                    }
                case 0xA434:
                    result.lens = result.lens ?? ascii(tiff, entry, little: little)
                default:
                    break
                }
            }
        }

        if gpsOffset > 0, gpsOffset < tiff.count {
            var latitude: Double?
            var longitude: Double?
            var latitudeRef: String?
            var longitudeRef: String?
            for entry in entries(tiff, ifd: gpsOffset, little: little) {
                switch entry.tag {
                case 0x0001: latitudeRef = ascii(tiff, entry, little: little)
                case 0x0002:
                    latitude = coordinate(tiff, entry, little: little)
                case 0x0003: longitudeRef = ascii(tiff, entry, little: little)
                case 0x0004:
                    longitude = coordinate(tiff, entry, little: little)
                default:
                    break
                }
            }
            if let latitude, let longitude {
                let lat = latitudeRef == "S" ? -latitude : latitude
                let lon = longitudeRef == "W" ? -longitude : longitude
                if CoordinateValidator.isValid(latitude: lat, longitude: lon) {
                    result.latitude = result.latitude ?? lat
                    result.longitude = result.longitude ?? lon
                }
            }
        }
    }

    /// GPS 坐标是 3 个 RATIONAL（度 / 分 / 秒）。
    private static func coordinate(_ bytes: [UInt8], _ entry: Entry, little: Bool) -> Double? {
        guard entry.type == 5, entry.count >= 3 else { return nil }
        let start = entry.valueOffset
        guard start > 0 else { return nil }
        let degrees = rational(bytes, at: start, little: little) ?? 0
        let minutes = rational(bytes, at: start + 8, little: little) ?? 0
        let seconds = rational(bytes, at: start + 16, little: little) ?? 0
        let value = degrees + minutes / 60 + seconds / 3600
        return value > 0 ? value : nil
    }
}
