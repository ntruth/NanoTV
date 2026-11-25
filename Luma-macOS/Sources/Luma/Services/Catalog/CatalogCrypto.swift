import Foundation
import CommonCrypto

/// 封面解密：站点返回的是 AES-128-CBC 密文，
/// 既可能是 Base64 文本（黄果），也可能是原始二进制（91 吃瓜），
/// 解密后再按自定义填充位裁尾、按魔数截断到图片结束标记。
enum CatalogCrypto {
    static func decodeImage(data: Data, key: String?, iv: String?) -> Data? {
        if isImage(data) { return data }
        guard let key, let iv,
              key.utf8.count == kCCKeySizeAES128,
              iv.utf8.count == kCCBlockSizeAES128 else { return nil }

        for cipher in candidates(data) {
            guard cipher.count % kCCBlockSizeAES128 == 0,
                  let plain = decrypt(cipher, key: Data(key.utf8), iv: Data(iv.utf8))
            else { continue }
            let image = trim(plain)
            if isImage(image) { return image }
        }
        return nil
    }

    /// 依次尝试「原始二进制」与「Base64 文本」两种密文形态。
    private static func candidates(_ data: Data) -> [Data] {
        var result: [Data] = [data]
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty,
           let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
           !decoded.isEmpty, decoded != data {
            result.append(decoded)
        }
        return result
    }

    private static func trim(_ plain: Data) -> Data {
        var image = stripPadding(plain)
        if isJPEG(image), let cut = truncate(image, marker: [0xFF, 0xD9]) {
            image = cut
        }
        if isPNG(image), let cut = truncate(image, marker: [0x49, 0x45, 0x4E, 0x44,
                                                            0xAE, 0x42, 0x60, 0x82]) {
            image = cut
        }
        return image
    }

    // MARK: - AES

    private static func decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        let capacity = data.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var moved = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outBuffer in
            data.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(0),
                                keyBuffer.baseAddress, key.count,
                                ivBuffer.baseAddress,
                                dataBuffer.baseAddress, data.count,
                                outBuffer.baseAddress, capacity,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        return output.prefix(moved)
    }

    // MARK: - 图片判型与裁剪

    private static func isImage(_ data: Data) -> Bool {
        isJPEG(data) || isPNG(data) || isWebP(data) || isGIF(data)
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.count > 2 && data[0] == 0xFF && data[1] == 0xD8
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    private static func isWebP(_ data: Data) -> Bool {
        data.count > 12 && data.starts(with: Array("RIFF".utf8))
            && data.subdata(in: 8..<12) == Data("WEBP".utf8)
    }

    private static func isGIF(_ data: Data) -> Bool {
        data.starts(with: Array("GIF8".utf8))
    }

    /// 去掉 PKCS#7 风格的自定义填充（1…16 个重复的填充字节）。
    private static func stripPadding(_ data: Data) -> Data {
        guard let last = data.last, (1...16).contains(Int(last)),
              data.count > Int(last) else { return data }
        let padding = data.suffix(Int(last))
        guard padding.allSatisfy({ $0 == last }) else { return data }
        return data.dropLast(Int(last))
    }

    /// 保留到最后一个结束标记为止，去掉解密块带来的尾部噪声。
    private static func truncate(_ data: Data, marker: [UInt8]) -> Data? {
        guard data.count >= marker.count else { return nil }
        let bytes = [UInt8](data)
        var index = bytes.count - marker.count
        while index >= 0 {
            if Array(bytes[index..<(index + marker.count)]) == marker {
                return Data(bytes[0..<(index + marker.count)])
            }
            index -= 1
        }
        return nil
    }
}
