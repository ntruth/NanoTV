import Foundation
import SwiftUI
import LumaContentCore

/// 智能助手：只读问答 + 检索建议。
/// 每条消息随当前图库保存；API Key 只存钥匙串。
extension LibraryStore {
    private static let aiConfigKey = "ai_config"
    private static let aiConversationKey = "ai_conversation"
    private static let aiCandidateLimit = 40

    // MARK: - 加载与保存

    func loadAIState() {
        aiTask?.cancel()
        aiTask = nil
        aiIsResponding = false
        aiActivity = nil
        aiError = nil

        if let json = metadataStore?.setting(Self.aiConfigKey),
           let data = json.data(using: .utf8),
           let config = try? JSONDecoder().decode(AIConfig.self, from: data) {
            aiConfig = config
        } else {
            aiConfig = AIConfig()
        }

        if let json = metadataStore?.setting(Self.aiConversationKey),
           let data = json.data(using: .utf8),
           let messages = try? JSONDecoder().decode([AIChatMessage].self, from: data) {
            aiMessages = messages
        } else {
            aiMessages = []
        }
    }

    func saveAIConfig() {
        guard let data = try? JSONEncoder().encode(aiConfig),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.aiConfigKey, json)
    }

    func saveAIConversation() {
        trimAIMessages()
        guard let data = try? JSONEncoder().encode(aiMessages),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.aiConversationKey, json)
    }

    func clearAIConversation() {
        aiTask?.cancel()
        aiTask = nil
        aiIsResponding = false
        aiActivity = nil
        aiMessages = []
        aiError = nil
        saveAIConversation()
    }

    func updateAIProvider(_ provider: AIProvider) {
        aiConfig.provider = provider
        aiConfig.model = provider.defaultModel
        aiConfig.baseURL = provider.defaultBaseURL
        saveAIConfig()
    }

    /// API Key 只存钥匙串，随设备而不是图库；切换图库不需要重新填写。
    var aiAPIKey: String {
        aiConfig.provider.requiresAPIKey ? AIKeychain.key(for: aiConfig.provider) : ""
    }

    var aiHasAPIKey: Bool {
        !aiConfig.provider.requiresAPIKey || AIKeychain.hasKey(for: aiConfig.provider)
    }

    /// 接口地址与模型名都必须填写（豆包与自定义提供商默认不预填模型）。
    var aiConfigurationReady: Bool {
        !aiConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !aiConfig.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveAIAPIKey(_ key: String) {
        AIKeychain.setKey(key, for: aiConfig.provider)
    }

    // MARK: - 发送

    /// 影院顶栏「一键智能整理」：打开助手、预填整理指令并自动发送。
    /// 本次运行只跳过影院写工具的逐轮确认 —— 入口本身就是授权，其它写操作仍然要确认。
    func presentCinemaAutoMatch() {
        let scope = cinemaActiveScope
        aiAutoMatchCinema = true
        aiInput = AILibraryTools.cinemaAutoMatchPrompt(scopeName: cinemaScopeName(scope))
        showAIAssistant = true
        // 等面板挂上再发，用户能先看到自己发出的问题。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.showAIAssistant, !self.aiInput.isEmpty else { return }
            self.sendAIMessage()
        }
    }

    func sendAIMessage() {
        let question = aiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !aiIsResponding else { return }
        guard aiConfigurationReady else {
            aiError = "请先在设置 › 助手中填写接口地址与模型"
            showToast("请先在设置 › 助手中填写接口地址与模型")
            return
        }
        guard aiHasAPIKey else {
            aiError = AIError.missingKey.localizedDescription
            showToast(AIError.missingKey.localizedDescription)
            return
        }

        aiInput = ""
        aiError = nil
        aiMessages.append(AIChatMessage(role: .user, text: question))
        trimAIMessages()
        saveAIConversation()
        aiIsResponding = true

        let config = aiConfig
        let key = aiAPIKey
        let mode = config.mode
        // 模式决定上下文规模、历史长度与工具轮数：快速更轻、深度更全。
        let candidateLimit: Int
        let historyRounds: Int
        let roundLimit: Int
        switch mode {
        case .fast:
            candidateLimit = 24
            historyRounds = min(3, config.historyRounds)
            roundLimit = min(12, max(4, config.maxToolRounds))
        case .balanced:
            candidateLimit = Self.aiCandidateLimit
            historyRounds = config.historyRounds
            roundLimit = config.maxToolRounds
        case .deep:
            candidateLimit = 64
            historyRounds = max(10, config.historyRounds)
            roundLimit = min(300, max(150, config.maxToolRounds))
        }
        let candidates = aiCandidatePhotos(limit: candidateLimit)
        let context = makeAILibraryContext(photos: candidates, limit: candidateLimit)
        let history = aiMessages.dropLast()
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(max(2, historyRounds * 2))
            .map { AIRequestMessage(role: $0.role == .user ? "user" : "assistant", text: $0.text) }
        let candidateIDs = Set(candidates.map(\.id))
        aiLastCandidateIDs = candidates.map(\.id)
        var candidateNames: [String: UUID] = [:]
        for photo in candidates {
            candidateNames[photo.originalName.lowercased()] = photo.id
            candidateNames[photo.filename.lowercased()] = photo.id
        }
        aiLastCandidateNames = candidateNames
        let prompt = context.promptText(question: question)
        let imageLimit = config.includeImages ? max(1, config.maxImages) : 0
        let imagePhotos = imageLimit > 0 ? Array(candidates.prefix(imageLimit * 2)) : []
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library((LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
                .standardizedFileURL.path),
                      kind: .assistant,
                      title: "AI 助手"),
            cancel: { [weak self] in
                Task { @MainActor in self?.stopAIResponse() }
            }
        )

        aiTask = Task { [weak self] in
            guard let self else { return }
            self.aiActivity = "正在理解当前范围"
            let startedAt = Date()
            defer {
                self.aiAutoMatchCinema = false
                self.aiActivity = nil
                if Task.isCancelled {
                    self.cancelSourceJob(jobID)
                } else {
                    self.finishSourceJob(jobID, message: "已回复")
                }
            }
            var imagePairs: [(UUID, String)] = []
            if imageLimit > 0 {
                imagePairs = await Task.detached(priority: .userInitiated) {
                    AIImageEncoder.dataURLs(for: imagePhotos, limit: imageLimit)
                }.value
            }
            if Task.isCancelled {
                self.aiIsResponding = false
                self.aiTask = nil
                return
            }

            var promptText = prompt
            if !imagePairs.isEmpty {
                let indices = imagePairs.compactMap { pair in
                    context.candidates.first(where: { $0.id == pair.0 })?.index
                }
                if !indices.isEmpty {
                    let list = indices.map { "#\($0)" }.joined(separator: "、")
                    promptText += "\n\n【随消息发送的图片】依次对应候选照片 \(list)。"
                }
            }

            var wire: [AIRequestMessage] = [
                AIRequestMessage(role: "system",
                                 text: AILibraryContext.systemPrompt + "\n\n"
                                     + AILibraryContext.modeInstruction(mode))
            ]
            wire.append(contentsOf: history)
            wire.append(AIRequestMessage(role: "user",
                                         text: promptText,
                                         images: imagePairs.map(\.1)))

            var allowedIDs = candidateIDs
            var finalText = ""
            var finalSuggestion: AISearchSuggestion?
            var toolRounds = 0
            var reminderSent = false
            var didExecuteTool = false

            do {
                while true {
                    let completion = try await AIProviderClient.complete(
                        config: config,
                        apiKey: key,
                        messages: wire,
                        tools: aiToolDefinitions
                    )
                    guard !Task.isCancelled else {
                        self.aiIsResponding = false
                        self.aiTask = nil
                        return
                    }

                    if completion.toolCalls.isEmpty {
                        // 有些模型会先给方案而不调用工具：对有明确操作意图的问题提醒一次。
                        if !reminderSent, Self.hasActionIntent(question) {
                            reminderSent = true
                            wire.append(AIRequestMessage(role: "assistant", text: completion.content))
                            wire.append(AIRequestMessage(
                                role: "user",
                                text: "请调用工具实际执行上面的操作；只有在工具返回成功后才能说已完成。若无法执行，请说明原因。"
                            ))
                            continue
                        }
                        let parsed = AIContextBuilder.parseDirective(from: completion.content)
                        finalText = parsed.text
                        finalSuggestion = parsed.suggestion
                        break
                    }

                    toolRounds += 1
                    if toolRounds > roundLimit {
                        finalText = "工具调用次数过多，已停止。请换一种问法或缩小范围。"
                        break
                    }

                    wire.append(AIRequestMessage(role: "assistant",
                                                 text: completion.content,
                                                 toolCalls: completion.toolCalls))

                    let writeCalls = completion.toolCalls.filter {
                        AILibraryTools.writeToolNames.contains($0.name)
                    }
                    let approved = writeCalls.isEmpty
                        ? Set<String>()
                        : self.approvedAIToolCalls(writeCalls)
                    var summaries: [String] = []

                    for call in completion.toolCalls {
                        let isWrite = AILibraryTools.writeToolNames.contains(call.name)
                        if isWrite, !approved.contains(call.id) {
                            wire.append(AIRequestMessage(
                                role: "tool",
                                text: "{\"ok\":false,\"error\":\"用户取消了本次操作\"}",
                                toolCallID: call.id
                            ))
                            continue
                        }
                        self.aiActivity = "正在" + AILibraryTools.shortTitle(for: call.name)
                        let result = await self.executeAITool(call)
                        didExecuteTool = true
                        wire.append(AIRequestMessage(role: "tool",
                                                     text: result.json,
                                                     toolCallID: call.id))
                        allowedIDs.formUnion(result.photoIDs)
                        if let summary = result.summary {
                            summaries.append(summary)
                        }
                    }

                    self.aiActivity = "正在整理结果"
                    if !summaries.isEmpty {
                        self.aiMessages.append(AIChatMessage(role: .action,
                                                             text: summaries.joined(separator: " · ")))
                        self.trimAIMessages()
                        self.saveAIConversation()
                    }
                }

                var photoIDs: [UUID] = []
                if let rawIDs = finalSuggestion?.photoIDs {
                    photoIDs = rawIDs.compactMap { UUID(uuidString: $0) }
                        .filter { allowedIDs.contains($0) }
                }
                let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.aiMessages.append(AIChatMessage(role: .assistant,
                                                     text: text.isEmpty ? "（模型没有返回内容）" : text,
                                                     photoIDs: photoIDs,
                                                     suggestion: finalSuggestion,
                                                     elapsed: Date().timeIntervalSince(startedAt),
                                                     toolSteps: toolRounds))
                // 有明确操作意图却一次工具都没调用：明确提示未执行，避免被模型的“已完成”误导。
                if !didExecuteTool, Self.hasActionIntent(question) {
                    self.aiMessages.append(AIChatMessage(
                        role: .assistant,
                        text: "本次没有执行任何图库操作：模型没有调用工具。可以重试，或在设置 › 助手中改用支持工具调用的模型。",
                        isError: true
                    ))
                }
                self.saveAIConversation()
                self.aiIsResponding = false
                self.aiTask = nil
            } catch {
                if case AIError.cancelled = error {
                    self.aiIsResponding = false
                    self.aiTask = nil
                    return
                }
                self.aiError = error.localizedDescription
                self.aiMessages.append(AIChatMessage(role: .assistant,
                                                     text: error.localizedDescription,
                                                     isError: true,
                                                     elapsed: Date().timeIntervalSince(startedAt)))
                self.saveAIConversation()
                self.aiIsResponding = false
                self.aiTask = nil
            }
        }
    }

    func stopAIResponse() {
        aiTask?.cancel()
        aiTask = nil
        aiIsResponding = false
        aiActivity = nil
    }

    /// 重新生成上一条回复：保留对应用户提问，清掉之后的回复与执行轨迹再重发。
    func regenerateAIResponse() {
        guard !aiIsResponding else { return }
        guard let index = aiMessages.lastIndex(where: { $0.role == .user }) else { return }
        let question = aiMessages[index].text
        aiMessages.removeSubrange(index...)
        aiError = nil
        saveAIConversation()
        aiInput = question
        sendAIMessage()
    }

    /// 把助手给出的检索条件套到当前网格（复用现有搜索与筛选管线）。
    func applyAISuggestion(_ suggestion: AISearchSuggestion) {
        if let keywords = suggestion.keywords?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keywords.isEmpty {
            searchText = keywords
            prepareSemanticSearch()
        }
        if let raw = suggestion.filter, let filter = PhotoFilter(rawValue: raw) {
            photoFilter = filter
        }
        showToast("已按助手的条件筛选当前图库")
    }

    func testAIConnection() async -> (Bool, String) {
        guard aiConfigurationReady else {
            return (false, "请先填写接口地址与模型")
        }
        let key = aiAPIKey
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, AIError.missingKey.localizedDescription)
        }
        do {
            let reply = try await AIProviderClient.complete(
                config: aiConfig,
                apiKey: key,
                messages: [AIRequestMessage(role: "user", text: "请只回复 OK")]
            )
            let preview = reply.content.prefix(40)
            return (true, "连接成功：\(preview)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - 上下文

    /// 选中项优先，其次当前范围的前若干张；数量固定，避免把整个图库塞进提示词。
    func aiCandidatePhotos(limit: Int) -> [PhotoItem] {
        var result: [PhotoItem] = []
        var seen: Set<UUID> = []
        for id in selection {
            guard let photo = anyPhoto(id: id) else { continue }
            guard seen.insert(photo.id).inserted else { continue }
            result.append(photo)
            if result.count >= limit { return result }
        }
        let source = isCloudScope ? cloudVisiblePhotos : visiblePhotos
        for photo in source {
            guard seen.insert(photo.id).inserted else { continue }
            result.append(photo)
            if result.count >= limit { break }
        }
        return result
    }

    func makeAILibraryContext(photos: [PhotoItem],
                              limit: Int = LibraryStore.aiCandidateLimit) -> AILibraryContext {
        let scopeCount = visibleCount
        let total: Int
        if isSystemScope {
            total = systemTotalAssetCount > 0 ? systemTotalAssetCount : systemPhotos.count
        } else if isCloudScope {
            total = cloudPhotos.count
        } else {
            total = self.photos.count
        }
        let analysis = isSystemScope || isCloudScope ? [:] : analysisIndex
        var context = AIContextBuilder.make(scopeTitle: sidebarTitle,
                                            scopeCount: scopeCount,
                                            libraryTotal: total,
                                            filterTitle: photoFilter.title,
                                            searchText: searchText,
                                            selectionCount: selection.count,
                                            photos: photos,
                                            analysis: analysis,
                                            limit: limit)
        // 影院页的照片图库可能是 0 项，但影院里有目录与视频：单独附一份影院快照。
        if isAICinemaScope {
            context.cinema = makeAICinemaSnapshot()
        }
        return context
    }

    private var isAICinemaScope: Bool {
        switch sidebarItem {
        case .cinema, .cloudCinema: return true
        default: return false
        }
    }

    /// 给助手一份克制的影院快照：目录、计数与少量样本，不把整库塞进提示词。
    private func makeAICinemaSnapshot() -> AILibraryContext.CinemaSnapshot {
        let scope = cinemaActiveScope
        let entries = Array(cinemaEntries(for: scope).values)
        // 计数以「完整视频清单」为准：从未刮削过的网盘 entries 为空，但仍需要让助手看到视频数。
        let candidates = cinemaCandidates(for: scope)
        let matchedIDs = Set(entries.filter(\.matched).map(\.id))
        let matched = candidates.filter { matchedIDs.contains($0.photo.id) }.count
        let total = max(candidates.count, entries.count)

        var allFolders: [CinemaFolder] = []
        var stack = cinemaFolders(for: scope)
        while let folder = stack.popLast() {
            allFolders.append(folder)
            stack.append(contentsOf: folder.children)
        }
        let folders = allFolders
            .sorted { $0.subtreePhotos.count > $1.subtreePhotos.count }
            .prefix(12)
            .map { folder in
                AILibraryContext.CinemaFolderLine(name: folder.name,
                                                  path: folder.path,
                                                  videos: folder.subtreePhotos.count,
                                                  matched: folder.matchedCount)
            }

        let videos: [AILibraryContext.CinemaVideoLine]
        if entries.isEmpty {
            // 还没刮削过：用文件名解析结果给模型一点样本，具体清单让它调用 cinema_tree。
            videos = candidates
                .sorted { $0.photo.displayFilename.localizedStandardCompare($1.photo.displayFilename)
                    == .orderedAscending }
                .prefix(16)
                .map { candidate in
                    let parsed = CinemaScraper.parse(filename: candidate.photo.displayFilename,
                                                     folderHint: candidate.folderHint)
                    return AILibraryContext.CinemaVideoLine(
                        filename: candidate.photo.displayFilename,
                        title: parsed.title,
                        matched: false,
                        season: parsed.season,
                        episode: parsed.episode,
                        resolution: candidate.photo.pixelWidth > 0
                            ? "\(candidate.photo.pixelWidth)×\(candidate.photo.pixelHeight)" : ""
                    )
                }
        } else {
            videos = entries
                .sorted { lhs, rhs in
                    if lhs.matched != rhs.matched { return !lhs.matched }
                    return lhs.file.capturedAt > rhs.file.capturedAt
                }
                .prefix(16)
                .map { entry in
                    AILibraryContext.CinemaVideoLine(
                        filename: entry.file.filename,
                        title: entry.title,
                        matched: entry.matched,
                        season: entry.season,
                        episode: entry.episode,
                        resolution: entry.file.pixelWidth > 0
                            ? "\(entry.file.pixelWidth)×\(entry.file.pixelHeight)" : ""
                    )
                }
        }

        return AILibraryContext.CinemaSnapshot(scopeName: cinemaScopeName(scope),
                                               total: total,
                                               matched: matched,
                                               folders: Array(folders),
                                               videos: Array(videos))
    }

    private func trimAIMessages() {
        // 本地保留比「请求历史」更宽：用户调大记忆轮数时，历史消息不会被提前裁掉。
        let cap = max(40, aiConfig.historyRounds * 4)
        if aiMessages.count > cap {
            aiMessages.removeFirst(aiMessages.count - cap)
        }
    }

    /// 粗略识别「要动手」的请求，用于提醒模型调用工具，而不是只给方案。
    private static func hasActionIntent(_ text: String) -> Bool {
        if text.contains("怎么") || text.contains("如何") || text.contains("为什么") { return false }
        let keywords = ["创建", "新建", "加入", "放到", "放进", "归入", "移出", "移除",
                        "收藏", "取消收藏", "添加关键词", "去掉关键词", "删除关键词", "打标签",
                        "整理成", "重命名", "改名", "移动", "隐藏", "取消隐藏", "恢复",
                        "设为封面", "封面", "改标题", "设置标题", "移入最近删除", "压缩", "美化",
                        "选中", "打开", "切换到", "筛选", "排序", "直接操作", "执行",
                        "匹配", "刮削", "重新识别", "识别一下"]
        return keywords.contains { text.contains($0) }
    }
}
