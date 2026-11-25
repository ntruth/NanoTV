# 视频播放能力补强设计：HDR / 转码 / 音频 / 画面 / 缓冲 / 字幕

- 日期：2026-11-22
- 状态：设计稿（部分已落地，2026-11-22 同步）
- 范围：`Sources/PlaybackCore`、`Sources/PhotosClone/Services/Video`、`Sources/PhotosClone/Features/Viewer`、`Sources/PhotosClone/Features/Settings`
- 事实基线：仓库当前代码 + 发布包内置 ffmpeg 9.0.2（ffmpeg-full + libplacebo + MoltenVK）；回退静态包为 ffmpeg 8.0.git（libzimg，无 libplacebo）
- 写作约束：本文只写「代码里有什么」「二进制实测到什么」和「按公开 API 能做到什么」；未实测的结论统一进入第 9 节，不写成既成事实

---

## 0. 摘要

本轮要补的六项能力，现状都不是「完全没有」，而是**没有收口成可配置的决策层**。当前 ffmpeg 参数集中在 `StreamPlanner`，HDR 判断散在 `VideoPlayback.swift`，音频策略写死在 `copyableAudioCodecs`，缓冲参数写死在 `VideoPlayerModel` 与 `RemoteRangeSource`，字幕偏好写死在 `autoLoadEmbeddedSubtitleIfNeeded`。继续按这个结构加功能，会出现三类问题：

1. 同一个视频在不同策略下生成的分片缓存互相覆盖（缓存键只含 `photoID + burnSuffix`）。
2. 参数散落在 4 个文件，改一个档位要动多处，无法做单元校验。
3. 没有「先计划、后执行」的中间层，失败降级只能靠重试，无法解释为什么走了这条路。

设计上的统一做法：**把六项能力都收敛成纯数据计划（Plan）→ 由 `StreamPlanner` 和播放器执行 → 计划的签名进入缓存键**。计划层不依赖 SwiftUI / AppKit，可以放进 `LumaCoreChecks` 做断言。

| # | 能力 | 当前实现 | 本轮要补的缺口 | 计划类型 | 状态 |
| --- | --- | --- | --- | --- | --- |
| 1 | HDR / 杜比视界 | 发布包内置 libplacebo；DV P5 在 HDR 屏保留原样、SDR 屏映射 | HDR10+ 动态元数据未处理；无「屏幕能力 → 输出模式」计划层；缓存键不含策略 | `HDRPlaybackPlan` | 部分落地 |
| 2 | 转码性能 | `TranscodeProfile` 已按像素率降档；可选 H.264 / HEVC / 低功耗 HEVC；边播边转与离线转码共用 | 无硬件解码 | `TranscodeProfile` | 已落地（兼容 / 高效 / 低功耗） |
| 3 | 音频直通 / 降混 | AC-3 / E-AC-3 / ALAC 直通；DTS / TrueHD 转 AC-3 5.1 | 直通实机验证；立体声降混；逐轨混合策略 | `AudioPlaybackPlan` | 已落地（直通 + 逐轨混合 + 降混开关） |
| 4 | 去隔行 / 画面比例 | 已探测 `field_order`，重编码链插入 `bwdif`；显示方式（适应 / 填充 / 拉伸 / 原始像素）、比例预设与平移已落地 | 烧进画面的裁剪（crop）不在首版 | `VideoTreatment` / `VideoFraming` | 已落地（显示层） |
| 5 | 网络缓冲策略 | 四选一「自适应 / 流畅 / 均衡 / 省流」，默认流畅 | 弱网计费感知；多码率 ABR | `BufferProfile` / `VideoBufferMode` | 已落地（三档 + 自适应） |
| 6 | 字幕偏好 | 语言优先级统一用于自动挂载、字幕菜单与在线搜索；forced 轨识别、手动选择记忆 | 云端自动挂载；语言优先级可编辑 | `SubtitlePreference` | 已落地（默认中文，无设置项） |

**本轮已落地（2026-11-22）**

