import Foundation

// MARK: - 115 网盘（Cookie 直连）

extension LibraryStore {
    /// 用根目录列表验证 Cookie 是否可用，并顺带给出内容概况。
    func testPan115Cookie(_ cookie: String) async -> (ok: Bool, message: String) {
        let normalized = Pan115Drive.normalizedCookie(cookie)
        guard !normalized.isEmpty else { return (false, "请先粘贴浏览器 Cookie") }
        do {
            let entries = try await Pan115Drive.list(cookie: normalized, folderID: Pan115Drive.rootID)
            let folders = entries.filter { $0.isDirectory }.count
            let media = entries.filter { !$0.isDirectory && $0.isMedia }.count
            return (true, "连接成功：根目录 \(folders) 个文件夹、\(media) 个媒体文件")
        } catch let error as CloudOAuthError where error.requiresReauth {
            return (false, "Cookie 已失效：请重新登录 115.com 后复制新的 Cookie")
        } catch {
            return (false, "连接失败：\(error.localizedDescription)")
        }
    }

    /// 添加或更新 115 网盘连接。个人网盘通常只用一个账号，因此已存在时直接替换 Cookie。
    @discardableResult
    func registerPan115Mount(cookie: String,
                             name: String = "115 网盘",
                             scopes: [CloudScopeRoot]? = nil,
                             excludes: [CloudScopeRoot]? = nil) -> String? {
        let normalized = Pan115Drive.normalizedCookie(cookie)
        guard !normalized.isEmpty else { return "请先粘贴浏览器 Cookie" }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "115 网盘" : trimmedName

        if let existing = cloudMounts.first(where: { $0.kind == .pan115 }) {
            updateCloudMountAccess(existing.id, scopes: scopes, excludes: excludes)
            CloudCredentials.setPassword(normalized, for: existing.id)
            cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(existing.id.uuidString) }
            cloudVisibleCacheKey = nil
            if case .cloudMount(let current) = sidebarItem, current == existing.id {
                beginCloudAlbumScan(mountID: existing.id)
            } else {
                navigate(to: .cloudMount(existing.id))
            }
            showToast("已更新「\(existing.name)」的 Cookie")
            return nil
        }

        let mount = CloudMount(kind: .pan115, name: finalName, authMode: .cookie,
                               scopeRoots: scopes ?? [], excludedRoots: excludes ?? [])
        CloudCredentials.setPassword(normalized, for: mount.id)
        cloudMounts.append(mount)
        saveCloudMounts()
        showToast("已连接「\(finalName)」")
        navigate(to: .cloudMount(mount.id))
        return nil
    }
}
