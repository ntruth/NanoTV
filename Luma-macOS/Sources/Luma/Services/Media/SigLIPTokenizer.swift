import Foundation

/// SigLIP 2 使用的 Gemma BPE 分词器（256k 词表）。
/// 词表与合并规则在构建时转换成紧凑二进制，运行时只读映射，不解析 33MB JSON。
struct SigLIPTokenizer {
    let padID: Int32
    let eosID: Int32
    let unkID: Int32
    let maxLength: Int

    private let tokens: [String]
    private let ids: [String: Int32]
    /// 合并规则按 FNV-1a 哈希排序，避免在内存里常驻 58 万条字符串对。
    private let merges: [(hash: UInt64, rank: UInt32)]

    init?(directory: URL) {
        let metaURL = directory.appendingPathComponent("tokenizer_meta.json")
        let vocabURL = directory.appendingPathComponent("tokenizer_vocab.bin")
        let mergesURL = directory.appendingPathComponent("tokenizer_merges.bin")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let vocabData = try? Data(contentsOf: vocabURL),
              let mergesData = try? Data(contentsOf: mergesURL) else { return nil }
        self.padID = Int32(meta["pad"] as? Int ?? 0)
        self.eosID = Int32(meta["eos"] as? Int ?? 1)
        self.unkID = Int32(meta["unk"] as? Int ?? 3)
        self.maxLength = meta["maxLength"] as? Int ?? 64

        var tokens: [String] = []
        var ids: [String: Int32] = [:]
        var mergeHashes: [(hash: UInt64, rank: UInt32)] = []
        let vocabOK = vocabData.withUnsafeBytes { raw -> Bool in
            let count = vocabData.count
            guard count >= 8 else { return false }
            let magic = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard magic == 0x4C564F43 else { return false }
            let n = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            var offset = 8
            tokens.reserveCapacity(n)
            ids.reserveCapacity(n)
            for index in 0..<n {
                guard offset + 2 <= count else { return false }
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                offset += 2
                guard offset + length <= count else { return false }
                let bytes = UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + length)])
                let token = String(decoding: bytes, as: UTF8.self)
                offset += length
                tokens.append(token)
                ids[token] = Int32(index)
            }
            return true
        }
        guard vocabOK else { return nil }
        let mergesOK = mergesData.withUnsafeBytes { raw -> Bool in
            let count = mergesData.count
            guard count >= 8 else { return false }
            let magic = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard magic == 0x4C564D47 else { return false }
            let n = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            guard count >= 8 + n * 12 else { return false }
            mergeHashes.reserveCapacity(n)
            var offset = 8
            for _ in 0..<n {
                let hash = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                let rank = raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)
                offset += 12
                mergeHashes.append((hash, rank))
            }
            return true
        }
        guard mergesOK else { return nil }
        self.tokens = tokens
        self.ids = ids
        self.merges = mergeHashes
    }

    /// 分词并补齐到固定长度：末尾追加 `<eos>`，其余用 `<pad>` 填满。
    func encode(_ text: String, maxLength: Int? = nil) -> [Int32] {
        let limit = min(maxLength ?? self.maxLength, self.maxLength)
        var pieces = symbolPieces(text)
        pieces = merge(pieces)
        var result: [Int32] = []
        result.reserveCapacity(limit)
        for piece in pieces {
            if result.count >= limit - 1 { break }
            if let id = ids[piece] {
                result.append(id)
            } else {
                // 极少数未登录字符按 UTF-8 字节回退。
                for byte in piece.utf8 {
                    if result.count >= limit - 1 { break }
                    let fallback = String(format: "<0x%02X>", byte)
                    result.append(ids[fallback] ?? unkID)
                }
            }
        }
        result.append(eosID)
        while result.count < limit { result.append(padID) }
        return result
    }

    // MARK: - BPE

    /// 与官方 normalizer / pre-tokenizer 等价：空格替换为 `▁`，再按字符切分。
    private func symbolPieces(_ text: String) -> [String] {
        var pieces: [String] = []
        pieces.reserveCapacity(text.count)
        for scalar in text.replacingOccurrences(of: " ", with: "▁").unicodeScalars {
            pieces.append(String(scalar))
        }
        return pieces
    }

    private func merge(_ input: [String]) -> [String] {
        guard input.count > 1 else { return input }
        var pieces = input
        while pieces.count > 1 {
            var bestRank = UInt32.max
            var bestIndex = -1
            for index in 0..<(pieces.count - 1) {
                if let rank = mergeRank(pieces[index], pieces[index + 1]), rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { break }
            let left = pieces[bestIndex]
            let right = pieces[bestIndex + 1]
            var merged: [String] = []
            merged.reserveCapacity(pieces.count)
            var index = 0
            while index < pieces.count {
                if index < pieces.count - 1, pieces[index] == left, pieces[index + 1] == right {
                    merged.append(left + right)
                    index += 2
                } else {
                    merged.append(pieces[index])
                    index += 1
                }
            }
            pieces = merged
        }
        return pieces
    }

    private func mergeRank(_ a: String, _ b: String) -> UInt32? {
        let hash = Self.pairHash(a, b)
        var low = 0
        var high = merges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let item = merges[mid]
            if item.hash == hash { return item.rank }
            if item.hash < hash { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    /// 与构建脚本一致的 FNV-1a 64：a 的 UTF-8 字节 + 0x01 + b 的 UTF-8 字节。
    private static func pairHash(_ a: String, _ b: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in a.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        hash ^= 0x01
        hash = hash &* 1099511628211
        for byte in b.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return hash
    }
}