| 模块 | 落地内容 | 证据 |
| --- | --- | --- |
| 视频运行时 | 发布包优先打包 ffmpeg-full 9.0.2 + libplacebo + MoltenVK（含全部 dylib）；缺失时回退静态 8.0.git | [build.sh](file:///Users/lijialong/Documents/gitlab/photos/build.sh#L105-L132)、`Vendor/ffmpeg-dv/VERSIONS.txt` |
| 杜比视界 P5 | libplacebo 链应用 DOVI RPU（`apply_dolbyvision=1`），并在 GPU 内顺带缩放 | [PlaybackFilters.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackFilters.swift#L20-L37) |
| Vulkan 初始化 | 子进程注入 `VK_ICD_FILENAMES`；启动 2 秒后后台预热一次 libplacebo 滤镜图 | [VideoSupport.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/VideoSupport.swift#L62-L92)、[FFmpegPrewarm.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/FFmpegPrewarm.swift#L1-L45) |
| 转码档位 | `TranscodeProfile` 按「宽 × 高 × 帧率」限制输出像素率，4K60 降到 1440p；码率随输出高度查表 | [TranscodeProfile.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/TranscodeProfile.swift#L1-L83) |
| 播放 / 离线转码 | 两条链路都改用 `h264_videotoolbox` + `TranscodeProfile`；非 HDR 转码也按档位缩放 | [StreamPlanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/StreamPlanner.swift#L205-L242)、[VideoSupport.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/VideoSupport.swift#L795-L845) |
| 杜比视界策略 | HDR 屏 `automatic` 保留 `dvh1` 交给系统解码；SDR 屏才映射。系统拒绝时按起流失败自动降级 | [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L1308-L1338) |
| zscale 回退修复 | 色调映射前用 `setparams` 把探测到的色彩参数写回帧；修复 ffmpeg 9 下 `no path between colorspaces` | [PlaybackFilters.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackFilters.swift#L20-L58) |
| 音频直通 | `copyableAudioCodecs` 已加入 `ac3 / eac3`；DTS / TrueHD 仍重编码 | [StreamPlanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/StreamPlanner.swift#L96-L100) |
| 网络缓冲 | 省流 / 均衡 / 流畅三档；默认流畅；远端按实测吞吐自适应降档 / 恢复 | [BufferProfile.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/BufferProfile.swift)、[BufferAdaptationState.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/BufferAdaptationState.swift) |
| 测试 | `LumaCoreChecks` 增加降档、码率、libplacebo 链尺寸、`setparams`、AC-3 直通断言 | [main.swift](file:///Users/lijialong/Documents/gitlab/photos/Tests/LumaCoreChecks/main.swift#L422-L470) |

**仍未落地**：`HDRPlaybackPlan`、硬件解码、多码率 ABR、云端自动挂载字幕。


**不做的事**（避免范围膨胀）：视频剪辑 / 转场 / 稳定、Atmos 对象音频渲染、HDR 屏幕强制切换、蓝光原盘菜单、逐帧色彩管理。这些与本次六个缺口不是同一层问题。

---

## 1. 事实基线

### 1.1 当前播放链路

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 940 430" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif">
  <defs>
    <marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto">
      <path d="M0,0 L10,5 L0,10 z" fill="#7a8494"/>
    </marker>
  </defs>
  <rect width="940" height="430" fill="#fbfbfd"/>
  <text x="24" y="30" font-size="15" font-weight="600" fill="#1d1d1f">Luma 视频播放链路与六个改造点</text>

  <!-- row 1 -->
  <rect x="24" y="52" width="150" height="62" rx="10" fill="#ffffff" stroke="#d9d9e3"/>
  <text x="99" y="76" text-anchor="middle" font-size="12" font-weight="600" fill="#1d1d1f">片源</text>
  <text x="99" y="94" text-anchor="middle" font-size="10" fill="#6e6e78">本地 / SMB / 网盘</text>

  <rect x="214" y="52" width="170" height="62" rx="10" fill="#ffffff" stroke="#d9d9e3"/>
  <text x="299" y="76" text-anchor="middle" font-size="12" font-weight="600" fill="#1d1d1f">探测</text>
  <text x="299" y="94" text-anchor="middle" font-size="10" fill="#6e6e78">AVFoundation + ffprobe</text>

  <rect x="424" y="52" width="200" height="62" rx="10" fill="#fff7ec" stroke="#e8a33d"/>
  <text x="524" y="76" text-anchor="middle" font-size="12" font-weight="600" fill="#8a5a13">计划层（部分落地）</text>
  <text x="524" y="94" text-anchor="middle" font-size="10" fill="#8a5a13">HDR / 音频 / 画面 / 缓冲 / 字幕</text>

  <rect x="664" y="52" width="252" height="62" rx="10" fill="#ffffff" stroke="#d9d9e3"/>
  <text x="790" y="76" text-anchor="middle" font-size="12" font-weight="600" fill="#1d1d1f">StreamPlanner + VideoStreamSession</text>
  <text x="790" y="94" text-anchor="middle" font-size="10" fill="#6e6e78">ffmpeg 参数唯一构造点</text>

  <!-- arrows row 1 -->
  <line x1="174" y1="83" x2="210" y2="83" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar)"/>
  <line x1="384" y1="83" x2="420" y2="83" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar)"/>
  <line x1="624" y1="83" x2="660" y2="83" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar)"/>

  <!-- row 2 -->
  <rect x="664" y="150" width="252" height="62" rx="10" fill="#ffffff" stroke="#d9d9e3"/>
  <text x="790" y="174" text-anchor="middle" font-size="12" font-weight="600" fill="#1d1d1f">本机 HLS 服务</text>
  <text x="790" y="192" text-anchor="middle" font-size="10" fill="#6e6e78">LocalHLSServer · 127.0.0.1</text>

  <rect x="424" y="150" width="200" height="62" rx="10" fill="#ffffff" stroke="#d9d9e3"/>
  <text x="524" y="174" text-anchor="middle" font-size="12" font-weight="600" fill="#1d1d1f">AVPlayer</text>
  <text x="524" y="192" text-anchor="middle" font-size="10" fill="#6e6e78">VideoPlayerModel</text>

  <rect x="214" y="150" width="170" height="62" rx="10" fill="#ffffff" stroke="#d9d9e3"/>
  <text x="299" y="174" text-anchor="middle" font-size="12" font-weight="600" fill="#1d1d1f">画面层</text>
  <text x="299" y="192" text-anchor="middle" font-size="10" fill="#6e6e78">AVPlayerLayer + SwiftUI</text>

  <rect x="24" y="150" width="150" height="62" rx="10" fill="#ffffff" stroke="#d9d9e3"/>
  <text x="99" y="174" text-anchor="middle" font-size="12" font-weight="600" fill="#1d1d1f">显示</text>
  <text x="99" y="192" text-anchor="middle" font-size="10" fill="#6e6e78">刷新率 / EDR 余量</text>

  <line x1="790" y1="114" x2="790" y2="146" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar)"/>
  <line x1="664" y1="181" x2="628" y2="181" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar)"/>
  <line x1="424" y1="181" x2="388" y2="181" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar)"/>
  <line x1="214" y1="181" x2="178" y2="181" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar)"/>

  <!-- annotations -->
  <rect x="24" y="256" width="892" height="146" rx="10" fill="#ffffff" stroke="#e4e4ee"/>
  <text x="40" y="280" font-size="12" font-weight="600" fill="#1d1d1f">六个改造点分别落在哪</text>

  <circle cx="52" cy="302" r="4" fill="#e8a33d"/><text x="64" y="306" font-size="11" fill="#3a3a44">① HDR / DV：探测结果与屏幕 EDR 余量进入计划层，决定 remux 还是 tone map</text>
  <circle cx="52" cy="324" r="4" fill="#e8a33d"/><text x="64" y="328" font-size="11" fill="#3a3a44">② 转码性能：计划层选择编码器 / 分辨率 / 码率 / 硬件解码，StreamPlanner 只负责拼参数</text>
  <circle cx="52" cy="346" r="4" fill="#e8a33d"/><text x="64" y="350" font-size="11" fill="#3a3a44">③ 音频：直通 / 降混 / 重编码三选一，写入 HLS 的 var_stream_map 与轨道语言标签</text>
  <circle cx="52" cy="368" r="4" fill="#e8a33d"/><text x="64" y="372" font-size="11" fill="#3a3a44">④ 去隔行进入 ffmpeg 滤镜链；画面比例只改显示层，不重编码</text>
  <circle cx="52" cy="390" r="4" fill="#e8a33d"/><text x="64" y="394" font-size="11" fill="#3a3a44">⑤ 缓冲：前向缓冲 / readrate / 预取窗口由档位统一注入；⑥ 字幕：探测 + 偏好共同决定默认轨</text>
</svg>

### 1.2 内置 ffmpeg 实测能力

以下为发布包内置二进制的直接输出（2026-11-22，`Luma.app/Contents/Resources/bin/ffmpeg`）：

| 项目 | 发布包（ffmpeg-full 9.0.2） | 回退静态包（8.0.git） |
| --- | --- | --- |
| 来源 | Homebrew `ffmpeg-full 9.0.2_3`，`--enable-libplacebo --enable-videotoolbox --enable-libzimg` | martin-riedl 静态包，仅 libzimg |
| libplacebo | **有**（`libplacebo` 滤镜可用） | **无**（`Unknown filter`） |
| 硬件编码 | `h264_videotoolbox`、`hevc_videotoolbox`、`prores_videotoolbox` | 同左 |
| 软件编码 | `libx264`、`libx265` | 同左 |
| H.264 VT 像素格式 | `videotoolbox_vld / nv12 / yuv420p` | 同左 |
| HEVC VT 像素格式 | `p010le / p210le`，支持 `main10` | 同左 |
| 去隔行 | `bwdif`、`yadif`、`yadif_videotoolbox`（Metal compute） | `bwdif`、`yadif` |
| 其他滤镜 | `zscale`、`tonemap`、`crop`、`cropdetect`、`scale_vt`、`subtitles`、`ass` | `zscale`、`tonemap`、`crop`、`cropdetect`、`scale_vt` |
| 硬件解码 | `videotoolbox` + `vulkan` | `videotoolbox` |
| libplacebo 关键选项 | `w / h`（输出尺寸）、`format`、`colorspace`、`color_primaries`、`color_trc`、`apply_dolbyvision`（默认 true）、`tonemapping` | — |

打包与运行方式：

- `build.sh` 优先复制 `Vendor/ffmpeg-dv/{bin,lib}` 到 `Contents/Resources`，并把 `VERSIONS.txt` 与 GPL 许可一并带入；找不到时调用 `Tools/make_vendor_runtime.sh` 现场生成，再退回静态包。
- 动态库约 100 个；libplacebo 通过 MoltenVK 初始化 Vulkan，子进程需要 `VK_ICD_FILENAMES`。
- 启动 2 秒后会后台跑一次最小 libplacebo 滤镜图，预热动态库、Vulkan 设备与着色器。


### 1.3 代码事实

| 事实 | 位置 |
| --- | --- |
| ffmpeg 参数唯一构造点；重编码码率来自 `TranscodeProfile` | [StreamPlanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/StreamPlanner.swift#L118-L260) |
| 可拷贝音频仅 `aac` / `alac` | [StreamPlanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/StreamPlanner.swift#L80-L98) |
| 像素率降档：4K60 → 1440p；码率按输出高度查表 | [TranscodeProfile.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/TranscodeProfile.swift#L15-L83) |
| 色调映射链支持输出尺寸；libplacebo 链内联 `w/h` | [PlaybackFilters.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackFilters.swift#L20-L37) |
| 缓存键仍只有 `photoID + burnSuffix`（尚未加策略签名） | [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoStreamSession.swift#L415-L427) |
| 生成提前量 >600s 挂起、<180s 恢复 | [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoStreamSession.swift#L217-L251) |
| 前向缓冲固定 8 秒 | [VideoPlayerModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoPlayerModel.swift#L247-L251) |
| readrate 本地 12 / 远端 6 | [StreamPlanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/StreamPlanner.swift#L125-L132) |
| 远端 Range 代理：8MB 分块、预取 6、并发 6 | [RemoteRangeSource.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/RemoteRangeSource.swift#L20-L35) |
| 卡顿自愈：12s 轻推、40s 重建流 | [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift#L230-L270) |
| HDR 策略入口（含 DV P5 判断） | [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L1302-L1317) |
| 离线转码已切 `h264_videotoolbox` + `TranscodeProfile` | [VideoSupport.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/VideoSupport.swift#L795-L838) |
| 内置 ffmpeg 查找顺序与 MoltenVK 环境变量 | [VideoSupport.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/VideoSupport.swift#L45-L125) |
| 启动后 libplacebo 预热 | [FFmpegPrewarm.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/FFmpegPrewarm.swift#L1-L45) |
| 播放会话把帧率与源尺寸传给 `StreamRequest` | [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift#L370-L385) |
| 仅按帧率切刷新率，不动 HDR 模式 | [DisplayModeMatcher.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Video/DisplayModeMatcher.swift#L14-L61) |
| 画面只有「适应 / 填充」 | [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L1676-L1705) |
| 内嵌字幕只挑「zh* / chi / zho / chs / cht / cn」，否则第一条 | [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L1264-L1279) |
| 外挂字幕取文件名最短者 | [SubtitleLoader.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Video/SubtitleLoader.swift#L20-L45) |
| 在线字幕搜索语言写死 `zh-cn,zh-tw` | [OpenSubtitlesClient.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Cinema/OpenSubtitlesClient.swift#L85-L100) |
| 探测结构里没有 `field_order`、字幕 `disposition`、`forced` | [PlaybackModels.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackModels.swift#L131-L163) |

---

## 2. HDR / 杜比视界

### 2.1 现状

- 探测层已经能拿到：`color_primaries / color_transfer / color_space / color_range / codec_tag / DOVI side data / dv_profile`；Matroska 的 DOVI 配置还会用 ffmpeg 读一次文件头补齐 profile（[VideoSupport.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/VideoSupport.swift#L409-L468)）。
- 色调映射：PQ / HLG 用 `zscale → linear → tonemap=hable → bt709`；杜比视界只有 `libplacebo` 才会应用 RPU（[PlaybackFilters.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackFilters.swift#L5-L20)）。
- 决策：`keepHDR` 直接保持原样；`toneMapSDR` 强制映射；`automatic` 在「DV P5 / 屏幕无 EDR」时映射（[VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L1302-L1317)）。
- 已知事实与约束：
  1. **发布包已内置 libplacebo**（ffmpeg-full 9.0.2 + MoltenVK），DV P5 走 `libplacebo=apply_dolbyvision=1`；只有回退到静态 8.0.git 时才没有 RPU 映射。
  2. 决策仍写在 `VideoPlayback.needsToneMapping`：DV 且无 libplacebo 时直接返回 false（保持原样并提示），不会烘错颜色。
  3. `DisplayModeMatcher` 只切刷新率，不参与 HDR 输出决策。
  4. HDR10+（ST 2094-40）动态元数据：zscale 链路按静态 HDR10 基线映射；libplacebo 链没有显式传 HDR10+ 参数，动态元数据利用情况待实测（T11）。
  5. 缓存键仍不含 HDR 策略：`keepHDR` 与 `toneMapSDR` 生成的结果会落在同一个 `<photoID>.hls` 目录。

### 2.2 目标行为矩阵

| 片源 | 屏幕 EDR 余量 | 策略 | 输出路径 | 说明 |
| --- | --- | --- | --- | --- |
| HDR10 / HLG | > 1.0 | 自动 | remux，保留 BT.2020 / PQ / HLG 标签 | 交给 AVPlayerLayer 原生输出 |
| HDR10 / HLG | ≤ 1.0 | 自动 | transcode + zscale tone map → BT.709 | 现有链路 |
| DV P5 | > 1.0 | 自动 | 优先 remux（系统能解 DV 时）；否则 libplacebo → SDR | 需要运行时确认 AVPlayer 是否接受 `dvh1` |
| DV P5 | ≤ 1.0 | 自动 | 有 libplacebo → tone map；无 → 保持原样并提示 | 当前已提示，但提示后仍可能偏色 |
| DV P8.1 | 任意 | 自动 | remux；不支持 DV 时按 HDR10 基线解码 | P8 的 BL 兼容 HDR10 |
| DV P7 | 任意 | 自动 | 有 libplacebo → tone map；无 → 保持原样 | P7 依赖 EL + RPU，映射失败风险最高 |
| 任意 HDR | 任意 | 映射到 SDR | 强制 tone map | 用户显式选择 |
| 任意 HDR | 任意 | 保持 HDR | remux | 用户显式选择 |

> **T8 实测（2026-11-22，内置 Retina XDR，`maxPotentialEDR=16`）**：AVPlayer 对该 DV P5 样片 `isPlayable=true`，轨道 tag 为 `dvh1`；解码后的 `CVPixelBuffer` 携带 `DolbyVisionRPUData` 与 `CVImageBufferTransferFunction=SMPTE_ST_2084_PQ`。说明 RPU 在 AVPlayer 管线中保留，显示链路可以应用。
>
> 注意：`AVAssetImageGenerator` / CIImage 导出的 PNG 只含 base layer，不含 RPU 应用结果；用截帧与 libplacebo 输出做 SSIM 会误判为「未应用 DV」。颜色验收必须在 HDR 显示链路上目视，不能只看导出的 PNG。
>
> 据此已落地：`automatic` 下 DV P5 在 HDR 屏保留 remux，SDR 屏才 tone map；若系统拒绝该码流，`PlaybackSession` 按起流失败自动降级为重编码 + 映射。

### 2.3 设计

**（1）计划层：`HDRPlaybackPlan`（纯结构，放 `PlaybackCore`）**

输入：

| 字段 | 来源 |
| --- | --- |
| `color` / `dvProfile` | `VideoProbe.color` |
| `edrHeadroom` / `potentialHeadroom` | `NSScreen`（公共 API 只有这两个值） |
| `policy` | `VideoHDRMode` |
| `supportsToneMapping` / `supportsLibplacebo` | `FFmpeg` 探测结果 |

输出：

| 字段 | 用途 |
| --- | --- |
| `mode: .remux / .transcode` | 传给 `StreamRequest` |
| `toneMapChain: String?` | 传给 `StreamPlanner` |
| `preserveDolbyVisionTag: Bool` | 决定 `dvh1 / dvhe` 是否保留 |
| `signature: String` | 进入缓存键，避免策略切换后命中旧结果 |
| `reason: String` | 写一条诊断日志，解释为什么这样选 |

**（2）DV P5 专用路径：随包内置 ffmpeg-full（已落地）**

实际采用「构建期打包」而不是「运行期下载增强包」：

- `build.sh` 优先复制 `Vendor/ffmpeg-dv/{bin,lib}`（ffmpeg-full 9.0.2 + libplacebo + MoltenVK + 约 100 个 dylib）到 `Contents/Resources`；`Vendor/ffmpeg-dv` 缺失时调用 `Tools/make_vendor_runtime.sh` 从本机 Homebrew 现场生成。
- 找不到 ffmpeg-full 时退回静态 8.0.git（zscale 可用，P5 会偏绿），并在设置页显示「未安装：杜比视界 P5 会偏绿，HDR10 / HLG 正常」。
- 运行时查找顺序：App 内置 `Contents/Resources/bin/ffmpeg` → Homebrew `ffmpeg-full` → Homebrew `ffmpeg` → 系统路径。
- libplacebo 走 Vulkan：`VK_ICD_FILENAMES` 指向内置 `lib/MoltenVK_icd.json`，由 `PlaybackEnvironment.apply(to:)` 注入所有 ffmpeg 子进程。
- 冷启动约 1 秒的库加载与设备创建由 `FFmpegPrewarm` 在启动 2 秒后后台消化。

剩余工作：

| 项 | 现状 |
| --- | --- |
| 版本记录 | `VERSIONS.txt` 已随包附带，但设置页还没有展示 |
| 更新策略 | 跟随本机 Homebrew 版本，没有固定版本清单与 SHA-256 |
| HDR10+ | libplacebo 链未显式传动态元数据参数（T11） |

**（3）HDR 输出模式匹配：明确能力边界**

公开 API 事实：

- `NSScreen.maximumExtendedDynamicRangeColorComponentValue` / `maximumPotentialExtendedDynamicRangeColorComponentValue` 只读。
- `CGDisplayCopyAllDisplayModes` 可以切刷新率与分辨率，没有公开的「切 HDR 模式」字段。
- `AVPlayerLayer` 的 EDR 输出由系统与显示器状态决定，App 没有开关。

因此「HDR 输出模式匹配」在本项目里定义为：

1. **能力匹配**：读取当前屏幕 EDR 余量，决定 remux 还是 tone map（2.2 矩阵）。
2. **刷新率匹配**：保留现有 `DisplayModeMatcher`，只改刷新率不动分辨率。
3. **码流匹配**：HDR 保持时确保 `dvh1 / hvc1 / bt2020 / smpte2084` 标签正确写回容器；tone map 时确保输出标记为 `bt709 / tv`。
4. **不做**：用私有 API 强制显示器进入 HDR 模式。文档与设置页必须写清这是系统行为。

**（4）缓存键修正（必须先做）**

当前 `cacheDirectoryName` 只有 `photoID + burnSuffix`。HDR 策略从「保持」切到「映射」、或音频策略从 AAC 切到直通时，会命中旧分片。改为：

```
photoID + burnSuffix + plan.signature + version
```

`signature` 至少包含：`mode / dvProfile / toneMapChain 版本 / 音频计划 / 去隔行 / 转码档位 / 输出分辨率`。这是本轮所有能力共用的基础设施。

### 2.4 改动点

| 文件 | 改动 | 状态 |
| --- | --- | --- |
| `Sources/PlaybackCore/HDRPlaybackPlan.swift`（新增） | 纯计划与矩阵，避免 UI 里散落 if | 未开始 |
| `Sources/PlaybackCore/StreamPlanner.swift` | tone map 链已按输出尺寸构造；`treatment` / `signature` 未加 | 部分 |
| `Sources/PlaybackCore/VideoStreamSession.swift` | 缓存键加入签名；诊断日志记录计划原因 | 未开始 |
| `Sources/PhotosClone/Services/Media/VideoSupport.swift` | 已内置 ffmpeg-full + MoltenVK 查找与环境注入；`max_cll / max_fall` 探测未加 | 部分 |
| `Sources/PhotosClone/Features/Viewer/VideoPlayback.swift` | HDR 屏保留 DV、SDR 屏映射已落地；`needsToneMapping` 仍未抽到计划层 | 部分 |
| `Sources/PhotosClone/Features/Settings/SettingsModels.swift` | `automatic` 文案已改为「HDR 屏保留、SDR 屏映射」 | 已落地 |
| `Sources/PhotosClone/Services/Video/DisplayModeMatcher.swift` | 增加 `snapshot()` 返回 EDR 余量与当前模式 | 未开始 |

### 2.5 验收口径

| 项 | 可观察结果 | 方法 | 状态 |
| --- | --- | --- | --- |
| 运行时能力 | 发布包 `-filters` 含 `libplacebo`；`-hwaccels` 含 `vulkan` | `Luma.app/Contents/Resources/bin/ffmpeg -filters` | 已通过 |
| 映射链选择 | DV P5 日志显示 `HDR 色调映射：libplacebo ...`；回退静态包时显示「缺少 libplacebo，未映射」 | 诊断日志 | 已具备 |
| 模式判定 | 同一片源在 `automatic / toneMapSDR / keepHDR` 下日志的 `mode` 与 `reason` 不同 | 诊断日志 | 待计划层落地 |
| 缓存隔离 | 切换策略后生成新的 `.hls` 目录 | 查看 `resources/transcodes` | 未通过（键未加签名） |
| 标签正确 | remux 输出 `ffprobe` 显示 `bt2020 / smpte2084 / dvh1`；tone map 输出 `bt709` | `ffprobe -show_streams` | 待实测 |
| DV P5 画面 | 发布包下画面不偏绿 | 目视 | 待实测 |
| HDR 屏 | `keepHDR` 下 AVPlayer 不报错、EDR 余量 > 1 | 实机 | 待实测 |

---

## 3. 转码性能

### 3.1 现状

| 场景 | 当前参数 | 事实 |
| --- | --- | --- |
| 边下边播重编码 | `h264_videotoolbox` + `TranscodeProfile` 推导的 `b:v / maxrate / bufsize` | 已落地；4K60 会降到 1440p |
| 离线「转换为兼容格式」 | `h264_videotoolbox` + `TranscodeProfile` | 已落地；`frameRate` 由探测结果传入，4K60 会降档 |
| 硬件解码 | 未启用 | ffmpeg 默认软件解码 |
| 关键帧 | `force_key_frames 2s` | 切片稳定，首段不用等长 GOP |
| 切片 | `hls_time 2`、`hls_init_time 0.5` | 首段较快 |
| 像素率上限 | `250_000_000 px/s`（宽 × 高 × 帧率） | 4K30 保持原分辨率，4K50 / 4K60 降档 |
| 输出高度阶梯 | 2160 / 1600 / 1440 / 1200 / 1080 / 720 | 宽度按源比例取偶数 |
| 4K HDR 处理 | libplacebo 在 GPU 内完成映射与缩放 | zscale 回退路径仍是 CPU `gbrpf32le` |

`TranscodeProfile` 代码注释记录的本机实测基线（M5 基础款，4K60 HEVC → libplacebo bt.2390 → H.264 VideoToolbox，10 秒素材）：

| 输出 | 耗时 | 实时倍率 |
| --- | --- | --- |
| 4K | 8.6s | ≈1.16× |
| 1440p | 5.8s | ≈1.74× |
| 1080p | 5.1s | ≈1.96× |

结论：4K 输出贴着实时，容易周期性缓冲；把像素率压到 2.5 亿/秒以内可以把余量拉到 1.7× 以上。

### 3.2 设计（基础版已落地）

**（1）统一 `TranscodeProfile`（基础版已落地）**

| 档位 | 编码器 | 像素格式 | 状态 |
| --- | --- | --- | --- |
| 兼容（当前唯一） | `h264_videotoolbox` + `-allow_sw 1` | `yuv420p` | 已落地 |
| 性能 | `hevc_videotoolbox`（`main10`） | `p010le` | 未开始 |
| 低功耗 | `hevc_videotoolbox` + `-power_efficient 1 -prio_speed 1` | `p010le` | 未开始 |
| 高压缩 | `libx265` / `libx264` | 按源 | 未开始 |

已实现的码率表（`TranscodeProfile.bitrate(forHeight:)`）：

| 输出高度 | 目标码率 |
| --- | --- |
| ≥ 2000 | 20 Mbps |
| 1400–1999 | 12 Mbps |
| 1000–1399 | 8 Mbps |
| < 1000 | 5 Mbps |

- `maxrate = 1.35 × b:v`，`bufsize = 2 × b:v`（与代码一致）。
- 降档依据是像素率而不是分辨率：`宽 × 高 × 帧率 > 250_000_000` 时，从 `2160 / 1600 / 1440 / 1200 / 1080 / 720` 里取第一个满足上限的高度。
- 已修复：离线转码把真实 `frameRate` 传进 `TranscodeProfile`，4K60 源会降到 1440p。

**（2）硬件解码（未开始）**

内置 ffmpeg 支持 `videotoolbox` 硬解（发布包还多一个 `vulkan`）。接入方式：

```
-hwaccel videotoolbox -hwaccel_output_format videotoolbox
```

注意：`zscale` / `bwdif` / `subtitles` 都需要系统内存帧，必须在滤镜前显式 `hwdownload,format=nv12|p010le`。是否净收益取决于 Mac 型号与滤镜链，**必须实测后再决定是否默认开启**；不达标就保持软解。

**（3）离线转码切硬件（已落地）**

`VideoSupport.transcode` 已改为 `h264_videotoolbox` + `TranscodeProfile`，并传入 `sourceSize`。HDR 源保持 HDR 时的 HEVC `p010le` 输出仍未实现。

**（4）低功耗与发热控制（未开始）**

| 参数 | 作用 |
| --- | --- |
| `-realtime 1` | 提示编码器按实时优先 |
| `-prio_speed 1` | 速度优先 |
| `-power_efficient 1` | 更省电的编码路径（系统支持时） |
| `-spatial_aq 1` | 空间自适应量化，低码率下减少块效应 |
| 输出分辨率上限 | 4K 源可降到 1080p |
| 提前量阈值 | 低功耗档把 600s/180s 收紧到 180s/60s，减少后台连续编码 |

**（5）不做的事**

- 编码会话常驻与跨 seek 复用：现有架构每次重建 ffmpeg 进程，做进程内复用会改动会话生命周期，收益需实测后再评估。
- 多码率 ABR 见第 6 节，不在本节。

### 3.3 改动点

| 文件 | 改动 | 状态 |
| --- | --- | --- |
| `Sources/PlaybackCore/TranscodeProfile.swift`（新增） | 像素率降档、码率表、`maxrate/bufsize` | 已落地 |
| `Sources/PlaybackCore/StreamPlanner.swift` | 编码器与码率从 `profile` 读取 | 已落地 |
| `Sources/PhotosClone/Services/Media/VideoSupport.swift` | 离线转码改用 `TranscodeProfile`；HDR 输出走 HEVC main10 | 部分（H.264 已切，HEVC 未做） |
| `Sources/PhotosClone/Features/Settings/SettingsModels.swift` | 新增「转码质量 / 低功耗」设置 | 未开始 |
| `Sources/PhotosClone/Features/Settings/CinemaSettingsSection.swift` | 设置项入口 | 未开始 |
| `Tests/LumaCoreChecks/main.swift` | 降档、码率、tone map 链尺寸断言 | 已落地 |

### 3.4 验收口径

| 项 | 方法 | 说明 | 状态 |
| --- | --- | --- | --- |
| 降档正确 | `swift run LumaCoreChecks` | 4K60 → 1440p、4K24 保持 4K、1080p60 不降档 | 已通过 |
| 编码器生效 | 日志记录最终参数；`ffprobe` 查看缓存分片编码 | 必须是 `h264_videotoolbox` | 已具备 |
| 首段耗时 | 记录「首段就绪 ms」（已有日志） | 同一片源对比改动前后 | 待实测 |
| 持续生成速度 | 记录生成末尾随时间变化（已有 `generatedEndSeconds`） | 目标：≥ 1.0× 实时才允许边播边转 | 已有基线（1.16×–1.96×） |
| 4K 发热 | 活动监视器 CPU / 能耗，连续播放 10 分钟 | 需要低功耗档后才能对比 | 未开始 |
| 离线转码 | `time ffmpeg ...` 对比 libx264 与 VT | 不以估算值代替实测 | 待实测 |

阈值在拿到本机基线后再写死，本文不预设。

### 3.5 基线实测（2026-11-22）

环境：MacBook Pro 内置 Retina XDR（`maxEDR=1.2`，`maxPotentialEDR=16`），HEVC 硬件解码可用，macOS 27.0.1 arm64；ffmpeg 使用 `Vendor/ffmpeg-dv/bin/ffmpeg` 9.0.2。素材为 10 秒合成片，直接跑与 `StreamPlanner` 相同的参数，不含 App 层探测与进程启动开销。

**4K60 SDR HEVC Main10（20 Mbps 源）→ H.264 VideoToolbox**

| 输出 | 墙钟 | 实时倍率 | user CPU |
| --- | --- | --- | --- |
| 4K 20 Mbps | 9.44s | 1.06× | 16.3s |
| 1440p 12 Mbps | 4.19s | 2.39× | 18.6s |
| 1080p 8 Mbps | 3.02s | 3.31× | 16.9s |

结论：4K60 保持 4K 只有 1.06×，必然周期性缓冲；`TranscodeProfile` 把它压到 1440p 是对的。

**4K30 HDR10（BT.2020 / PQ，10 Mbps 源）→ 色调映射 + H.264 VideoToolbox**

| 滤镜链 / 输出 | 墙钟 | 实时倍率 | user CPU |
| --- | --- | --- | --- |
| libplacebo 4K 20 Mbps | 6.32s | 1.58× | 8.9s |
| libplacebo 1440p 12 Mbps | 5.15s | 1.94× | 9.9s |
| zscale + `setparams` 4K | 6.45s | 1.55× | 39.6s |
| zscale + `setparams` 1440p | 3.95s | 2.53× | 23.5s |

结论：

- 4K30 像素率约 2.49 亿/秒，未触发降档，1.58× 可用。
- zscale 墙钟与 libplacebo 接近，但 CPU 时间约为 4 倍；有 libplacebo 时应优先使用，发热更可控。
- **zscale 不带 `setparams` 时直接失败**：ffmpeg 9 对只有容器层色彩标记的片源没有把色彩参数挂到解码帧，zscale 报 `no path between colorspaces`。已在 `PlaybackFilters` 前置 `setparams` 修复并加断言。

**其他样片**

| 样片 | 探测结果 | 说明 |
| --- | --- | --- |
| 1080i（x264 隔行） | `field_order=tt` | 当前探测不读该字段，也没有去隔行 |
| AC-3 5.1 MKV | `ac3 / 6ch` | 已加入可直通集合 |
| E-AC-3 5.1 MKV | `eac3 / 6ch` | 已加入可直通集合 |
| DTS 5.1 MKV | `dts / 6ch` | 仍重编码 AAC |
| TrueHD 5.1 MKV | `truehd / 6ch` | 仍重编码 AAC |
| DV P5 MP4 | `dvh1 / Main10 / 1080p` | T8 见 §2.2：AVPlayer 管线携带 `DolbyVisionRPUData` |

**App 层尚未测量**：首段就绪 ms、播放中卡顿次数、真实网盘带宽下的生成领先。这些需要跑 `Luma.app` 并读取诊断日志，合成片直跑无法替代。

---

## 4. 音频直通 / 降混

> 状态：已落地（AC-3 / E-AC-3 / ALAC 直通；DTS / TrueHD → E-AC-3 1536k；逐轨混合直通 / 重编码；**默认保持原音质**，「立体声」降混需手动开启）。

### 4.1 现状

| 行为 | 代码事实 |
| --- | --- |
| 可直通 | `aac` / `alac` / `ac3` / `eac3`（按 codec 判定，不限制声道） |
| AC-3 / E-AC-3 | fMP4 HLS 中 AVPlayer 实际装载 `soun:ac-3` / `soun:ec-3` 并起播（rate=1） |
| ALAC 多声道 | ALAC 5.1 实测可直通（`soun:alac`，首片 94 包），因此不因声道数拒绝 |
| DTS / TrueHD(MLP) | 重编码为 E-AC-3 1536k / 6ch，而不是 AC-3 640k |
| 其余（FLAC / Opus / Vorbis / MP3） | 重编码为 AAC（6ch 512k / 2ch 256k） |
| 多音轨 | 只有全部轨道都可直通时才装进一个 HLS 会话 |
| 声道 | 默认保持源声道；AAC >2 声道给 512k；E-AC-3 固定 `-ac 6` |
| 音频延迟 | 非 0 时强制重编码 |
| 原生 MP4 直连 | 走 AVPlayer，不受上述策略影响 |

### 4.2 分层策略

| 源编码 | 目标 | 条件 | 实现 |
| --- | --- | --- | --- |
| AAC / ALAC | 直通 | 始终 | `-c:a copy` |
| AC-3 / E-AC-3 | 直通 | 已实测（5.1，含 seek 会话） | `-c:a copy` |
| E-AC-3 JOC（Atmos） | 直通 | 同上；JOC 元数据是否保留单独验证 | `-c:a copy` |
| DTS / DTS-HD / TrueHD(MLP) | E-AC-3 | 多声道（>2） | `-async 1 -c:a eac3 -b:a 1536k -ac 6` |
| FLAC / Opus / Vorbis / MP3 | AAC | 其余情况 | `-async 1 -c:a aac -b:a 512k/256k` |
| 任意多声道 | 降混立体声 | 设置里手动选「立体声」 | 已实现，默认关闭（`AudioDownmixMode.source`） |
| 任意 | 保持多声道 | 默认 | 不加 `-ac`（E-AC-3 固定 6ch） |

**关键约束：直通失败必须可回退。** 失败路径分两层：ffmpeg 非零退出（编码器 / 滤镜 / 封装）会从 remux 降级为 transcode；网盘 / 鉴权失败由 `RemoteRangeSource.onFailure` 直接上报，不再无谓重编码。直通成功后如果 AVPlayer 没有音频轨，界面会表现为「有画面没声音」。已加运行时检查（多音轨看 audible 组，单音轨看 `AVPlayerItem.tracks`）：

1. 会话启动后读取 `engine.audioOptions`。
2. 若为空且源有音轨 → 记录诊断，关闭直通，按 AAC 重建一次。
3. 重建结果写入缓存签名，避免下次再踩。

**多音轨混合处理。** ffmpeg 支持按流指定编码器：

```
-map 0:a:0 -map 0:a:1
-c:a:0 copy -c:a:1 aac -b:a:1 256k
```

因此「全部可直通才多轨」的限制可以放开为「逐轨决定」，`var_stream_map` 仍按音轨分组生成。

### 4.3 改动点

| 文件 | 改动 |
| --- | --- |
| `Sources/PlaybackCore/AudioPlaybackPlan.swift`（新增） | 逐轨决策 + 降混模式 + 语言排序 |
| `Sources/PlaybackCore/StreamPlanner.swift` | 使用逐轨编码参数；`var_stream_map` 支持混合直通 / 重编码 |
| `Sources/PlaybackCore/VideoPlayerModel.swift` | 增加 `hasPlayableAudio` 观察，供回退判断 |
| `Sources/PlaybackCore/PlaybackSession.swift` | 直通无音轨时触发一次 AAC 重建 |
| `Sources/PhotosClone/Features/Settings/*` | 新增「音频输出：自动 / 立体声 / 保持多声道」 |

### 4.4 验收口径

| 项 | 方法 |
| --- | --- |
| 直通是否真的生效 | 缓存 `init.mp4` / 分片用 `ffprobe` 看 `codec_name=ac3/eac3` |
| 播放器是否能选到轨 | 播放器音轨菜单数量与源一致 |
| 降混 | `ffprobe -show_streams` 显示 `channels=2` |
| 回退 | 人为禁用直通后，缓存重建且菜单仍有音轨 |
| 音画同步 | 继续沿用 `video-av-sync-diagnosis-2026-11.md` 的测试片段 |

**当前状态**：AC-3 / E-AC-3 / ALAC 已进入默认直通白名单，并有参数断言与实机轨道验证；「直通后没有音轨 → 自动回退 AAC」的运行时检查已落地（多音轨看 audible 组，单音轨看 `AVPlayerItem.tracks`）。T1 已通过轨道层面验证（含 3 秒 seek 会话）；Atmos（T2）仍未闭环，不建议宣传为支持。逐轨混合与立体声降混仍是设计项。

---

## 5. 去隔行 / 画面比例

> 状态：已落地（`field_order` 探测 + `bwdif`；隔行源跳过原生直读；显示方式适应 / 填充 / 拉伸 / 原始像素；比例预设 16:9 / 4:3 / 2.35:1 / 1:1 + 平移，纯显示层不改转码）。

### 5.1 现状

- 探测没有读 `field_order`，无法判断隔行。
- ffmpeg 滤镜链只有字幕与 tone map，没有 `bwdif / yadif`。
- 画面只有 `.resizeAspect` 与 `.resizeAspectFill` 两档，加手动 90° 旋转。
- 没有裁剪、比例预设、1:1 像素显示、平移。

### 5.2 去隔行

**检测**

- `ffprobe -show_streams` 的 `field_order`：`tt / bb / tb / bt` 视为隔行；`progressive` 视为逐行。
- 对 `field_order=unknown` 的源，可选跑 1 秒 `idet` 采样，取 `TFF/BFF` 比例。
- 探测结果加入 `VideoProbe.fieldOrder` / `isInterlaced`。

**处理**

| 场景 | 处理 |
| --- | --- |
| 需要 ffmpeg 转码 | 滤镜链最前面插入 `bwdif=mode=send_frame:parity=auto:deint=all` |
| 已走 VideoToolbox 硬解 / 硬滤镜 | 可选 `yadif_videotoolbox`（发布包 Metal compute 版本），避免把帧下载回系统内存 |
| 系统原生可直连但探测为隔行 | 强制走 ffmpeg 重编码，因为 AVPlayer 没有去隔行开关 |
| 用户关闭去隔行 | 不插入滤镜 |

说明：`bwdif` 默认 `mode=send_field` 会把每个场输出成一帧，帧率翻倍；播放场景必须显式写 `send_frame`。

**顺序**：`bwdif → tone map → subtitles`。字幕烧录放在去隔行与色调映射之后，避免 SDR 字幕被二次映射变暗。

> 当前代码仍是「字幕 → tone map」（[StreamPlanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/StreamPlanner.swift#L197-L221)），上表是待实现的目标顺序；改成「先映射、后烧录」后，HDR 烧录场景的字幕亮度会变化，需要目视验收。

### 5.3 画面比例

显示层做成 `VideoFraming`，不重编码：

| 模式 | 实现 |
| --- | --- |
| 适应 | `AVLayerVideoGravity.resizeAspect` |
| 填充 | `.resizeAspectFill` |
| 拉伸 | `.resize` |
| 原始像素 | 按 `presentationSize` 的 1:1 尺寸居中，超出容器时裁切 |
| 比例预设 | 容器按目标比例裁切，播放层 `resizeAspectFill`，支持上下 / 左右平移 |
| 手动旋转 | 保留现有 90° 步进，叠加在 framing 之上 |

比例预设首版：`16:9 / 4:3 / 2.35:1 / 1:1 / 源比例`。裁剪只作用于显示，不影响截图与导出（导出仍按原片）。

若后续要做「烧进画面的裁剪」，再把 crop 参数加入 `VideoTreatment`，走 ffmpeg `crop=w:h:x:y`；首版不做。

### 5.4 改动点

| 文件 | 改动 |
| --- | --- |
| `Sources/PlaybackCore/PlaybackModels.swift` | `VideoProbe` 增加 `fieldOrder / isInterlaced` |
| `Sources/PhotosClone/Services/Media/VideoSupport.swift` | ffprobe 解析 `field_order`；可选 `idet` 采样 |
| `Sources/PlaybackCore/VideoTreatment.swift`（新增） | 去隔行 / 裁剪参数与签名 |
| `Sources/PlaybackCore/StreamPlanner.swift` | 滤镜链接入 `bwdif` |
| `Sources/PhotosClone/Features/Viewer/VideoPlayback.swift` | `playerFrame` 支持拉伸 / 裁剪 / 比例预设 |
| `Sources/PhotosClone/Features/Settings/*` | 「去隔行：自动 / 总是 / 关闭」「画面比例默认值」 |

### 5.5 验收口径

| 项 | 方法 |
| --- | --- |
| 隔行检测 | 用一段 1080i 样片，日志显示 `field_order=tt` 且触发去隔行 |
| 画面锯齿 | 同一帧暂停截图对比，隔行梳齿消失 |
| 比例预设 | 2.35:1 样片切 16:9 预设后上下裁切、无拉伸变形 |
| 操作持久化 | 退出重进后保留上次 framing |

---

## 6. 网络缓冲策略

> 状态：三档 + 远端网络自适应已落地；设置页四选一「自适应 / 流畅 / 均衡 / 省流」，默认流畅；弱网计费感知与多码率 ABR 未做。

### 6.1 现状

| 参数 | 当前值 | 位置 |
| --- | --- | --- |
| 前向缓冲 | 由档位决定：4 / 8 / 16 秒，默认 16 | `VideoPlayerModel.load` |
| 远端 readrate | 由档位决定：3× / 6× / 10×，默认 10× | `StreamPlanner` |
| 本地 readrate | 固定 12× | `StreamPlanner` |
| 生成提前量 | 省流 180/60s、均衡 600/180s、流畅 1200/300s | `VideoStreamSession` |
| Range 分块 | 4 / 8 / 16 MB | `RemoteRangeSource` |
| 保留分块 | 4 / 8 / 12 块 | `RemoteRangeSource` |
| 预取窗口 | 3 / 6 / 8 | `RemoteRangeSource` |
| 并发下载 | 3 / 6 / 8 | `RemoteRangeSource` |
| 请求超时 | 30s / 资源 3600s | `RemoteRangeSource` |
| 401/403 | 重新解析直链并重试一次 | `RemoteRangeSource` |
| 卡顿自愈 | 12s 轻推、40s 重建 | `PlaybackSession` |

缺口：没有吞吐测量；没有弱网 / 计费网络感知；HLS 只有一个 variant，AVPlayer 无法做码率自适应。

### 6.2 设计

**（1）`BufferProfile` 档位（已落地）**

| 档位 | 前向缓冲 | 远端 readrate | 提前量挂起/恢复 | 预取 | 保留分块 | 分块大小 | 并发 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 省流 | 4s | 3× | 180s / 60s | 3 | 4 | 4 MB | 3 |
| 均衡 | 8s | 6× | 600s / 180s | 6 | 8 | 8 MB | 6 |
| 流畅（默认） | 16s | 10× | 1200s / 300s | 8 | 12 | 16 MB | 8 |

- 默认档位由 `BufferProfile.defaultProfile` 与 `AppSettings` 初值共同保证为「流畅」。
- 前向缓冲可在播放中修改（`AVPlayerItem.preferredForwardBufferDuration`）。
- readrate、预取窗口、分块大小需要重建会话；设置里切换后对下一次起流生效。

**（2）吞吐自适应（已落地）**

`RemoteRangeSource` 每完成一块下载，用「字节数 / 耗时」上报一次吞吐；`VideoStreamSession` 在每个 pacing tick（约 3 秒）用「已生成分片字节数 / 已生成秒数」估算当前内容码率，再交给 `BufferAdaptationState` 判定：

| 条件 | 动作 |
| --- | --- |
| 领先 < 5s，或吞吐 < 内容码率 × 0.85，连续 2 次 | 降一档（流畅 → 均衡 → 省流） |
| 领先 > 120s，且吞吐 > 内容码率 × 1.8，连续 3 次 | 升一档，最高不超过用户在设置里选的档位 |
| 两次切档之间 | 至少间隔 20 秒（冷却） |

生效范围：

- 前向缓冲：`AVPlayerItem.preferredForwardBufferDuration` 立即调整。
- 生成提前量阈值：下一次 pacing tick 起按新档位执行。
- Range 预取窗口 / 并发：`RemoteRangeSource.updateProfile` 立即调整；分块大小保持不变。
- readrate：当前 ffmpeg 进程不重启，仍按起播档位执行；下一次起流按设置档位执行。

边界：

- 只有远端片源有 Range 代理，本地盘 / SMB 直接跳过自适应。
- 设置里的档位是**上限**：用户选省流时不会被自动升档；选流畅时允许临时降到均衡 / 省流，网络恢复后再升回流畅。
- 设置页把「自适应 / 流畅 / 均衡 / 省流」放在同一个分段控件里，默认「流畅」：选「自适应」时以流畅为上限并开启降档，选其余三项则固定该档位、不做自适应。
- 起播先攒 4–8 秒生成量（按档位，最多多等 6 秒）再交给播放器：只给首段 2 秒缓冲时，SMB / 网盘上的高码率片源会在出画面后立刻耗尽，表现为「一开播就卡一下」。

**（3）弱网与计费网络**

- 用 `NWPathMonitor` 监听 `isExpensive / isConstrained / unsatisfied`。
- 进入计费网络：默认暂停后台生成（保留当前播放所需），提示用户；用户可选「继续缓存」。
- 网络不可用：保留当前已生成分片，恢复后先探测 Range 再续传，不从头重建。

**（4）多码率 ABR（第二阶段）**

当前 HLS 只有一个 variant，AVPlayer 的 ABR 没有可选项。要真正实现「弱网自动降清晰度」，需要让 ffmpeg 同时输出两条 variant：

```
-var_stream_map "v:0,agroup:aud,name:1080p v:1,agroup:aud,name:720p a:0,agroup:aud,default:yes"
```

代价是转码开销约翻倍。建议先做档位与自适应，再根据实测决定是否上 ABR；不在首版强行加入。

### 6.3 改动点

| 文件 | 改动 | 状态 |
| --- | --- | --- |
| `Sources/PlaybackCore/BufferProfile.swift`（新增） | 三档参数、默认流畅 | 已落地 |
| `Sources/PlaybackCore/BufferAdaptationState.swift`（新增） | 吞吐驱动的降档 / 升档与滞回 | 已落地 |
| `Sources/PlaybackCore/StreamPlanner.swift` | 远端 readrate 从档位读取 | 已落地 |
| `Sources/PlaybackCore/RemoteRangeSource.swift` | 分块 / 预取 / 并发从档位注入；上报吞吐；自适应调整预取 | 已落地 |
| `Sources/PlaybackCore/VideoStreamSession.swift` | 提前量阈值、吞吐采样、码率估算与档位切换；起播前攒 4–8 秒缓冲 | 已落地 |
| `Sources/PhotosClone/Services/Media/VideoSupport.swift` | 网络卷 MKV / AVI 跳过 AVFoundation 探测；ffprobe 限 `-probesize 5M -analyzeduration 1s`，远程超时 15s | 已落地 |
| `Sources/PlaybackCore/VideoPlayerModel.swift` | 前向缓冲可配置、可在线调整 | 已落地 |
| `Sources/PlaybackCore/PlaybackSession.swift` | 自适应结果同步到播放器前向缓冲 | 已落地 |
| `Sources/PhotosClone/Features/Settings/*` | 网络缓冲四选一「自适应 / 流畅 / 均衡 / 省流」，默认流畅 | 已落地 |

### 6.4 验收口径

| 项 | 方法 | 状态 |
| --- | --- | --- |
| 默认值 | `LumaCoreChecks` 断言默认档为流畅、三档参数 | 已通过 |
| 自适应阈值 | `LumaCoreChecks` 断言连续低吞吐降档、连续高吞吐升档、省流上限、冷却 | 已通过 |
| 自适应开关 | `LumaCoreChecks` 断言未注入时默认关闭、注入开启后按网络降档 | 已通过 |
| 档位日志 | 诊断日志出现「网络自适应：流畅 → 均衡 … 吞吐 / 目标 / 领先」 | 已具备 |
| 弱网 | 用 Network Link Conditioner 限速，观察是否降档与恢复升档 | 待实测 |
| 本地 / SMB | 播放本地视频不应出现自适应日志 | 待实测 |
| 计费网络 | 热点场景下默认暂停后台生成 | 未开始 |
| 卡顿恢复 | 断网 10s 再恢复，播放能继续，不整片重转 | 待实测 |

---

## 7. 字幕偏好

> 状态：已落地（默认中文偏好：简体 > 繁体 > 中文 > 英语 > 其他；无设置项。覆盖内嵌自动挂载、字幕菜单排序、外挂候选与在线搜索；forced 轨不优先，手动选择按影片记忆）。

### 7.1 现状

| 行为 | 代码事实 |
| --- | --- |
| 内嵌自动挂载 | 仅本地 / SMB（`sourceURL.isFileURL`），云端不自动 |
| 选轨规则 | 语言前缀 `zh / chi / zho / chs / cht / cn`，否则第一条文本轨 |
| 外挂发现 | 同名 4 次 stat，再按文件名长度取最短 |
| 在线搜索 | `languages=zh-cn,zh-tw` 写死 |
| forced / default | ffprobe 已输出 `disposition`，但项目没有读取 |
| 图形字幕 | 只显示烧录入口，不进文本轨菜单 |

### 7.2 设计

**（1）`SubtitlePreference`**

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `languages: [String]` | `["zh-Hans", "zh-Hant", "en"]` | 优先级从高到低 |
| `mode` | `.auto` | `auto / preferredOnly / off` |
| `includeForced` | `false` | 是否优先 forced（仅对白以外的说明 / 歌曲） |
| `preferExternalOverEmbedded` | `true` | 外挂与内嵌同时存在时的优先级 |
| `autoLoadOnCloud` | `false` | 云端是否自动提取（避免和起流抢带宽） |
| `rememberManualChoice` | `true` | 按剧集 / 影片记住手动选择 |

**（2）语言归一化**

新建纯函数 `SubtitleLanguage`（建议放 `LumaCore` 以便测试）：

| 输入 | 归一化 |
| --- | --- |
| `zh`, `chi`, `zho`, `chs`, `cn`, `zh-cn`, `zh-hans`, `简体`, `简中` | `zh-Hans` |
| `cht`, `zh-tw`, `zh-hk`, `zh-hant`, `繁體`, `繁中` | `zh-Hant` |
| `eng`, `en`, `english`, `英文` | `en` |
| `jpn`, `ja`, `日文` | `ja` |
| `und`, `unknown`, 空 | `und` |

来源优先级：`tags.language` > `tags.title` 关键词 > 文件名后缀（`movie.zh-Hans.srt`）。

**（3）候选打分**

每条候选（内嵌轨 / 外挂文件 / 在线结果）计算：

```
score = 语言排名权重 + 来源权重 + forced 权重 + default 权重
```

| 项 | 规则 |
| --- | --- |
| 语言排名 | 第 1 优先 +100，第 2 +90，以此类推；不在列表 -1 |
| 来源 | 外挂 / 内嵌按 `preferExternalOverEmbedded` 决定 +10 / 0 |
| forced | `includeForced` 且轨为 forced +20 |
| default | 容器 default 轨 +5 |
| 图形字幕 | 文本轨 +15，图形轨仅作为烧录候选 |

`preferredOnly` 模式下，没有命中语言就不加载；`auto` 模式下允许回退到第一条文本轨，并记录诊断。

**（4）外挂发现改为候选列表**

`SubtitleLoader.discoverSibling` 从「返回一个 URL」改为「返回 `[URL]`」，由偏好引擎选择。这样 `movie.zh-Hans.srt` 与 `movie.eng.srt` 同时存在时不会因为文件名更短而选错。

**（5）在线字幕**

`OpenSubtitlesClient.search` 的 `languages` 改为偏好列表拼接（如 `zh-cn,zh-tw,en`），结果按同一套打分排序，不再只显示「没有找到中文字幕」。

**（6）记忆**

按「影片 / 剧集 + 季」记录用户最后一次手动选择（`subtitleTrackID` 或语言），下次打开优先恢复。只记录显示偏好，不写入源文件。

### 7.3 改动点

| 文件 | 改动 |
| --- | --- |
| `Sources/LumaCore/SubtitleLanguage.swift`（新增） | 语言归一化与打分，纯函数 |
| `Sources/PlaybackCore/SubtitlePreference.swift`（新增） | 偏好模型与默认值 |
| `Sources/PhotosClone/Services/Video/SubtitleLoader.swift` | 返回候选列表 |
| `Sources/PhotosClone/Features/Viewer/VideoPlaybackUI.swift` | 候选选择、手动记忆 |
| `Sources/PhotosClone/Features/Viewer/VideoPlayback.swift` | 自动挂载改为偏好引擎 |
| `Sources/PhotosClone/Services/Cinema/OpenSubtitlesClient.swift` | 语言参数从偏好读取 |
| `Sources/PhotosClone/Features/Settings/*` | 语言优先级列表编辑（拖拽排序） |

### 7.4 验收口径

| 项 | 方法 |
| --- | --- |
| 归一化 | `LumaCoreChecks` 覆盖 `chi/zh-Hant/cht/简体/english` 等样本 |
| 选轨 | 同一视频含 `zh-Hans / zh-Hant / en / forced` 四条轨，按偏好顺序切换设置，选中结果符合预期 |
| 外挂 | 目录同时有 `movie.zh-Hans.srt` 与 `movie.en.srt`，优先中文 |
| 在线 | 搜索结果按偏好排序，不只返回中文 |
| 记忆 | 手动选英文字幕后重开同一集，仍为英文 |

---

## 8. 落地顺序与依赖

| 阶段 | 内容 | 前置依赖 | 结果 | 状态 |
| --- | --- | --- | --- | --- |
| P0 | 视频运行时内置 ffmpeg-full + libplacebo + MoltenVK | 无 | DV P5 有正确映射路径 | 已完成 |
| P0 | 转码像素率降档 + 码率表 + 测试 | 无 | 4K60 → 1440p，边播边转留出余量 | 已完成 |
| P0 | 离线转码切 VideoToolbox | 无 | 4K 兼容转码等待时间下降 | 已完成 |
| P0 | DV P5 在 HDR 屏保留 remux（T8） | 无 | HDR 屏不再无条件映射 | 已完成 |
| P0 | zscale 前置 `setparams` 修复 | 无 | 回退路径不再报 `no path between colorspaces` | 已完成 |
| P0 | ffmpeg 直跑基线（4K60 / HDR10 / 1080i / 音频样片） | 无 | 降档阈值与滤镜链选择有实测依据 | 已完成 |
| P0 | 计划层骨架 + 缓存键签名 | 无 | 后续所有能力不会再互相污染缓存 | 已完成（cacheKeyVersion + 清单 HDR 标记） |
| P0 | 探测补字段：`field_order`、字幕 `disposition/forced`、`max_cll` | 无 | 后续功能的输入事实 | 部分（`field_order` 已落地） |
| P1 | 音频直通验证 + 降混 + 直通回退 | P0 缓存键 | AC-3 / E-AC-3 可用，其他编码可降混 | 部分（直通验证与回退已落地，降混未做） |
| P1 | 网络缓冲三档 + 远端自适应（默认流畅） | 无 | 前向缓冲 / readrate / 预取可配，弱网自动降档 | 已完成 |
| P1 | 去隔行 | P0 探测字段 | 1080i 正常 | 已完成（探测 + bwdif + 跳过原生直读） |
| P1 | 字幕偏好 | 无 | 自动选轨可解释、可配置 | 已完成（默认中文，无设置项；forced 识别 + 选择记忆） |
| P2 | HEVC / 低功耗档 + 硬件解码 | 转码档位 | 4K 发热与等待继续下降 | 部分（HEVC / 低功耗已落地，硬解未做） |
| P2 | 画面比例预设 | 无 | 显示层裁剪与拉伸 | 已完成（适应 / 填充 / 拉伸 / 原始像素 + 比例预设 + 平移） |
| P2 | 多码率 ABR | 吞吐自适应实测 | 弱网自动降清晰度 | 未开始 |

依赖关系是单向的：P0 的计划层与缓存键必须先做，否则 P1/P2 每加一个策略都会产生新的缓存歧义。缓存签名与清单已落地；后续切换音频 / 去隔行 / HDR 策略时，记得把策略变化带进签名或 +1 `cacheKeyVersion`。

---

## 9. 待实测清单（不得凭推测写入实现）

| 编号 | 待验证项 | 方法 | 影响 | 状态 |
| --- | --- | --- | --- | --- |
| T1 | AVPlayer 对 fMP4 HLS 中 AC-3 / E-AC-3 的支持 | 生成 10s 片段，`AVPlayerItem` 检查 `audioOptions` 与实际出声 | 决定 AC-3 直通默认开关 | 已通过（轨道层面）：`itemTracks` 显示 `soun:ac-3` / `soun:ec-3` 且起播；见 [组合实测](file:///Users/lijialong/Documents/gitlab/photos/docs/video-media-matrix-2026-11.md) |
| T2 | E-AC-3 JOC（Atmos）元数据是否在 fMP4 中保留 | `ffprobe` 看 `profile` / side data；AVPlayer 实际输出 | 决定 Atmos 是否宣传为支持 | 待实测 |
| T3 | `hevc_videotoolbox main10` 在目标 Mac 上的编码速度 | 4K HDR 样片 `-benchmark` | 决定性能 / 低功耗档默认编码器 | 待实测 |
| T4 | `-hwaccel videotoolbox` + `hwdownload` 的净收益 | 同一 4K 样片对比软解 | 决定是否默认开启硬解 | 待实测 |
| T5 | zscale tone map 在 4K 上的实时倍率 | 记录 `fps` 与生成领先 | 回退路径是否也要强制降档 | 已实测：4K 1.55× / 1440p 2.53×；必须带 `setparams` |
| T6 | libplacebo 滤镜选项与版本行为 | `ffmpeg -h filter=libplacebo` | 决定增强参数 | 已确认：9.0.2 支持 `w/h/format/colorspace/color_primaries/color_trc/apply_dolbyvision/tonemapping` |
| T7 | 运行时增强包下载与校验 | 实际下载 / 校验 | 决定是否提供应用内安装 | 已取消：改为构建期内置 |
| T8 | 目标显示器 EDR 余量与 DV 播放表现 | 实机 `NSScreen` 读数 + AVPlayer 解码帧附件 | 决定 `automatic` 阈值 | 已通过（管线）：`maxPotentialEDR=16`、`dvh1`、`DolbyVisionRPUData`、PQ；颜色目视待补 |
| T9 | 多 variant HLS 的切换行为与开销 | 双 variant 本地服务 + 限速 | 决定 ABR 是否值得做 | 待实测 |
| T10 | 断网 / 计费网络下 `NWPathMonitor` 的回调时序 | 热点 + 飞行模式 | 决定暂停生成策略 | 待实测 |
| T11 | HDR10+ 动态元数据是否被 libplacebo 链利用 | HDR10+ 样片对比 `tonemapping` 开关前后的高光 | 决定是否要显式传 ST 2094-40 参数 | 待实测 |
| T12 | 离线转码 `frameRate: 0` 的降档缺口 | 4K60 源走「转换为兼容格式」，看输出分辨率 | 4K60 离线转码仍会按 4K 处理 | 已修复：传入真实帧率 |
| T13 | `yadif_videotoolbox` 与 `bwdif` 的画质 / 性能差异 | 1080i 样片两条滤镜链对比 | 决定去隔行默认实现 | 待实测 |
| T14 | App 层首段 / 卡顿 / 生成领先 | 在 `Luma.app` 中播放样片，读诊断日志 | 验收线需要真实端到端数据 | 进行中：已有 11-22 日志基线（首段 p50 889ms、拖拽 p50 3.0s、2 次 49s 卡死）与请求级诊断；待真实网盘复现定案 |

---

## 10. 版本记录

| 日期 | 变更 |
| --- | --- |
| 2026-11-22 | 初稿：六项能力的现状、计划层设计、参数表、改动点、验收口径与待实测清单 |
| 2026-11-22 | 同步已落地状态：ffmpeg-full 9.0.2 + libplacebo + MoltenVK 随包内置；`TranscodeProfile` 像素率降档；离线转码切 VideoToolbox；测试断言；更新事实基线、状态列与待实测清单 |
| 2026-11-22 | T8 实测：AVPlayer 保留 DV RPU；DV P5 在 HDR 屏改为保留 remux；zscale 前置 `setparams` 修复；补 4K60 / HDR10 / 1080i / 音频样片基线；AC-3 / E-AC-3 直通白名单同步 |
| 2026-11-22 | 网络缓冲三档落地：省流 / 均衡 / 流畅，默认流畅；前向缓冲、readrate、提前量、Range 预取全部由档位驱动，设置页可切换 |
| 2026-11-22 | 远端缓冲自适应：按 Range 实测吞吐 + 生成领先量降档，恢复后升回设置档位；带冷却与滞回，本地盘 / SMB 不参与 |
| 2026-11-22 | 组合实测后的修复：hev1 原生直读判定；多音轨 `LANGUAGE`；离线转码真实帧率；单音轨直通无音轨回退；`HTTPByteRange` 后缀 / HEAD；SDR 屏拒绝 HDR 缓存；播放中缓存不被容量清理删除；详见 [组合实测](file:///Users/lijialong/Documents/gitlab/photos/docs/video-media-matrix-2026-11.md) |
| 2026-11-22 | 边界复核修复：上游 206 缺 `Content-Range` 不再把分片长度当总长；ffmpeg 非零退出不再被误判为源失败（保留 remux→transcode 降级）；缓存 SDR 判定改用播放器内生效的 HDR 策略；ffmpeg stderr 落盘失败改为 `nullDevice`；`stop()` 改用 `wasServingCache`；§4 音频状态与实测对齐（AC-3 / E-AC-3 / ALAC 直通、DTS/TrueHD→AC-3） |
| 2026-11-22 | 音频逐轨策略 + 降混：`AudioPlaybackPlan` 逐条决定 copy / AC-3 / AAC，混合编码同会话（实测 master CODECS 为 `ac-3,mp4a.40.2`）；新增「自动 / 立体声」降混开关。转码编码可选 H.264 / HEVC / 低功耗 HEVC（实测 1080p60 4s 素材：H.264 1.92s、HEVC 3.49s、HEVC 低功耗 1.79s；HEVC fMP4 HLS 输出 `hvc1` / Main10 / `yuv420p10le`）。字幕偏好收尾：外挂候选按语言排序、在线搜索语言参数、forced / default 识别、按影片记忆手动选择；缓存键升至 v5 |
| 2026-11-22 | 画面比例与显示方式：`VideoFramingGeometry` 纯几何布局；适应 / 填充 / 拉伸 / 原始像素 1:1；比例预设 16:9 / 4:3 / 2.35:1 / 1:1 + 上下左右平移与居中；控制条与顶栏共用画面菜单，A 键仍切适应 / 填充；布局断言全部通过 |
| 2026-11-22 | 真实来源联调落地：群晖 SMB 5 个真实片源复核；seek 起流去掉 `-copyts -start_at_zero`（首片 850→317ms，长片段末端音画差 <40ms）；音频兜底检测窗口 400ms→2s 且连续 4 次确认；卡死重建阈值 40s→10s；HLS 请求级诊断 + 快照 `seekable/av/local/base`；真实 MKV+AAC 直通复核推翻丢轨假设 |
| 2026-11-22 | 音质优先：默认 `AudioDownmixMode.source` 不降混；DTS / TrueHD 重编码目标 AC-3 640k → E-AC-3 1536k（真实 DTS-HD 片源实测可播）；多声道 AAC 384k→512k、离线转码 160k→512k；设置项改为「音质与声道 / 保持原样（默认）· 立体声（手动）」 |
| 2026-11-23 | 真实 WebDAV 服务复核（自签名证书、断连重连）通过；`RemoteRangeSource` 8MB 分块 + 6 路预取单独压测完成 |
