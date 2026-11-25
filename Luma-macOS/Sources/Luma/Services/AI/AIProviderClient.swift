import Foundation

/// 发给模型的一条消息：
/// - role = user / system：text 为正文，images 为 data URL；
/// - role = assistant：text 为正文字，toolCalls 非空时附带工具调用；
/// - role = tool：text 为工具结果，toolCallID 对应被调用的工具。
struct AIRequestMessage {
    var role: String
    var text: String
    var images: [String] = []
    var toolCalls: [AIToolCall]?
    var toolCallID: String?
}

/// OpenAI 兼容的 chat/completions 客户端：DeepSeek / Kimi / GLM / 通义千问 / 豆包 / OpenAI / 自定义。
enum AIProviderClient {
    static func complete(config: AIConfig,
                         apiKey: String,
                         messages: [AIRequestMessage],
                         tools: [AIRequestTool] = []) async throws -> AICompletion {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // 本地运行时（Ollama / LM Studio）不校验 API Key。
        if config.provider.requiresAPIKey, key.isEmpty { throw AIError.missingKey }
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AIError.server("请先在设置 › 助手中填写模型名称")
        }
        guard let url = endpointURL(for: config.baseURL) else { throw AIError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(encode),
            "temperature": 0.2,
            "max_tokens": config.maxTokens,
            "stream": false
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters
                    ]
                ]
            }
            body["tool_choice"] = "auto"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw AIError.cancelled
            }
            throw AIError.server("网络请求失败：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            throw httpError(status: http.statusCode, data: data)
        }
        return try parseCompletion(from: data)
    }

    private static func encode(_ message: AIRequestMessage) -> [String: Any] {
        var payload: [String: Any] = ["role": message.role]

        if message.role == "tool" {
            payload["content"] = message.text
            payload["tool_call_id"] = message.toolCallID ?? ""
            return payload
        }

        if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            payload["content"] = message.text.isEmpty ? NSNull() : message.text
            payload["tool_calls"] = toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments
                    ]
                ]
            }
            return payload
        }

        if message.images.isEmpty {
            payload["content"] = message.text
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": message.text]]
            for image in message.images {
                parts.append(["type": "image_url", "image_url": ["url": image]])
            }
            payload["content"] = parts
        }
        return payload
    }

    private static func endpointURL(for baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        let endpoint = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private static func httpError(status: Int, data: Data) -> AIError {
        let message = serverMessage(from: data)
        switch status {
        case 401, 403:
            return .unauthorized
        case 429:
            return .rateLimited
        default:
            return .server(message ?? "请求失败（HTTP \(status)）")
        }
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8).map { String($0.prefix(300)) }
        }
        if let error = root["error"] as? [String: Any] {
            return error["message"] as? String
        }
        if let message = root["message"] as? String {
            return message
        }
        return nil
    }

    private static func parseCompletion(from data: Data) throws -> AICompletion {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIError.badResponse
        }

        var toolCalls: [AIToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                guard let id = raw["id"] as? String,
                      let function = raw["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let arguments: String
                if let string = function["arguments"] as? String {
                    arguments = string
                } else if let object = function["arguments"],
                          let argumentData = try? JSONSerialization.data(withJSONObject: object),
                          let string = String(data: argumentData, encoding: .utf8) {
                    arguments = string
                } else {
                    arguments = "{}"
                }
                toolCalls.append(AIToolCall(id: id, name: name, arguments: arguments))
            }
        }

        let content = parseContent(from: message)
        guard !content.isEmpty || !toolCalls.isEmpty else { throw AIError.badResponse }
        return AICompletion(content: content, toolCalls: toolCalls)
    }

    private static func parseContent(from message: [String: Any]) -> String {
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 少数兼容实现会把 content 拆成多段。
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        if let reasoning = message["reasoning_content"] as? String {
            return reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
