import Foundation

/// 智能助手支持的提供商：统一走 OpenAI 兼容的 chat/completions 协议。
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case deepseek
    case kimi
    case glm
    case qwen
    case doubao
    case openAI
    case local
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi"
        case .glm: return "GLM（智谱）"
        case .qwen: return "通义千问"
        case .doubao: return "豆包（火山方舟）"
        case .openAI: return "OpenAI"
        case .local: return "本地运行时"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .openAI: return "https://api.openai.com/v1"
        // Ollama 的 OpenAI 兼容端点；LM Studio 默认在 1234 端口。
        case .local: return "http://127.0.0.1:11434/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .kimi: return "moonshot-v1-8k"
        case .glm: return "glm-4-flash"
        case .qwen: return "qwen-plus"
        // 火山方舟使用推理接入点 ID（ep-...），必须由用户自己填写。
        case .doubao: return ""
        case .openAI: return "gpt-4o-mini"
        // 本地运行时的模型名由「检测本机运行时」扫描得到。
        case .local: return ""
        case .custom: return ""
        }
    }

    /// 常用模型，用户也可以在设置里直接填写其他模型名。
    var models: [String] {
        switch self {
        case .deepseek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .kimi:
            return ["moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"]
        case .glm:
            return ["glm-4-flash", "glm-4-plus", "glm-4v-flash", "glm-4v-plus"]
        case .qwen:
            return ["qwen-plus", "qwen-max", "qwen-turbo", "qwen-vl-plus", "qwen-vl-max"]
        case .doubao, .custom, .local:
            return []
        case .openAI:
            return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini"]
        }
    }

    /// 是否使用视觉输入需要用户自行选择模型；这里只用于设置页提示。
    var supportsVisionHint: String? {
        switch self {
        case .glm: return "视觉模型：glm-4v-flash / glm-4v-plus"
        case .qwen: return "视觉模型：qwen-vl-plus / qwen-vl-max"
        case .openAI: return "视觉模型：gpt-4o-mini / gpt-4o"
        case .local: return "本地模型是否支持图片取决于模型本身（如 llava、qwen2-vl）。"
        case .deepseek, .kimi, .doubao, .custom: return nil
        }
    }

    /// 本地运行时不需要 API Key。
    var requiresAPIKey: Bool { self != .local }

    /// Keychain 里的账号名；API Key 只存钥匙串，绝不进入图库或 UserDefaults。
    var keychainAccount: String { "provider.\(rawValue)" }
}

/// 写操作审批策略：决定 AI 修改本地数据前是否弹窗。
enum AIApprovalMode: String, Codable, CaseIterable, Identifiable {
    /// 每次写操作都确认（默认，最安全）。
    case always
    /// 只有删除 / 压缩 / 批量刮削等高风险操作才确认。
    case smart
    /// 全部自动执行，不再弹窗。
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: return "每次确认"
        case .smart: return "仅高风险"
        case .automatic: return "自动应用"
        }
    }

    var detail: String {
        switch self {
        case .always: return "每个写操作都弹窗确认"
        case .smart: return "删除、压缩、批量刮削等才确认，其余直接执行"
        case .automatic: return "不再弹窗，所有写操作直接执行"
        }
    }

    var symbol: String {
        switch self {
        case .always: return "hand.raised.fill"
        case .smart: return "checkmark.shield.fill"
        case .automatic: return "bolt.badge.automatic.fill"
        }
    }
}

/// 助手会话模式：决定回答深度、工具轮数与上下文规模。
enum AIMode: String, Codable, CaseIterable, Identifiable {
    /// 快速：少工具、短回答，适合简单问答与单个操作。
    case fast
    /// 标准：按需调用工具，兼顾速度与完整度。
    case balanced
    /// 深度：多轮批量读取与执行，适合整库整理与复杂分析。
    case deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "快速"
        case .balanced: return "标准"
        case .deep: return "深度"
        }
    }

    var symbol: String {
        switch self {
        case .fast: return "bolt.fill"
        case .balanced: return "circle.grid.2x2.fill"
        case .deep: return "brain.head.profile"
        }
    }

    var detail: String {
        switch self {
        case .fast: return "少调工具、直接给结论，最快出结果"
        case .balanced: return "按需检索与执行，速度与完整度平衡"
        case .deep: return "批量读取、多轮核对，适合整库整理"
        }
    }
}

