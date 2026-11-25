import Foundation

/// 本机可用的 OpenAI 兼容推理服务（不内置 GGUF 运行时，先接入用户已有的服务）。
struct LocalRuntimeCandidate: Identifiable, Hashable {
    let baseURL: String
    let models: [String]

    var id: String { baseURL }

    var title: String {
        if baseURL.contains("11434") { return "Ollama" }
        if baseURL.contains("1234") { return "LM Studio" }
        return baseURL
    }
}

enum LocalRuntimeScanner {
    static let defaultEndpoints = [
        "http://127.0.0.1:11434/v1",   // Ollama
        "http://127.0.0.1:1234/v1"     // LM Studio
    ]

    /// 逐个探测本机常见端口；当前配置的地址也会一起探测。
    static func scan(extra baseURL: String? = nil) async -> [LocalRuntimeCandidate] {
        var endpoints = defaultEndpoints
        if let baseURL, !baseURL.isEmpty, !endpoints.contains(baseURL) {
            endpoints.insert(baseURL, at: 0)
        }
        var results: [LocalRuntimeCandidate] = []
        for endpoint in endpoints {
            if let models = await models(at: endpoint), !models.isEmpty {
                results.append(LocalRuntimeCandidate(baseURL: endpoint, models: models))
            }
        }
        return results
    }

    static func models(at baseURL: String) async -> [String]? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return nil }
        return items.compactMap { $0["id"] as? String }.sorted()
    }
}
