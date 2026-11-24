# Nano — 全能跨端流媒体中心 (macOS & Apple TV)

**Nano** 是一款基于 **100% Swift & SwiftUI** 原生架构打造的暗夜毛玻璃风格流媒体聚合应用，同时适配 **macOS 14.0+** 桌面端与 **tvOS 17.0+ (Apple TV)** 10 英尺遥控器焦点交互。

---

## 核心特性矩阵

1. **网络存储与主流网盘双轨直连 (`NanoVFS`)**
   * **方案 A (OpenAPI 优先) + 方案 B (扫码 Cookie 兜底)**：接入 **115 网盘、百度网盘、夸克网盘** 时优先走官方 OpenAPI，若不支持（如夸克）或权限受限自动降级至方案 B，配合内置 `LocalStreamProxyServer`（`127.0.0.1` 回环代理）注入防盗链请求头并透传 HTTP `Range` 实现 4K 秒开拖动。
   * **小雅 / OpenList V3 原生适配**：免全量扫盘，支持 302 重定向直链穿透与全局秒搜。
   * **本地 NAS**：支持 SMB / WebDAV 挂载与目录浏览。
2. **影院级海报墙与刮削 (`NanoScraper`)**
   * 正则清洗复杂文件名（提取片名、年份、`S01E02`、4K/DV/HDR/帧率），兼容本地 `.nfo` 与 TMDB API 刮削，支持分集进度百分比与**一键设置跳过片头/片尾**。
3. **IPTV 网络电视与时移回看 (`NanoLiveTV`)**
   * 兼容 `#EXTM3U` 与 `#genre#` TXT 源，自动归类「央视 / 卫视 / 港澳台 / 4K8K / 省份」，同名频道多线路聚合容灾，支持多日节目单回看（`playseek` / `catchup-source`）与底部横向快速选台抽屉。
4. **三大远程资源引擎全兼容 (`NanoRemoteHub`)**
   * 原生支持 **标准苹果 CMS JSON 接口** + **TVBox / FongMi `json` 订阅包** + **声明式自定义网页爬虫规则**，配备联网健康度圆环表、并发测速（`ms`）与磁盘缓存 LRU 配额管家。
5. **Hi-Fi 无损音乐中心 (`NanoMusic`)**
   * 原生解析整轨 `.cue` 自动虚拟分轨与 `.lrc` 时间轴歌词，配备 Apple TV 沉浸式流体歌词大屏。
6. **多端无感同步与隐私空间 (`NanoSync`)**
   * **iCloud Keychain** 跨端免输密码共享凭证 + **WebDAV** 全量 SQLite 快照备份恢复 + **Apple TV 局域网扫码快传微服务端** + **Touch ID / PIN 码隐私保险箱**。

---

## 同步到 Mac 后的编译与运行指南

### 方式一：一键生成双端 Xcode 工程（推荐）
将整个 `Nano` 目录同步至 Mac 后，在终端执行：
```bash
chmod +x scripts/generate_xcodeproj.sh
./scripts/generate_xcodeproj.sh
```
脚本将自动运行 `NanoKit` 单元测试并通过 `XcodeGen` 生成 `Nano.xcodeproj`，在 Xcode 顶部 Scheme 切换 **`Nano-macOS`** 或 **`Nano-tvOS`** 按 `Cmd + R` 即可运行。

### 方式二：零工具直接用 Xcode 打开 Swift Package
无需安装任何命令行工具，直接在 Mac Finder 中双击打开：
`Packages/NanoKit/Package.swift`
即可在 Xcode 中直接编译全部 10 个核心模块、查看 SwiftUI Previews 并执行单元测试（`Cmd + U`）。

### 开启外部 C/C++ 扩展库（可选）
默认工程使用 Apple 原生 SDK（`AVPlayer` + 系统 `SQLite3` + `Network`）实现零外部依赖秒级编译；如需挂载 `MPVKit (libmpv + Metal)`、`AMSMB2`、`GRDB`、`Nuke`，在构建前设置环境变量：
```bash
export NANO_USE_VENDOR_LIBS=1
```

---

## 目录结构说明

* `docs/PRD_Architecture.md` — 完整产品需求与系统架构设计文档
* `project.yml` — XcodeGen 双端（macOS + tvOS）工程声明文件
* `App/` — macOS 与 Apple TV 应用宿主入口及权限声明 (`entitlements`)
* `Packages/NanoKit/` — 核心模块化 Swift Package 源码：
  * `Sources/NanoCore` — 领域实体模型、原生 SQLite3 快照存储、LRU 磁盘缓存配额管家
  * `Sources/NanoVFS` — 双轨网盘协调器、115/百度/夸克/小雅/WebDAV 驱动、本地 HTTP 流式代理网关
  * `Sources/NanoScraper` — 文件名清洗器、本地 NFO 解析器、TMDB 在线刮削客户端
  * `Sources/NanoLiveTV` — M3U/TXT 解析、同名多线聚合、回看 URL 拼装、并发测速探针
  * `Sources/NanoRemoteHub` — 苹果 CMS JSON、TVBox/FongMi 订阅解析、自定义网页爬虫规则引擎
  * `Sources/NanoMusic` — 整轨 CUE 分轨器、LRC 歌词时间轴引擎
  * `Sources/NanoPlayerKit` — `AVPlayer + MPVKit` 双内核智能路由状态机
  * `Sources/NanoSync` — iCloud Keychain、WebDAV 快照同步、局域网扫码快传 Web 服务、Touch ID/PIN 隐私锁
  * `Sources/NanoDesignSystem` — 暗夜深空毛玻璃组件库与双端焦点交互修饰器
  * `Sources/NanoUI` — 全业务共享 SwiftUI 页面视图
  * `Tests/NanoKitTests` — 核心引擎单元测试集
