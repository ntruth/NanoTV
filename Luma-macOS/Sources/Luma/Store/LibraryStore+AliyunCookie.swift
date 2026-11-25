import Foundation

// MARK: - 阿里云盘（Cookie / refresh_token 直连）

extension LibraryStore {
    /// 用根目录列表验证 Cookie / refresh_token 是否可用。
    func testAliyunCookie(_ input: String) async -> (ok: Bool, message: String) {
        do {
            let token = try await AliyunCookieAuth.token(from: input)
            let drives = try await AliyunOAuth.drives(accessToken: token.accessToken)
            guard !drives.isEmpty else { throw CloudOAuthError.api("未获取到网盘信息") }
            var folders = 0
            var media = 0
            for drive in drives {
                let entries = try await AliyunOAuth.list(driveID: drive.id,
                                                         parentID: "root",
                                                         accessToken: token.accessToken)
                folders += entries.filter { $0.isDirectory }.count
                media += entries.filter { !$0.isDirectory && $0.isMedia }.count
            }
            let names = drives.map(\.label).joined(separator: " / ")
            return (true, "连接成功：\(names)，根目录合计 \(folders) 个文件夹、\(media) 个媒体文件")
        } catch let error as CloudOAuthError where error.requiresReauth {
            return (false, "登录凭据已失效：请打开 https://alist.nn.ci/tool/aliyundrive/request 重新扫码，复制新的 refresh_token")
        } catch {
            return (false, "连接失败：\(error.localizedDescription)")
        }
    }

    /// 添加或更新阿里云盘的 Cookie 连接。
    func registerAliyunCookieMount(input: String,
                                   name: String = "阿里云盘",
                                   scopes: [CloudScopeRoot]? = nil,
                                   excludes: [CloudScopeRoot]? = nil) async -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "请先粘贴 Cookie 或 refresh_token" }

        let token: CloudToken
        let info: (driveID: String, name: String?)
        do {
            token = try await AliyunCookieAuth.token(from: text)
            info = try await AliyunOAuth.driveInfo(accessToken: token.accessToken)
        } catch {
            return error.localizedDescription
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "阿里云盘" : trimmedName

        if let existing = cloudMounts.first(where: { $0.kind == .aliyun && $0.authMode == .cookie }) {
            updateCloudMountAccess(existing.id, scopes: scopes, excludes: excludes)
            if let index = cloudMounts.firstIndex(where: { $0.id == existing.id }) {
                cloudMounts[index].remoteDriveID = info.driveID
                if !trimmedName.isEmpty { cloudMounts[index].name = finalName }
            }
            CloudCredentials.setPassword(text, for: existing.id)
            CloudOAuthStore.saveToken(token, mountID: existing.id)
            cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(existing.id.uuidString) }
            cloudVisibleCacheKey = nil
            saveCloudMounts()
            if case .cloudMount(let current) = sidebarItem, current == existing.id {
                beginCloudAlbumScan(mountID: existing.id)
            } else {
                navigate(to: .cloudMount(existing.id))
            }
            showToast("已更新「\(cloudMounts.first(where: { $0.id == existing.id })?.name ?? finalName)」的登录凭据")
            return nil
        }

        let mount = CloudMount(kind: .aliyun,
                               name: finalName,
                               remoteDriveID: info.driveID,
                               authMode: .cookie,
                               scopeRoots: scopes ?? [],
                               excludedRoots: excludes ?? [])
        CloudCredentials.setPassword(text, for: mount.id)
        CloudOAuthStore.saveToken(token, mountID: mount.id)
        cloudMounts.append(mount)
        saveCloudMounts()
        showToast("已连接「\(finalName)」")
        navigate(to: .cloudMount(mount.id))
        return nil
    }
}
