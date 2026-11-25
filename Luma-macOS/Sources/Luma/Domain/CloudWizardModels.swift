import Foundation
import SwiftUI

enum AlistProvider: String, CaseIterable, Identifiable {
    case aliyun
    case baidu
    case quark
    case pan115

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aliyun: return "阿里云盘"
        case .baidu: return "百度网盘"
        case .quark: return "夸克网盘"
        case .pan115: return "115 网盘"
        }
    }

    var subtitle: String {
        switch self {
        case .aliyun: return "扫码授权，内置公共应用"
        case .baidu: return "授权码换取刷新令牌"
        case .quark: return "粘贴浏览器 Cookie"
        case .pan115: return "扫码或粘贴 Cookie"
        }
    }

    var brand: CloudBrand {
        switch self {
        case .aliyun: return .aliyun
        case .baidu: return .baidu
        case .quark: return .quark
        case .pan115: return .pan115
        }
    }

    var mountPath: String {
        switch self {
        case .aliyun: return "/aliyun"
        case .baidu: return "/baidu"
        case .quark: return "/quark"
        case .pan115: return "/pan115"
        }
    }

    var steps: [String] {
        switch self {
        case .aliyun:
            return [
                "打开 AList 后台 → 存储 → 添加",
                "驱动选择「阿里云盘Open」，挂载路径填 \(mountPath)",
                "打开「获取令牌页面」，用阿里云盘 App 扫码并在手机上确认",
                "把生成的 refresh_token 填入「刷新令牌」，Client ID/Secret 留空，保存"
            ]
        case .baidu:
            return [
                "打开 AList 后台 → 存储 → 添加",
                "驱动选择「百度网盘」，挂载路径填 \(mountPath)",
                "打开「刷新令牌」的获取链接，登录百度账号并授权",
                "把返回的 refresh_token 填入，下载 API 保持「官方」，保存"
            ]
        case .quark:
            return [
                "用 Chrome/Edge 登录 pan.quark.cn，F12 → 网络，复制任一请求的完整 Cookie",
                "AList 后台 → 存储 → 添加，驱动「夸克网盘」，挂载路径 \(mountPath)",
                "粘贴 Cookie，根目录 ID 填 0，保存",
                "视频播放异常时，可在该存储中开启「使用转码地址」"
            ]
        case .pan115:
            return [
                "AList 后台 → 存储 → 添加，驱动「115网盘」，挂载路径 \(mountPath)",
                "点「扫码登录」用 115 App 扫码；或按文档手动粘贴 Cookie",
                "保存后在 AList 首页确认目录可见"
            ]
        }
    }

    var notes: [String] {
        switch self {
        case .aliyun:
            return [
                "Client ID/Secret 留空即使用 AList 的公共应用凭据，无需自己去开放平台注册应用。",
                "视频走阿里云盘官方转码，首次播放可能需要等待转码完成。"
            ]
        case .baidu:
            return [
                "百度令牌约 30 天有效，AList 会自动刷新。",
                "下载 20MB 以上文件需要 User-Agent: pan.baidu.com；在 AList 使用 Web 代理模式可避免手动设置。"
            ]
        case .quark:
            return [
                "仅 Chrome/Edge 抓取的 Cookie 可用，Firefox 抓到的可能是游客状态。"
            ]
        case .pan115:
            return [
                "115 官方开放平台已暂停，AList 使用 Cookie 方式，稳定性由 115 侧风控决定。",
                "建议只读使用，减少触发风控的概率。"
            ]
        }
    }

    var docsURL: String {
        switch self {
        case .aliyun: return "https://alistgo.com/guide/drivers/aliyundrive_open.html"
        case .baidu: return "https://alist.nn.ci/guide/drivers/baidu.html#refresh-token"
        case .quark: return "https://alistgo.com/guide/drivers/quark.html"
        case .pan115: return "https://alistgo.com/guide/drivers/115.html"
        }
    }

    var extraLink: (title: String, url: String)? {
        switch self {
        case .aliyun:
            return ("获取令牌页面", "https://alistgo.com/tool/aliyundrive/request")
        case .baidu:
            return ("打开百度网盘", "https://pan.baidu.com")
        case .quark:
            return ("打开夸克网盘", "https://pan.quark.cn")
        case .pan115:
            return ("打开 115 网盘", "https://115.com")
        }
    }
}

// MARK: - 向导流程

enum CloudWizardFlow: String, CaseIterable, Identifiable {
    case aliyunCookie
    case baidu
    case quark
    case pan115
    case smb
    case webdav
    case alist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aliyunCookie: return "阿里云盘"
        case .baidu: return "百度网盘"
        case .quark: return "夸克网盘"
        case .pan115: return "115 网盘"
        case .smb: return "SMB 共享"
        case .webdav: return "WebDAV"
        case .alist: return "AList 聚合"
        }
    }

    var subtitle: String {
        switch self {
        case .aliyunCookie: return "浏览器 Cookie · 免开发者应用"
        case .baidu: return "官方 OAuth · 直链播放"
        case .quark: return "浏览器 Cookie · 直连浏览与播放"
        case .pan115: return "浏览器 Cookie · 直连浏览与播放"
        case .smb: return "群晖 / TrueNAS · 只读浏览"
        case .webdav: return "填地址与账号，直连 NAS"
        case .alist: return "夸克 / 115 / 其他网盘"
        }
    }

    var icon: String {
        switch self {
        case .aliyunCookie: return "cloud"
        case .baidu: return "cloud.fill"
        case .quark: return "square.stack.3d.up.fill"
        case .pan115: return "externaldrive.fill"
        case .smb: return "network"
        case .webdav: return "externaldrive.connected.to.line.below"
        case .alist: return "wand.and.stars"
        }
    }

    /// 官方网盘的品牌图标；SMB / WebDAV / AList 用系统符号。
    var brand: CloudBrand? {
        switch self {
        case .aliyunCookie: return .aliyun
        case .baidu: return .baidu
        case .quark: return .quark
        case .pan115: return .pan115
        case .smb, .webdav, .alist: return nil
        }
    }

    var kind: CloudKind? {
        switch self {
        case .aliyunCookie: return nil
        case .baidu: return .baidu
        case .quark: return .quark
        case .pan115: return .pan115
        case .smb: return .smb
        case .webdav: return .webdav
        case .alist: return nil
        }
    }

    var steps: [String] {
        switch self {
        case .baidu: return ["应用凭据", "授权登录", "接入范围", "完成"]
        case .aliyunCookie, .quark, .pan115: return ["粘贴 Cookie", "确认添加"]
        case .smb, .webdav: return ["填写连接", "确认添加"]
        case .alist: return ["选择网盘", "连接 AList", "在 AList 中添加", "确认"]
        }
    }

    /// 走浏览器 Cookie / 令牌的接入方式。
    var usesCookie: Bool { self == .aliyunCookie || self == .quark || self == .pan115 }

    var requiresDeveloperApp: Bool { self == .baidu }
}
