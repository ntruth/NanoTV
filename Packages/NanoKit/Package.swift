// swift-tools-version: 5.9
import Foundation
import PackageDescription

// 支持零外部依赖秒级编译调试，也可通过环境变量 NANO_USE_VENDOR_LIBS=1 开启 MPVKit / GRDB / Nuke / AMSMB2 扩展依赖
let enableVendorLibs = ProcessInfo.processInfo.environment["NANO_USE_VENDOR_LIBS"] == "1"

var packageDependencies: [Package.Dependency] = []
if enableVendorLibs {
    packageDependencies = [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/kean/Nuke.git", from: "12.8.0"),
        .package(url: "https://github.com/amosavian/AMSMB2.git", from: "3.1.0"),
        .package(url: "https://github.com/mpvkit/MPVKit.git", from: "0.40.0")
    ]
}

let package = Package(
    name: "NanoKit",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14),
        .tvOS(.v17)
    ],
    products: [
        .library(name: "NanoCore", targets: ["NanoCore"]),
        .library(name: "NanoVFS", targets: ["NanoVFS"]),
        .library(name: "NanoScraper", targets: ["NanoScraper"]),
        .library(name: "NanoLiveTV", targets: ["NanoLiveTV"]),
        .library(name: "NanoRemoteHub", targets: ["NanoRemoteHub"]),
        .library(name: "NanoMusic", targets: ["NanoMusic"]),
        .library(name: "NanoPlayerKit", targets: ["NanoPlayerKit"]),
        .library(name: "NanoSync", targets: ["NanoSync"]),
        .library(name: "NanoDesignSystem", targets: ["NanoDesignSystem"]),
        .library(name: "NanoUI", targets: ["NanoUI"])
    ],
    dependencies: packageDependencies,
    targets: [
        // 1. 基础设施与统一领域模型层（内置原生 SQLite3 引擎与磁盘缓存配额管家）
        .target(
            name: "NanoCore",
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // 2. 统一虚拟文件系统与网盘双轨（方案A OpenAPI + 方案B 扫码Cookie + 本地HTTP流代理）
        .target(
            name: "NanoVFS",
            dependencies: ["NanoCore"]
        ),
        // 3. 影视文件名智能清洗、TMDB 刮削与本地 NFO 解析
        .target(
            name: "NanoScraper",
            dependencies: ["NanoCore", "NanoVFS"]
        ),
        // 4. IPTV 直播源解析、多线聚合、XMLTV EPG 与回看时间轴引擎
        .target(
            name: "NanoLiveTV",
            dependencies: ["NanoCore"]
        ),
        // 5. 远程网络资源聚合引擎（苹果CMS JSON + TVBox/FongMi订阅 + 自定义网页爬虫规则 + Luma 预置片源包）
        .target(
            name: "NanoRemoteHub",
            dependencies: ["NanoCore"],
            resources: [
                .process("Resources")
            ]
        ),
        // 6. 高解析度音乐中心（无损元数据、整轨 CUE 分轨器、LRC 逐字/逐行歌词引擎）
        .target(
            name: "NanoMusic",
            dependencies: ["NanoCore", "NanoVFS"]
        ),
        // 7. 双内核播放引擎路由（AVPlayer 原生内核 + MPVKit 协议桥接层 + 在线字幕与 Trakt 打点）
        .target(
            name: "NanoPlayerKit",
            dependencies: ["NanoCore", "NanoVFS", "NanoSync"]
        ),
        // 8. 多端同步与安全（iCloud Keychain、WebDAV 快照备份、Apple TV 局域网扫码助手、隐私锁）
        .target(
            name: "NanoSync",
            dependencies: ["NanoCore"]
        ),
        // 9. 暗夜毛玻璃视觉设计系统（兼容 macOS 鼠标悬停与 tvOS 10英尺遥控器焦点）
        .target(
            name: "NanoDesignSystem",
            dependencies: ["NanoCore"]
        ),
        // 10. 全业务共享视图层（macOS NavigationSplitView + tvOS TabView 自适应）
        .target(
            name: "NanoUI",
            dependencies: [
                "NanoCore",
                "NanoVFS",
                "NanoScraper",
                "NanoLiveTV",
                "NanoRemoteHub",
                "NanoMusic",
                "NanoPlayerKit",
                "NanoSync",
                "NanoDesignSystem"
            ]
        ),
        // 单元测试集
        .testTarget(
            name: "NanoKitTests",
            dependencies: [
                "NanoCore",
                "NanoVFS",
                "NanoScraper",
                "NanoLiveTV",
                "NanoRemoteHub",
                "NanoMusic",
                "NanoPlayerKit"
            ]
        )
    ]
)