/// 随图库保存的智能助手配置（不含 API Key）。
struct AIConfig: Codable, Equatable {
    var provider: AIProvider = .deepseek
    var model: String = AIProvider.deepseek.defaultModel
    var baseURL: String = AIProvider.deepseek.defaultBaseURL
    /// 是否允许把选中/候选照片压缩后发送给模型；默认关闭，只发本地 Vision 标签与 OCR。
    var includeImages = false
    /// 单次请求最多发送的图片数量。
    var maxImages = 4
    var maxTokens = 1200
    /// 每次请求附带的最近对话轮数（用户 + 助手各一条算一轮）。
    var historyRounds = 6
    /// 单次任务允许的最大工具调用轮数：批量整理影院时越大越少来回。
    var maxToolRounds = 80
    /// 本次会话模式：快速 / 标准 / 深度。
    var mode: AIMode = .balanced
    /// 写操作审批策略：每次确认 / 仅高风险 / 自动应用。
    var approval: AIApprovalMode = .always

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? container.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? .deepseek
        model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? provider.defaultModel
        baseURL = (try? container.decodeIfPresent(String.self, forKey: .baseURL)) ?? provider.defaultBaseURL
        includeImages = (try? container.decodeIfPresent(Bool.self, forKey: .includeImages)) ?? false
        maxImages = (try? container.decodeIfPresent(Int.self, forKey: .maxImages)) ?? 4
        maxTokens = (try? container.decodeIfPresent(Int.self, forKey: .maxTokens)) ?? 1200
        historyRounds = (try? container.decodeIfPresent(Int.self, forKey: .historyRounds)) ?? 6
        maxToolRounds = (try? container.decodeIfPresent(Int.self, forKey: .maxToolRounds)) ?? 80
        mode = (try? container.decodeIfPresent(AIMode.self, forKey: .mode)) ?? .balanced
        approval = (try? container.decodeIfPresent(AIApprovalMode.self, forKey: .approval)) ?? .always
        maxImages = min(6, max(1, maxImages))
        maxTokens = min(8000, max(256, maxTokens))
        historyRounds = min(40, max(1, historyRounds))
        maxToolRounds = min(300, max(10, maxToolRounds))
    }
}

/// 一条对话消息；只持久化文字与照片引用，不保存图片数据。
struct AIChatMessage: Codable, Identifiable {
    enum Role: String, Codable {
        case user
        case assistant
        /// 本地执行完工具后的操作回执，不来自模型。
        case action
    }

    var id = UUID()
    var role: Role
    var text: String
    var createdAt = Date()
    /// 助手引用到的照片，仅保留仍存在于当前图库中的 ID。
    var photoIDs: [UUID] = []
    /// 助手建议的检索条件。
    var suggestion: AISearchSuggestion?
    var isError = false
    /// 本次回复耗时（秒）：助手消息页脚展示用。
    var elapsed: TimeInterval?
    /// 本次回复执行了多少轮工具。
    var toolSteps: Int?

    init(role: Role,
         text: String,
         photoIDs: [UUID] = [],
         suggestion: AISearchSuggestion? = nil,
         isError: Bool = false,
         elapsed: TimeInterval? = nil,
         toolSteps: Int? = nil) {
        self.role = role
        self.text = text
        self.photoIDs = photoIDs
        self.suggestion = suggestion
        self.isError = isError
        self.elapsed = elapsed
        self.toolSteps = toolSteps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        role = (try? container.decodeIfPresent(Role.self, forKey: .role)) ?? .assistant
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        photoIDs = (try? container.decodeIfPresent([UUID].self, forKey: .photoIDs)) ?? []
        suggestion = try? container.decodeIfPresent(AISearchSuggestion.self, forKey: .suggestion)
        isError = (try? container.decodeIfPresent(Bool.self, forKey: .isError)) ?? false
        elapsed = try? container.decodeIfPresent(TimeInterval.self, forKey: .elapsed)
        toolSteps = try? container.decodeIfPresent(Int.self, forKey: .toolSteps)
    }
}

/// 助手在回答末尾附加的检索建议。
struct AISearchSuggestion: Codable, Equatable {
    var keywords: String?
    var filter: String?
    var photoIDs: [String]?
}

/// 提供给模型的工具定义（OpenAI tools / function calling）。
struct AIRequestTool {
    var name: String
    var description: String
    /// JSON Schema 形式的参数描述。
    var parameters: [String: Any]
}

/// 模型返回的一次工具调用。
struct AIToolCall: Identifiable {
    var id: String
    var name: String
    /// 参数是 JSON 字符串（部分兼容实现会直接给对象，客户端已统一转成字符串）。
    var arguments: String
}

/// 一次模型回复：文本 + 可选工具调用。
struct AICompletion {
    var content: String
    var toolCalls: [AIToolCall]
}

enum AIError: LocalizedError {
    case missingKey
    case invalidBaseURL
    case unauthorized
    case rateLimited
    case server(String)
    case badResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "还没有填写 API Key，请在设置 › 助手中填写"
        case .invalidBaseURL:
            return "接口地址无效，请填写 https:// 开头的地址"
        case .unauthorized:
            return "API Key 无效或已过期"
        case .rateLimited:
            return "请求过于频繁或额度不足，请稍后再试"
        case .server(let message):
            return message
        case .badResponse:
            return "模型返回的内容无法解析"
        case .cancelled:
            return "已停止生成"
        }
    }
}
