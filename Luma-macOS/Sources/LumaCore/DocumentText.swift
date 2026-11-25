import Foundation

/// 票据 / 证件的纯文本判定：只处理 OCR 文本，不依赖 Vision 与图像，便于在命令行断言。
public enum DocumentText {
    /// 18 位身份证号的加权因子与校验码表（GB 11643-1999）。
    private static let idWeights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    private static let idCheckCodes: [Character] = ["1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2"]

    /// 发票的强特征词：至少命中一个且文本含「发票」，或直接命中两个。
    private static let invoiceStrongWords = [
        "发票代码", "发票号码", "价税合计", "开票日期", "增值税", "电子发票",
        "纳税人识别号", "校验码", "销方", "购方"
    ]

    /// 18 位中国居民身份证号：出生日期合法且校验位正确。
    public static func isValidChineseID(_ value: String) -> Bool {
        let text = normalized(value)
        guard text.count == 18 else { return false }
        let chars = Array(text)
        let body = chars.prefix(17)
        guard body.allSatisfy({ $0.isNumber }) else { return false }
        guard let year = Int(String(chars[6..<10])), (1900...2100).contains(year),
              let month = Int(String(chars[10..<12])), (1...12).contains(month),
              let day = Int(String(chars[12..<14])), (1...31).contains(day) else { return false }
        var sum = 0
        for (index, char) in body.enumerated() {
            guard let digit = char.wholeNumberValue else { return false }
            sum += digit * idWeights[index]
        }
        return Character(chars[17].uppercased()) == idCheckCodes[sum % 11]
    }

    /// 身份证：命中合法 18 位号码，或出现只有身份证才会印的字段名。
    public static func looksLikeIDCard(_ text: String) -> Bool {
        let value = normalized(text)
        guard !value.isEmpty else { return false }
        if value.contains("公民身份号码") || value.contains("居民身份证") { return true }
        return containsValidIDNumber(value)
    }

    /// 发票：命中强特征词组合，避免「门票」「收据」这类普通票据被误判。
    public static func looksLikeInvoice(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let hits = invoiceStrongWords.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
        if text.contains("发票") && hits >= 1 { return true }
        return hits >= 2
    }

    private static func containsValidIDNumber(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count >= 18 else { return false }
        for start in 0...(chars.count - 18) where isValidChineseID(String(chars[start..<(start + 18)])) {
            return true
        }
        return false
    }

    /// 全角数字 / 字母转 ASCII：OCR 偶尔把身份证号里的数字识别成全角。
    private static func normalized(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            if (0xFF10...0xFF19).contains(scalar.value) || (0xFF21...0xFF3A).contains(scalar.value)
                || (0xFF41...0xFF5A).contains(scalar.value),
               let ascii = UnicodeScalar(scalar.value - 0xFEE0) {
                return Character(ascii)
            }
            return Character(scalar)
        })
    }
}
