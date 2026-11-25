# 视频音画不同步：现状诊断、实测与修复方案

- 日期：2026-11-22
- 范围：影院 / 视频查看器的「跳片头、续播、远距离拖进度」场景
- 测试环境：macOS，项目内置 `Vendor/ffmpeg/ffmpeg`（ffmpeg 8.0.git）、`Vendor/ffmpeg/ffprobe`（ffprobe 4.4.1）
- 结论级别：已复现、已定位、已修复（P0 / P1 / P2）并通过实测验证

---

## 1. 结论

**这不是 AVPlayer 的锅，也不是网络慢。是我们自己用 ffmpeg 重启 HLS 会话时，把视频和音频切在了两个不同的源时间点上。**

只要发生「带偏移量重新起流」——跳过片头、续播、拖到未生成区间重建流——`-c:v copy` 会把视频退回到请求时间点之前的关键帧，而 `-c:a aac` 重编码的音频会被精确裁到请求时间点。两条流从第一帧起就相差最多一个 GOP。`-copyts -start_at_zero` 只重写时间戳，不会把已经裁掉的内容补回来。

实测（同一份合成片源、同一条命令）：

| 场景 | 当前实现 | 加入 `-noaccurate_seek` |
| --- | --- | --- |
| 2 秒 GOP，跳转到 6.0s（关键帧） | 音画相差 **2.06 s** | **0.000 s** |
| 10 秒 GOP，跳转到 10.0s（关键帧） | 音画相差 **5.2 s** | **0.000 s** |
| 10 秒 GOP，跳转到 20.0s（关键帧） | 音画相差 **9.9 s** | **0.000 s** |

也就是说：GOP 越长，错得越离谱；而我们的代码**永远把起流位置对齐到关键帧**，所以影院里的 MKV 几乎必然中招。SMB、本地、网盘全部一样，因为它们最终都走同一条 ffmpeg 转封装链路。原生 MP4（AVPlayer 直连）不受影响。

一句话修复（已落地）：**转封装模式下，在 `-ss` 前加 `-noaccurate_seek`，并用一次单帧探测把真实起流时间回填给 `playbackStartOffset`。**

---

## 2. 触发条件与影响面

| 入口 | 是否走 ffmpeg 转封装 | 是否中招 |
| --- | --- | --- |
| 影院「跳过片头」（`introSeconds > 0`） | MKV 是；MP4 否 | **是** |
| 影院「继续播放」（`cinemaResumeOffset`） | MKV 是 | **是** |
| 进度条拖到未生成区间（`restartStreaming`） | MKV 是 | **是** |
| 切换音轨（重建流） | 是 | **是** |
| 快进/快退到已生成区间内（`model.seek`） | 否，AVPlayer 内部 seek | 否 |
| 从 0 秒正常开播 | 是，但 `-ss` 不生效 | 否 |
| 原生 MP4 / MOV（SMB 挂载也一样） | 否 | 否 |

关键点：

- 「SMB 也一样」符合预期——SMB 只是文件来源，播放仍由 ffmpeg 处理，裁剪逻辑完全相同。
- 「不是一个视频这样，是全部对不上」也符合预期——片头时长不同没关系，起流位置只要落在关键帧上，就会稳定错一个 GOP。
- 冷启动第一遍可能感觉正常，一旦跳片头/续播就歪，因为只有带 `-ss` 的会话才有这个问题。

---

## 3. 现状：三条播放链路

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 330" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif">
  <defs>
    <marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto">
      <path d="M0,0 L10,5 L0,10 z" fill="#7a8494"/>
    </marker>
  </defs>
  <rect width="900" height="330" fill="#fbfbfd"/>
  <text x="24" y="32" font-size="14" font-weight="600" fill="#1d1d1f">Luma 当前视频播放链路</text>

  <rect x="24" y="56" width="200" height="64" rx="10" fill="#eef3ff" stroke="#b9ccf5"/>
  <text x="40" y="82" font-size="12.5" font-weight="600" fill="#2b4a8b">原生 AVPlayer</text>
  <text x="40" y="102" font-size="11" fill="#5a6b8c">MP4 / MOV · 无 ffmpeg</text>

  <rect x="24" y="140" width="200" height="64" rx="10" fill="#fff2ec" stroke="#f3c3ab"/>
  <text x="40" y="166" font-size="12.5" font-weight="600" fill="#9b4420">ffmpeg 转封装（remux）</text>
  <text x="40" y="186" font-size="11" fill="#9b6b52">-c:v copy + AAC 重编码</text>

  <rect x="24" y="224" width="200" height="64" rx="10" fill="#f3f0ff" stroke="#cec2f5"/>
  <text x="40" y="250" font-size="12.5" font-weight="600" fill="#5a3fa8">ffmpeg 重编码（transcode）</text>
  <text x="40" y="270" font-size="11" fill="#71618f">libx264 / 烧录字幕兜底</text>

  <line x1="224" y1="88" x2="320" y2="88" stroke="#7a8494" stroke-width="1.2" marker-end="url(#a)"/>
  <line x1="224" y1="172" x2="320" y2="172" stroke="#7a8494" stroke-width="1.2" marker-end="url(#a)"/>
  <line x1="224" y1="256" x2="320" y2="256" stroke="#7a8494" stroke-width="1.2" marker-end="url(#a)"/>

  <rect x="320" y="56" width="250" height="64" rx="10" fill="#f6f7f9" stroke="#d9dde4"/>
  <text x="336" y="82" font-size="12" fill="#333">直接读文件 URL</text>
  <text x="336" y="102" font-size="11" fill="#6b7280">seek 由 AVPlayer 处理</text>

  <rect x="320" y="140" width="250" height="64" rx="10" fill="#fff7f3" stroke="#f3c3ab"/>
  <text x="336" y="166" font-size="12" fill="#333">-ss 重启 … → fMP4 HLS</text>
  <text x="336" y="186" font-size="11" fill="#9b4420">本地 127.0.0.1 静态服务</text>

  <rect x="320" y="224" width="250" height="64" rx="10" fill="#faf8ff" stroke="#cec2f5"/>
  <text x="336" y="250" font-size="12" fill="#333">-ss 重启 … → fMP4 HLS</text>
  <text x="336" y="270" font-size="11" fill="#71618f">先转关键帧再编码</text>

  <line x1="570" y1="88" x2="660" y2="88" stroke="#7a8494" stroke-width="1.2" marker-end="url(#a)"/>
  <line x1="570" y1="172" x2="660" y2="172" stroke="#7a8494" stroke-width="1.2" marker-end="url(#a)"/>
  <line x1="570" y1="256" x2="660" y2="256" stroke="#7a8494" stroke-width="1.2" marker-end="url(#a)"/>

  <rect x="660" y="56" width="216" height="64" rx="10" fill="#eefaf1" stroke="#bfe5cb"/>
  <text x="676" y="82" font-size="12" font-weight="600" fill="#1f6b3a">AVPlayer 正常</text>
  <text x="676" y="102" font-size="11" fill="#4f7a60">音画由系统时钟保证</text>

  <rect x="660" y="140" width="216" height="64" rx="10" fill="#fdeeee" stroke="#efb9b9"/>
  <text x="676" y="166" font-size="12" font-weight="600" fill="#a12b2b">音画不同步</text>
  <text x="676" y="186" font-size="11" fill="#a45a5a">两轨内容起点不一致</text>

  <rect x="660" y="224" width="216" height="64" rx="10" fill="#eefaf1" stroke="#bfe5cb"/>
  <text x="676" y="250" font-size="12" font-weight="600" fill="#1f6b3a">通常正常</text>
  <text x="676" y="270" font-size="11" fill="#4f7a60">两轨都被精确裁剪</text>
</svg>

代码落点：

- 起流参数：[VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Video/VideoStreamSession.swift#L350-L419)
- 关键帧对齐：[VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Video/VideoStreamSession.swift#L452-L492)
- 起流调用与 `timelineOffset`：[VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L1582-L1651)
- 拖动/远跳重建流：[VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L1524-L1558)
- 片头/续播位置来源：[LibraryStore+Cinema.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Cinema.swift#L1830-L1886)
- 装片后 seek：[VideoPlayerModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Video/VideoPlayerModel.swift#L252-L345)

---

## 4. 现状代码到底做了什么

> 本节记录的是**修复前**的问题现场，用于解释失步成因；修复后的实现见第 8 节。

`VideoStreamSession.launch()` 的核心参数（修复前）：

```swift
let alignedStart = startOffset > 0.5
    ? Self.alignedKeyframe(before: startOffset, input: inputTarget)
    : 0
playbackStartOffset = alignedStart

var arguments = ["-y", "-v", "error", "-probesize", "2M", "-analyzeduration", "2M"]
arguments += ["-readrate", isRemote ? "6" : "12"]
if alignedStart > 0 {
    arguments += ["-ss", String(format: "%.3f", alignedStart)]   // 输入侧 seek
}
arguments += ["-i", inputTarget]
if alignedStart > 0 {
    arguments += ["-copyts", "-start_at_zero", "-avoid_negative_ts", "make_zero"]
}
arguments += ["-map", "0:v:0"]
// remux 分支
arguments += ["-c:v", "copy"]
arguments += ["-async", "1", "-c:a", "aac", ...]
```

这条命令里有两处互相冲突的诉求：

1. `-ss`（输入侧）+ `-c:v copy`：视频只能从**关键帧**开始，ffmpeg 实际会退回到请求点之前的关键帧。
2. `-ss`（输入侧）+ `-c:a aac`：音频是**解码后重编码**，`accurate_seek`（默认开启）会把它精确裁到请求时间点。

于是视频内容起点 = 关键帧，音频内容起点 = 请求时间点。代码注释里已经预判了这个问题：

> 「否则音频被精确裁到目标点、视频还在关键帧，嘴型必然对不上。」

但 `-copyts -start_at_zero` 解决不了它——这两个参数只平移时间戳，不会改变「两轨装的是不同时间段的样本」这个事实。

### 时间轴示意

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 300" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif">
  <rect width="900" height="300" fill="#fbfbfd"/>
  <text x="24" y="28" font-size="14" font-weight="600" fill="#1d1d1f">请求跳到 6.0s：accurate_seek 把两轨切在了不同位置</text>

  <!-- timeline -->
  <line x1="70" y1="60" x2="860" y2="60" stroke="#cfd4dc"/>
  <g font-size="10" fill="#8a919e">
    <text x="66" y="46">0</text><text x="226" y="46">2</text><text x="386" y="46">4</text>
    <text x="546" y="46">6</text><text x="706" y="46">8</text><text x="846" y="46">10s</text>
  </g>
  <g stroke="#e3e6eb">
    <line x1="80" y1="54" x2="80" y2="66"/><line x1="240" y1="54" x2="240" y2="66"/>
    <line x1="400" y1="54" x2="400" y2="66"/><line x1="560" y1="54" x2="560" y2="66"/>
    <line x1="720" y1="54" x2="720" y2="66"/><line x1="856" y1="54" x2="856" y2="66"/>
  </g>

  <!-- video row -->
  <text x="24" y="102" font-size="11.5" font-weight="600" fill="#9b4420">视频 copy</text>
  <rect x="240" y="84" width="480" height="30" rx="6" fill="#ffe9de" stroke="#f3c3ab"/>
  <text x="252" y="103" font-size="11" fill="#9b4420">从关键帧 4.0s 开始（无法裁到 6.0s）</text>
  <rect x="400" y="84" width="8" height="30" fill="#e8875d"/>
  <text x="414" y="103" font-size="10" fill="#b56a4a">关键帧 4.0</text>

  <!-- audio row -->
  <text x="24" y="164" font-size="11.5" font-weight="600" fill="#2b4a8b">音频 aac</text>
  <rect x="560" y="146" width="160" height="30" rx="6" fill="#eef3ff" stroke="#b9ccf5"/>
  <text x="572" y="165" font-size="11" fill="#2b4a8b">从 5.98s 开始（精确裁剪）</text>
  <rect x="560" y="146" width="8" height="30" fill="#5b7fd6"/>
  <text x="574" y="192" font-size="10" fill="#4a6bb8">音频内容起点 5.98</text>

  <!-- offset bracket -->
  <line x1="400" y1="226" x2="560" y2="226" stroke="#a12b2b" stroke-width="1.4"/>
  <line x1="400" y1="219" x2="400" y2="233" stroke="#a12b2b"/>
  <line x1="560" y1="219" x2="560" y2="233" stroke="#a12b2b"/>
  <text x="404" y="248" font-size="11.5" font-weight="600" fill="#a12b2b">2.0s 的内容缺口 = 一个 GOP</text>
  <text x="404" y="268" font-size="10.5" fill="#9b6b6b">fMP4 的第一个分片里只有视频包，音频被放到了后面的分片</text>
</svg>

---

## 5. 复现与实测

### 5.1 测试素材

用 ffmpeg 合成带唯一音画地标的片源：视频在 `t=15s` 闪一帧白，音频在 `t=15s` 响一声 1 kHz（2 秒 GOP；另有 10 秒 GOP 版本，地标在 25s）。

```bash
FF=./Vendor/ffmpeg/ffmpeg

# 2 秒 GOP 片源
$FF -y -v error \
  -f lavfi -i "color=c=black:s=320x180:r=25:d=40,\
drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='between(t\,15\,15.03)'" \
  -f lavfi -i "aevalsrc='0.8*sin(2*PI*1000*t)*between(t\,15\,15.1)':s=48000:d=40" \
  -c:v libx264 -preset veryfast -g 50 -keyint_min 50 -sc_threshold 0 \
  -pix_fmt yuv420p -c:a aac -b:a 128k -shortest src_2s.mkv

# 10 秒 GOP 片源（把 d=60、地标 25、-g 250 同理替换）
```

> 选唯一地标而不是「每秒一闪」，是为了避免「第 1 秒的声对第 2 秒的画」这种配对歧义。

### 5.2 当前命令的实测结果

对同一片源执行与 App 完全一致的转封装参数，然后分别解码视频帧亮度（找白闪）和音频静音段（找 beep 起点）：

| 请求位置 | 视频白闪出现时间 | 音频 beep 出现时间 | 差值 | 结论 |
| --- | --- | --- | --- | --- |
| 4.0s（关键帧） | 13.080s | 11.021s | **音频早 2.06s** | 失步 |
| 6.0s（关键帧） | 11.080s | 9.021s | **音频早 2.06s** | 失步 |
| 8.0s（关键帧） | 9.080s | 7.022s | **音频早 2.06s** | 失步 |
| 10.0s（关键帧） | 7.080s | 5.021s | **音频早 2.06s** | 失步 |
| 12.0s（关键帧） | 5.080s | 3.021s | **音频早 2.06s** | 失步 |
| 7.4s（非关键帧） | 9.000s | 9.000s | 0.000s | 偶然正常 |
| 5.9s（非关键帧） | 11.000s | 11.000s | 0.000s | 偶然正常 |

**规律：只要请求点正好落在关键帧上，就稳定错一个 GOP。** 而 App 的 `alignedKeyframe(before:)` 正是把 `startOffset` 向下取到关键帧，所以线上必然命中。

10 秒 GOP 的片源更严重：

| 请求位置 | 视频白闪 | 音频 beep | 差值 |
| --- | --- | --- | --- |
| 10.0s（关键帧） | 25.0s | ≈19.78s | **音频早 5.2s** |
| 20.0s（关键帧） | 15.0s | ≈24.9s | **音频晚 9.9s** |

差值的方向和大小都会随 GOP / 容器索引变化，用户的感受就是「哪个都对不上、越看越乱」。

### 5.3 第一个分片里没有音频

直接拆开 `init.mp4 + seg00000.m4s` 检查包列表：

```
lm2（-ss 6.0，当前实现）
  video 首包 pts = 0.160    音频首包 pts = 2.0587（在 seg00001 里）
  seg00000：视频包 250 个，音频包 0 个
```

这正是「前两秒只有画面没有声音，然后声音从错的位置接上」的物证。

### 5.4 修复参数验证

同一素材，仅在 `-ss` 前加 `-noaccurate_seek`：

| 场景 | 视频白闪 | 音频 beep | 差值 |
| --- | --- | --- | --- |
| 2s GOP，`-ss 6.0` | 11.096s | 11.096s | **0.000s** |
| 2s GOP，`-ss 7.4` | 9.090s | 9.090s | **0.000s** |
| 10s GOP，`-ss 10.0` | 25.000s | 25.000s | **0.000s** |
| 10s GOP，`-ss 20.0` | 15.000s | 15.000s | **0.000s** |

额外验证：

- `-c:a copy`（源是 AAC）也能保持 0.000s，说明失步来自「重编码 + 精确裁剪」这一组合，不是 fMP4 封装本身。
- transcode 模式（视频也重编码）当前参数本来就是对齐的（0.000s），不要给它加 `-noaccurate_seek`。
- `-async 1` 对这个问题没有帮助（实测开不开都是 2.06s）；把它看作历史兼容参数，不要依赖它修同步。

---

## 6. 根因链

1. `cinemaResumeOffset` / `restartStreaming` 把「要跳到第几秒」交给 `startStreaming(offset:)`。
2. `VideoStreamSession` 用 ffprobe 把 offset 向下取到关键帧，得到 `alignedStart`（例如 6.0）。
3. ffmpeg 输入侧 `-ss 6.0`：MKV/MP4 的 demuxer 实际退回到更早的关键帧（例如 4.0），视频 copy 从 4.0 开始。
4. 音频走解码重编码，`accurate_seek`（默认）把它精确裁到 6.0（实测首包 5.9787）。
5. `-copyts -start_at_zero` 只做时间戳平移；两条流一开始就相差 2 秒的内容，平移后依然差 2 秒。
6. fMP4 分片按各自的轨道时间戳写入，于是第一个分片只有视频；AVPlayer 忠实地按 tfdt 播放这份「错位」的素材。

补充一个工程隐患：内置 `ffprobe` 是 4.4.1，而 `ffmpeg` 是 8.0.git。`alignedKeyframe` 用 4.4.1 的 `-read_intervals` 找关键帧，和 8.0 的实际 seek 行为可能不一致（实测：ffprobe 报 6.0，ffmpeg 落到 4.0）。版本对齐后能减少「对齐值 ≠ 实际起流值」的二次误差。

---

## 7. 对标：为什么优秀播放器没有这个问题

| 播放器 | 播放内核 | seek 的处理方式 | 音画同步机制 |
| --- | --- | --- | --- |
| mpv / IINA | 进程内 libavformat + libavcodec | demux seek 后解码并丢弃到目标帧，渲染由 PTS 驱动 | 音频主时钟（`--video-sync=audio`），视频丢帧/重复追时钟 |
| VLC | 自研 input/decoder/output 管线 | demux seek 后重建时钟 | 独立 input clock 仲裁，支持手动 desync |
| Infuse | 自研播放核心（闭源，不依赖 AVPlayer 播放转封装流） | 进程内 seek | 播放器内核统一同步 |
| Zidoo | 硬件解码 + 自研播放器 | 进程内 seek | 内核统一同步 |
| AVPlayer 原生 MP4 | AVPlayer | AVPlayer 内部 seek | 无问题 |
| **Luma（现状）** | AVPlayer 播放进程外转封装出的 fMP4 HLS | **每次远跳杀掉 ffmpeg、带 `-ss` 重启** | 两轨内容起点错位，AVPlayer 无从修正 |

差别不在「谁用了更强的同步算法」，而在**架构**：

- 成熟播放器把「seek」和「解码输出」放在同一个时间轴模型里，PTS 是唯一真理；跳到哪一帧、丢掉哪些包，都由播放内核统一决定。
- 我们是「外部 muxer 先切好文件，再交给 AVPlayer」。一旦切的时候两轨不一致，AVPlayer 只能照单全收。

所以这不是「我们做得差一点」，而是**这条链路本身缺少一层约束：切流必须按同一时间点切两轨**。补上这层约束，音画同步就能达到 AVPlayer 原生水平。

---

## 8. 修复方案与实施记录

实施状态（2026-11-22，已编译通过）：

| 编号 | 内容 | 状态 | 代码落点 |
| --- | --- | --- | --- |
| P0-1 | 转封装模式关闭 `accurate_seek` | 已实现 | [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Video/VideoStreamSession.swift#L386-L396) |
| P0-2 | 真实起流点回填 `playbackStartOffset` | 已实现 | [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Video/VideoStreamSession.swift#L483-L541) |
| P1-1 | AAC / ALAC 音轨直接拷贝 | 已实现 | [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Video/VideoStreamSession.swift#L404-L418) |
| P1-2 | 重编码模式强制 2 秒关键帧 | 已实现 | [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Video/VideoStreamSession.swift#L419-L421) |
| P2 | 重建流期间合并连续远跳 | 已实现 | [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L1539-L1596) |

### P0-1（已实现）：转封装模式关闭 accurate_seek

`-noaccurate_seek` 是输入选项，必须放在 `-i` 之前。它的语义是「不要在解码后精确丢弃到目标时间」，因此音轨会和视频一样从 demuxer 落到的关键帧开始。

```swift
// VideoStreamSession.launch()
let effectiveMode: Mode = burnSubtitle == nil ? mode : .transcode
let copiesVideo = effectiveMode == .remux
let seeking = startOffset > 0.5

if seeking {
    if copiesVideo {
        arguments += ["-noaccurate_seek"]   // 必须在 -i 之前
    }
    let seekValue = copiesVideo ? startOffset : playbackStartOffset
    arguments += ["-ss", String(format: "%.3f", seekValue)]
}
arguments += ["-i", inputTarget]
```

`-copyts -start_at_zero -avoid_negative_ts make_zero` 保留（已验证与 `-noaccurate_seek` 共存时对齐）。

### P0-2（已实现）：把 `playbackStartOffset` 改成「真实起流时间」

`-noaccurate_seek` 之后，实际起流点是 demuxer 落到的关键帧（可能比 ffprobe 报的 `alignedStart` 更早）。如果继续把 `playbackStartOffset` 设成请求值，音画是同步了，但「跳片头会停在片头前 2 秒」。

实现为 `VideoStreamSession.actualSeekStart(requested:input:)`：用与真正转封装完全相同的 seek 参数读一帧视频，解析 framecrc 的 PTS（含时间基换算）：

```bash
ffmpeg -v error -probesize 2M -analyzeduration 2M \
       -noaccurate_seek -ss 6.0 -i input.mkv \
       -copyts -map 0:v:0 -c copy -frames:v 1 -f framecrc -
# #tb 0: 1/1000
# 0, 3920, 4000, 40, 65, 0x...     ← pts=4000 → 4.0s
```

要点：

- 解析 `#tb 0:` 声明的时间基，兼容 MKV（1/1000）与 MP4（1/16000）。
- 探测失败 / 超时（4 秒）退回请求值：音画仍然同步，落点最多差一个 GOP。
- `retainedStartSeconds` / `trim()` 都基于 `playbackStartOffset`，会自动跟着正确。
- 探测与真实会话使用同一个 `startOffset`，保证 demuxer 落点一致。

### P1-1（已实现）：能拷音频就拷音频

`-c:a copy` 实测同样 0.000s，而且省掉一次 AAC 重编码。当前白名单只放开 **AAC / ALAC**：

```swift
private static let copyableAudioCodecs: Set<String> = ["aac", "alac"]
```

AC-3 / E-AC-3 虽然技术上可封装进 fMP4，但没有实机验证前仍走 AAC，避免出现「有画面没声音」；DTS / TrueHD 本来就必须重编码。命中白名单时不再输出 `-async`，直接 `-c:a copy`。

### P1-2（已实现）：纯重编码模式补关键帧约束

transcode 模式当前是对齐的，但 `-hls_time 2` 在长 GOP 源上切不出 2 秒分片（实测 10 秒 GOP 的首片就是 10 秒），首段等待会变长。已加入：

```bash
-c:v libx264 -preset veryfast -crf 20 -force_key_frames "expr:gte(t,n_forced*2)"
```

实测切片全部为 2.000s。

### P2（已实现）：减少重启次数

「向后保留 2 分钟 + 已生成区间内直接 `model.seek` + 拖动预览」在现状代码里已经成立，本次补的是**连续远跳的合并**：

- 重建流进行中，`seekRouter` 与 `restartStreaming` 不再用旧会话的时间轴去 seek，而是把目标写进 `pendingRestartTarget`。
- 当前会话就绪后只追最后一个目标（差值 ≤ 0.75s 视为已到位），不会排队拉起多个 ffmpeg。
- 换片 / 重新载入时清空 pending，避免把上一部片的跳转带到新片。

这样连续拖动进度条时，最多只会有「当前重建 + 一次追赶重建」，不再出现多个会话互相抢占。

### 不推荐的做法

| 做法 | 问题 |
| --- | --- |
| 只加 `-async 1` / `aresample=async=1` | 实测不解决，音频会「补齐」到错误起点 |
| 把 `-ss` 挪到 `-i` 之后 | 视频 copy 无法在 GOP 中间切开，会得到更奇怪的偏移 |
| 直接去掉 `-copyts` | 时间戳归一化，但两轨内容仍然错位，只是把问题藏起来 |
| 每次都全片重编码 | 能对齐，但 4K 长片 CPU / 等待成本不可接受 |

---

## 9. 验收标准与回归

### 9.1 验收（播放器侧）

- 唯一地标素材：`|beep - flash| ≤ 50ms`（当前修复实测 0ms）。
- 首片 `seg00000.m4s` 的音频包数 > 0。
- 片头跳过落点误差 ≤ 0.5s；续播落点误差 ≤ 1s。
- 2s / 10s GOP、HEVC、AC-3 / DTS 音轨各测一遍。
- 本地、SMB、网盘（Range 代理）三种源各测一遍。

### 9.2 本次实现后的实测（2026-11-22）

用与 App 完全一致的参数（含 `-readrate 12`、`-noaccurate_seek`、AAC 拷贝）：

| 用例 | 视频白闪 | 音频 beep | 差值 | 首片音频包 |
| --- | --- | --- | --- | --- |
| 2s GOP MKV，`-ss 6.0` | 11.075s | 11.0749s | 0.000s | 94 |
| 10s GOP MKV，`-ss 10.0` | 25.000s | 25.000s | 0.000s | 466 |
| MP4（2s GOP），`-ss 6.0` | 9.112s | 9.112s | 0.000s | — |
| transcode + 强制关键帧 | 切片全部 2.000s | 1.021s… | 0.000s | — |

对照：修复前同一 2s GOP 用例首片音频包为 **0**。

编译验证：`swift build -c debug --product PhotosClone` 通过（无新增错误）。

### 9.3 回归风险

| 风险 | 处理 |
| --- | --- |
| `-noaccurate_seek` 误加到 transcode 模式 | 用 `copiesVideo` 条件包住，只作用于 remux |
| 真实起流点探测在网盘上慢 | 与 ffprobe 同样 4s 超时，失败则退回请求值（音画仍同步，位置可能差一个 GOP） |
| fMP4 不支持某些音轨拷贝 | 拷贝前检查 codec 白名单，不支持就走 AAC |
| 旧 HLS 缓存是错位的 | 现状缓存只对 `startOffset < 0.5` 生效，不受影响；无需清缓存 |
| 4K 高码率 `-max_muxing_queue_size` 溢出 | 保持现有 2048 |
| MP4 源被误伤 | 实测修复前后都对齐（MP4 demuxer 本来就会落到请求关键帧） |
| framecrc 时间基解析错误放大时间轴 | 已修正 `#tb 0: 1/1000` 的分子分母；续播记录按片源时长校验，异常记录自动丢弃 |

### 9.3.1 续播显示「直接到结尾」（2026-11-22 修复）

**现象**：影院 / 目录续播一打开，进度条就在片尾，时间显示成几万小时。

**日志证据**：

```text
起流对齐 270s → 265933000s（真实落点）
```

`actualSeekStart` 用 `framecrc` 探测真实落点。ffmpeg 输出 `#tb 0: 1/1000`，
旧代码把时间基算成了 `denominator / numerator`（= 1000），而正确值是 `numerator / denominator`（= 0.001）。
帧 pts `265933` 被放大成 `265933000`，`PlaybackTimeline.sessionStart` 随之为 2.66 亿秒：

- `currentTime = local + sessionStart` → 显示几万小时、进度条 `min(1, …)` 直接到 100%；
- `duration` 也被 `timeline.absolute(local:)` 同步放大 → 比例失真；
- 落盘的影院进度 `position` / `duration` 一起被污染，下次续播仍落在片尾。

**修复**：

| 落点 | 改动 |
| --- | --- |
| [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoStreamSession.swift#L461-L481) | 时间基改为 `numerator / denominator`，并加 `denominator > 0` 防护 |
| [CinemaModels.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/CinemaModels.swift#L740-L752) | `CinemaProgressRecord.isTrustworthy(realDuration:)`：时长超过片源 1.5 倍（或 24h）即判为脏记录 |
| [LibraryStore+PlaybackHooks.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+PlaybackHooks.swift#L7-L52) | 续播前校验记录，脏记录不参与续播 |
| [LibraryStore+Cinema.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Cinema.swift#L174-L197) | 启动加载时清洗脏记录并回写，「继续观看」不再显示已看完 |

**验证**：同一 `framecrc` 命令实测 `#tb 0: 1/1000`、`pts 38000` → 修复后为 `38.0s`（关键帧），不再放大 1000 倍；`swift build -c debug --product PhotosClone` 通过。

### 9.3.2 拖到远端后被拉回片头、最终「无法连接服务器」（2026-11-22 修复）

**现象**：拖到后面再拖回来回不去；每次拖到远端，约 0.3 秒后又自动跳回片头；来回几次后播放器报「无法连接服务器」，画面黑屏。

**日志特征**（每次拖到远端后都紧跟一次片头起流）：

```text
起流对齐 1023s → ... 首段就绪 offset=1023
拖拽起流 → 1024s
起流对齐 144s  → ... 首段就绪 offset=144
拖拽起流 → 145s
```

**根因**：`PlaybackSession.handleTick` 的续播重试跑在 `current > 3` 判断之前。重建流时 `VideoPlayerModel.load` 会先 `resetForNewItem()` 把 `currentTime` 置 0，这个 0 采样带着首次续播点（片头 145s）进入重试分支：

1. `current(0) < pending(145) - 4` 成立 → `engine.requestSeek(to: 145)`；
2. `seekRouter` 判定 145 早于当前会话保留窗口 → `restartStreaming(at: 145)`；
3. 外层 `PlaybackSession.restart` 还没结束，于是把 145 记进 `pendingRestartTarget`，本轮结束后立刻再建一个 145 的流。

于是「拖到 1023 → 自动回 145」形成死循环。每次 stop 都会关闭旧的 `LocalHLSServer`，循环中 AVPlayer 仍指向已关闭的地址，最终报「无法连接服务器」。

**修复**：

| 落点 | 改动 |
| --- | --- |
| [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift#L190-L215) | 续播重试增加 `current > 3`，`load` 重置出的 0 采样不再参与判断 |
| [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift#L305-L325) | 重建流分支清空 `pendingResume` 与重试计数：重建目标只认调用方给的 `resumeAt` |

**回归要点**：拖到覆盖范围外只重建一次；重建完成后位置停在目标处，不再回片头；连续来回拖动不会堆积 ffmpeg。

### 9.3.3 拖动时错误卡片闪现、按钮停在暂停态（2026-11-22 修复）

时间轴修复后日志已正常（`起流对齐 1425s → 1424s`），但重建流期间仍有两个过渡态问题：

- `restart` 一开始就关闭旧会话的 `LocalHLSServer`，AVPlayer 对旧 item 报「无法连接服务器」，`activeFailure` 立刻拿来弹卡片，随后新流就绪卡片又消失——表现为「偶尔闪现」；
- 重建期间 `model.pause()` 后 `timeControlStatus` 的下一次回报才到，控制条还停在暂停图标，中央也不一定进入等待态——表现为「显示暂停按钮，而不是刷新」。

**修复**：

| 落点 | 改动 |
| --- | --- |
| [VideoPlayerModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoPlayerModel.swift#L24-L28) | 新增 `isReloading`：重建流期间 `isStalled` 直接为 true，统一显示转圈 |
| [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift#L386-L418) | `restart` 进入时 `setReloading(true)`，结束时复位；`stop()` 也复位 |
| [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L536-L541) | `activeFailure` 在 `isPreparing` / 重建期间忽略 `model.errorMessage`，瞬时断连不再弹卡片 |
| [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L403-L445) | `VideoControlButton` 支持 `busy`，重建 / 缓冲时播放按钮换成转圈 |

**回归要点**：来回拖动时只看到转圈；不再出现「无法连接服务器」卡片；真正的起流失败仍会显示错误卡片与「转换为兼容格式」。

### 9.4 快速自查（用户侧）

```bash
# App 诊断日志（起流耗时、对齐值、失败原因）
~/Library/Logs/Luma/diagnostics.log

# 正在生成的 HLS 工作目录（能看到 seg00000 是否缺音频）
<图库>/resources/transcodes/*.hls/live.m3u8
```

---

## 10. 附：复现脚本

```bash
#!/bin/sh
# 生成 2 秒 GOP 的唯一地标素材
FF=./Vendor/ffmpeg/ffmpeg
$FF -y -v error \
  -f lavfi -i "color=c=black:s=320x180:r=25:d=40,\
drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='between(t\,15\,15.03)'" \
  -f lavfi -i "aevalsrc='0.8*sin(2*PI*1000*t)*between(t\,15\,15.1)':s=48000:d=40" \
  -c:v libx264 -preset veryfast -g 50 -keyint_min 50 -sc_threshold 0 \
  -pix_fmt yuv420p -c:a aac -b:a 128k -shortest src.mkv

# 当前实现（失步）
$FF -y -v error -probesize 2M -analyzeduration 2M \
  -ss 6.000 -i src.mkv -copyts -start_at_zero -avoid_negative_ts make_zero \
  -map 0:v:0 -c:v copy -async 1 -c:a aac -b:a 192k -map 0:a:0 \
  -max_muxing_queue_size 2048 \
  -f hls -hls_time 2 -hls_init_time 0.5 -hls_list_size 0 -hls_playlist_type event \
  -hls_flags temp_file -hls_segment_type fmp4 \
  -hls_fmp4_init_filename init.mp4 \
  -hls_segment_filename bad/seg%05d.m4s bad/live.m3u8

# 修复后（同步）：AAC / ALAC 直接拷贝音轨
$FF -y -v error -probesize 2M -analyzeduration 2M \
  -noaccurate_seek -ss 6.000 -i src.mkv \
  -copyts -start_at_zero -avoid_negative_ts make_zero \
  -map 0:v:0 -c:v copy -c:a copy -map 0:a:0 \
  -max_muxing_queue_size 2048 \
  -f hls -hls_time 2 -hls_init_time 0.5 -hls_list_size 0 -hls_playlist_type event \
  -hls_flags temp_file -hls_segment_type fmp4 \
  -hls_fmp4_init_filename init.mp4 \
  -hls_segment_filename good/seg%05d.m4s good/live.m3u8

# 真实起流点（回填给 playbackStartOffset）
$FF -v error -probesize 2M -analyzeduration 2M \
  -noaccurate_seek -ss 6.000 -i src.mkv \
  -copyts -map 0:v:0 -c copy -frames:v 1 -f framecrc - \
  | grep -E "^#tb|^[0-9]"
# #tb 0: 1/1000
# 0, 3920, 4000, 40, 65, 0x...   → pts 4000 / 1000 = 4.0s

# 量测：视频白闪时刻 vs 音频 beep 起点
# 视频
$FF -v error -i good/live.m3u8 -an -vf "signalstats,metadata=print" -f null - 2>&1 \
  | grep -E "pts_time|YAVG" | head
# 音频
$FF -hide_banner -v info -i good/live.m3u8 -vn \
  -af silencedetect=noise=-25dB:d=0.05 -f null - 2>&1 \
  | grep -E "silence_(start|end)"
# 首片音频包数
cat good/init.mp4 good/seg00000.m4s > good/c0.mp4
./Vendor/ffmpeg/ffprobe -v error -select_streams a:0 \
  -show_entries packet=pts_time -of csv=p=0 good/c0.mp4 | wc -l
```

---

## 11. 一句话总结

我们没有「不会同步」的播放器，只有「切歪了再交给播放器」的转封装：**`-c:v copy` 退到关键帧、`-c:a aac` 精确裁剪，两轨从第一帧起就差一个 GOP**。加 `-noaccurate_seek` 并把真实起流点回填（P0），命中白名单时直接拷贝音轨（P1），再合并连续远跳（P2）——这三步已经落地并实测通过。再往上，减少「每次跳转重启 ffmpeg」才是和 mpv / VLC / Infuse 真正对齐的方向。

---

## 12. 播放能力补齐（2026-11-22）

这一轮把与主流播放器的六项差距一次补齐，全部落在 `PlaybackCore` 与播放页的既有分层里。

| 能力 | 实现要点 | 代码 |
| --- | --- | --- |
| 高倍速音频 | `AVPlayerItem.audioTimePitchAlgorithm = .spectral`，0.25×～4× 变速保持音调 | [VideoPlayerModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoPlayerModel.swift#L254-L256) |
| 音频延迟微调 | 内核 `PlaybackSession.audioDelay`，正值 `adelay`、负值 `atrim+asetpts`，音频自动改为 AAC；速度菜单内 ±0.1s / ±0.5s | [StreamPlanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/StreamPlanner.swift#L219-L227) |
| 音轨即时切换 | 多音轨 remux 输出 master playlist（`-var_stream_map` + `agroup`），切换只让 AVPlayer 换轨 | [StreamPlanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/StreamPlanner.swift#L92-L101) |
| 内嵌字幕 | ffprobe 解析字幕轨，ffmpeg 提取为 ASS 文本交给覆盖层；本地 / SMB 源自动挂载中文字幕 | [EmbeddedSubtitleLoader.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Video/EmbeddedSubtitleLoader.swift) |
| ASS / SSA 样式 | 解析样式表与 `\an` `\b` `\i` `\fs` `\c`，渲染颜色、字号倍率、粗斜体、描边与上/中/下位置 | [SubtitleCore.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/SubtitleCore.swift#L142-L231) |
| 系统媒体集成 | Now Playing 标题 / 时长 / 进度 / 封面 + 播放、暂停、切集、拖动命令 | [NowPlayingCenter.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Video/NowPlayingCenter.swift) |

### 12.1 音轨即时切换的边界

- 仅当 **remux + 无字幕烧录 + 音频编码可拷贝（AAC / ALAC）+ 音频延迟为 0** 时启用多音轨 master playlist；
- 其它情况仍走单音轨会话，切轨按原逻辑重建 ffmpeg；
- 多音轨会话不做长期缓存、不做滚动删片，避免各轨分片序号不一致。

### 12.2 已用真实 ffmpeg 验证的参数

```text
# 双音轨 master playlist
-map 0:v:0 -c:v copy -map 0:a:0 -map 0:a:1 -c:a copy \
-var_stream_map "v:0,agroup:aud a:0,agroup:aud,default:yes a:1,agroup:aud" \
-hls_segment_filename seg_%v_%05d.m4s -master_pl_name master.m3u8 live_%v.m3u8

# 音频延迟
-af "adelay=delays=500:all=1"                       # 音频延后 0.5s
-af "atrim=start=0.500,asetpts=PTS-STARTPTS"        # 音频提前 0.5s
```

两条命令都实测能正常生成 HLS；master 里输出两条 `EXT-X-MEDIA`，AVPlayer 可即时换轨。

### 12.3 编译

`swift build -c debug --product PhotosClone` 通过；`./build.sh` 全量 release 打包通过。

### 12.4 设置入口

**设置 → 影院 → 播放 → 播放增强**（新增 4 个开关，默认全部开启）：

| 开关 | 默认 | 作用 |
| --- | --- | --- |
| 高倍速保持音调 | 开 | 变速时用频谱算法保持音调；切换后对当前视频立即生效 |
| 音轨即时切换 | 开 | 多音轨装进同一会话，切轨不重启转码；关闭后改回重建流 |
| 自动挂载内嵌字幕 | 开 | 本地 / SMB 视频自动提取中文字幕轨；云端仍为手动选择 |
| 系统媒体集成 | 开 | 控制中心与媒体键控制当前视频；切换后立即生效 |

**播放期临时操作**（不进设置，避免每部片都要回去改）：

- 音频延迟：控制条「速度」菜单里的「音频延迟」子菜单，±0.1s / ±0.5s，范围 ±2s；调整后按当前位置重建一次流。
- 内嵌字幕：字幕菜单里的「内嵌 · …」，可随时切换或关闭。
- ASS / SSA 样式：自动生效；设置页的字幕颜色 / 字号只作为 SRT / VTT 的基准，ASS 自带样式优先。

## 13. 播放稳定性与起播反馈（2026-11-22）

### 13.1 SMB / 慢盘播放周期性卡顿

**现象**：本地 SMB 长片播一会儿卡一下，很有规律。

**根因**：播放中每 3 秒滚动删除旧分片，并在服务端动态改写 m3u8（前移 `MEDIA-SEQUENCE`、删条目）。AVPlayer 对 EVENT 列表的预期是「只追加」，播放列表被改写会让它重新对齐缓冲窗口；在 SMB / 慢盘上，这个重新对齐就表现为周期性卡顿。

**修复**：

| 落点 | 改动 |
| --- | --- |
| [LocalHLSServer.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/LocalHLSServer.swift#L126-L130) | 不再动态过滤播放列表，m3u8 只由 ffmpeg 追加 |
| [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoStreamSession.swift#L132-L139) | `trim` 只调整生成节奏，播放中不删分片；会话结束时整目录清理 |
| [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoStreamSession.swift#L164-L186) | 生成提前窗口 4 分钟→10 分钟、恢复线 90 秒→180 秒，减少 SIGSTOP / SIGCONT 频繁启停 |
| [VideoPlayerModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoPlayerModel.swift#L212-L215) | `preferredForwardBufferDuration` 3 秒→8 秒，吸收生成抖动 |

代价：播放期间临时分片不再滚动删除，长片会占用与片长等量的临时磁盘，停止播放即清理。

### 13.2 起播时中间缺少 loading

`VideoBufferingOverlay` 统一延迟 0.22 秒出现（避免短跳转闪白圈），起播阶段也走了这个防抖。现在起播 / 重建流阶段传 `immediate: true`，中央转圈立即出现；普通播放中的短暂抖动仍保留防抖。

### 13.3 如何定位残余卡顿

新增诊断日志：

```text
播放缓冲 <文件名> at <秒>
```

如果仍然出现卡顿，日志会给出位置与频率：周期性集中在某几个秒数通常是 SMB 读取抖动，零散出现则看同时间的 ffmpeg 输出。

## 14. 进度条缩略图预览（2026-11-22）

**现象**：拖到 HLS 还没生成的区间时，预览气泡里只有一个占位图标；同时顶栏播放舱的完整文件名 tooltip 会盖在气泡上。

**优化**：

| 问题 | 处理 |
| --- | --- |
| 未生成区间取不到帧 | HLS 会话取帧失败时，用 ffmpeg 从原始片源抽一帧（320 宽、8 秒超时、按采样段缓存） |
| 取帧失败时空黑框 | 不再画 176×99 的占位框，只显示一个时间胶囊，避免看起来像坏了 |
| 文件名 tooltip 覆盖预览 | 移除视频播放舱的 `help(显示完整文件名)`；标题本身已在舱内可见 |
| 可控 | 「设置 → 影院 → 播放 → 画面与控制 → 进度条悬停预览」可关闭，关闭后不取帧、不显示气泡 |

实现落点：

- [VideoScrubThumbnails.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoScrubThumbnails.swift)：源文件抽帧 + 回退 provider + 无帧时的紧凑时间胶囊
- [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift)：注册回退取帧、按设置开关预览
- [PhotoViewer.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/PhotoViewer.swift)：移除播放舱 tooltip

**说明**：源文件抽帧需要现场 seek 一次，SMB / 网盘上首帧可能慢 1～2 秒；同一采样段内来回滑动命中缓存，不会重复解码。

## 15. 进度条缓冲区间（2026-11-22）

**问题**：进度条只有「已播放」一段，看不出后面还有多少已经准备好。HLS 是边转边播，用 AVPlayer 自身的 `loadedTimeRanges` 画缓冲段只有几秒，看起来像永远没在缓冲。

**参考做法**：YouTube / Infuse / Plex 都画「已经能立即跳转」的区间，而不是播放器内部的小缓冲窗口：

| 元素 | 表现 |
| --- | --- |
| 底轨 | 深色细槽，表示整条片长 |
| 缓冲区间 | 更浅的一层实心段，从当前会话还能回退的起点画到已生成末尾 |
| 缓冲前沿 | 1.5pt 亮线 + 轻微柔光，标出「到这里都准备好了」 |
| 已播放段 | 渐变亮色，盖在缓冲段之上 |
| 完全缓冲 | 不再画前沿线，整条轨道都是浅色 |

**实现**：

- [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoStreamSession.swift)：`generatedEndSeconds` 读播放列表 `#EXTINF` 求和（多音轨读 `live_0.m3u8`），0.5 秒节流，避免进度条每帧解析 m3u8
- [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift)：时间轴每次刷新把「已生成末尾」与播放器缓冲取较大值同步给引擎；seek 决策也改用已生成末尾，保证「画到哪里就能跳到哪里」
- [VideoPlayerModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoPlayerModel.swift)：`generatedEndTime` / `bufferedEndTime`，换片时清零
- [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift)：`VideoScrubber` 新增 `bufferedStart`，画缓冲段与前沿亮线；画面控制条与窗口工具栏共用同一份数据

**行为变化**：拖到浅色区间内直接 seek，不再重建 ffmpeg；拖到浅色区间之后仍按原逻辑重新起流，缓冲段会从新的保留起点重新铺开。

## 16. 快进稳定性（2026-11-22）

**现象**：连续 / 长按快进时偶发退出、卡死或「无法连接服务器」。

**根因**（按影响从大到小）：

1. **高频重建流**：快进到未生成区间会 stop 旧 ffmpeg、起新会话。长按方向键时目标每 100ms 变一次，形成「拉起 → 立刻杀掉 → 再拉起」的抖动，4K 解码 / SMB 读取时最容易把会话拖进异常状态。
2. **监听 fd 跨线程关闭**：`LocalHLSServer` / `RemoteRangeSource` 的 `stop()` 直接在调用线程 `close(listenFD)`，而接收线程还阻塞在 `accept`。fd 号可能立刻被下一次重建的服务复用，旧线程会 accept 到别的 socket 上。
3. **stop 与起流交叉**：起流是后台任务，`stop()` 可能在 `server.start()` / `process.run()` 之间发生，导致 stop 之后又挂上一个没人负责的本地服务或 ffmpeg。
4. **非有限值**：拖动 / 快进的中间值一旦出现 NaN，会进入 `frame(width:)`、AVPlayer 时间轴与播放列表求和，轻则进度条卡住，重则 SwiftUI 布局死循环。

**处理**：

| 位置 | 改动 |
| --- | --- |
| [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift) | 重建前等待目标稳定（150ms 静默，最多 0.6s）；单次重建最多 12 轮；拒绝非有限目标 |
| [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoStreamSession.swift) | `stop()` 幂等；先终止 ffmpeg 再撤代理服务；起流每一步都检查 `stopping`，避免 stop 后重新挂上资源；m3u8 字节数未变时跳过解析 |
| [LocalHLSServer.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/LocalHLSServer.swift) | 监听 fd 只由接收线程关闭；`poll`（250ms 超时）代替阻塞 `accept`；`stop()` 只 `shutdown` 唤醒 |
| [RemoteRangeSource.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/RemoteRangeSource.swift) | 同上，避免快速重建时 fd 复用误 accept |
| [VideoPlayerModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoPlayerModel.swift) / [PlaybackTimeline.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackTimeline.swift) | `seek` / `scrub` / `requestSeek` / `seekStep` / `clamp` 全部拒绝 NaN 与无穷大 |

**打包注意**：不要用 `cp` 直接覆盖正在运行的 `Luma.app/Contents/MacOS/Luma`。运行中的进程映射着旧二进制，就地覆盖会触发 `SIGBUS` / `Code Signature Invalid`，表现就是「忽然崩溃」。现在改为先在临时目录组装并签名，再整包原子替换。

**验证**：长按 → 连续快进跨越多个未生成区间，只会在松手后重建一次流；浅色缓冲段之内则始终是会话内 seek。

## 17. 「有缓冲却卡住 / 播一会儿就暂停」整体排查（2026-11-22）

结合诊断日志（`~/Library/Logs/Luma/diagnostics.log`）逐层定位，实际是 6 个问题叠加：

### 17.1 本地 HLS 服务的两个致命实现问题

| 问题 | 后果 |
| --- | --- |
| 客户端 socket 没有 `SO_NOSIGPIPE` | 快进 / 拖动时 AVPlayer 直接关掉连接，下一次 `write` 触发 `SIGPIPE`，**整个 App 被系统杀掉** |
| 单线程串行处理连接 | 一个被播放器放弃的连接会让 `write` 永久阻塞，整个服务随即卡死，后面所有分片请求都拿不到数据 → 明明「有缓冲」却一直卡住 |

处理（[LocalHLSServer.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/LocalHLSServer.swift)）：

- 每个连接独立线程处理；
- 客户端 socket 设置 `SO_NOSIGPIPE` 与 `SO_SNDTIMEO=10s`；
- 监听 fd 只由接收线程关闭（上一节）。

### 17.2 播放列表被读到半截

ffmpeg 重写 m3u8 是「先截断再写」。AVPlayer 恰好在这个瞬间请求，会拿到 0 字节或半截列表，按「流已结束」处理并停在原地，之后也不会自己恢复。

处理：服务播放列表时校验 `#EXTM3U`、结尾换行、至少一个分片 / `#EXT-X-ENDLIST`；校验失败短暂重试，仍失败就回退到上一份完整快照，绝不把半截列表发出去。

### 17.3 播到「已生成末尾」后暂停，并连带挂起转码

AVPlayer 播到当前 EVENT 列表末尾会进入 `.paused`。原逻辑用 `isPlaying` 控制转码生成：一暂停就 `SIGSTOP` ffmpeg → 新分片永远不会再产生 → 永久卡死。

处理：

- 转码开关改用 `wantsPlayback`（用户意图），不再用瞬时播放状态；
- [VideoPlayerModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoPlayerModel.swift) 增加 0.5s 看护：`wantsPlayback == true` 且播放器意外 `.paused` 且未到片尾时，重新 `playImmediately(atRate:)`。

### 17.4 多音轨会话入口地址错误

多音轨生成的入口是 `master.m3u8`，但会话统一返回 `/live.m3u8`（该文件不存在）→ 404，表现为「刚进来播一下就停」。已按 `isMultiAudio` 返回正确入口。

### 17.5 转码吞吐跟不上播放

日志里 DV 2160p 走 `mode=transcode` + libplacebo，播放 10 分钟后在固定秒数长时间卡住；烧录内嵌字幕同样强制重编码。根因是 `libx264 veryfast` 在 4K 上明显慢于实时。

处理：转码编码器改为 `h264_videotoolbox`（`-b:v 12M`、`allow_sw` 回退）。实测同一 DV 片源 30 秒片段：

| 编码器 | 耗时 | 吞吐 |
| --- | --- | --- |
| libx264 veryfast | 明显慢于实时 | 缓冲持续倒退 |
| h264_videotoolbox | 10.5s | ≈ 2.8× 实时 |

### 17.6 新增诊断

卡住超过 5 秒会写一条：

```text
缓冲等待 <秒>s：已生成领先 <秒>s · mode=remux/transcode
```

- 领先为 0 或负数 → 转码/读盘跟不上；
- 领先几百秒却还在等 → 服务或播放器问题（对应 17.1 / 17.2 / 17.3）。

同时 ffmpeg 被挂起 / 恢复时会记录原因（用户暂停 / 提前量过大）。

## 18. NAS / SMB 片源适配（2026-11-22）

**现场结论**：`/Volumes/迅雷` 是 Synology 的 `smbfs` 挂载，实测读取约 22 MB/s。57 GB 的 4K REMUX 码率接近 10 MB/s，转封装生成只有约 1.7× 实时，ffmpeg 大部分时间处于磁盘等待（`ps` 状态 U）。因此前几分钟缓冲很薄，共享盘一抖动就卡；领先攒到几百秒后才稳定。

**改动**：

| 位置 | 改动 |
| --- | --- |
| [VideoSupport.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/VideoSupport.swift) | 网络卷探测超时 15s → 45s；播放前探测跳过 `-show_chapters`（MKV 章节在文件尾部，SMB 上要跨大半个文件） |
| 同上 | 起播后不再对网络卷跑第二次技术探测：它和 ffmpeg 抢同一块带宽，会让正在播的片源变卡；章节 / 码率信息以起播探测为准 |
| [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoStreamSession.swift) | 起播前先攒 `startupLeadSeconds`（4–8s）生成量，最多多等 6s：避免「刚出画面就卡一下」 |

**日志**：起播时会记录 `起播缓冲 Xs / 目标 8s`；播放中每 10 秒记录 `播放心跳 pos=… 领先=…s`；卡住时输出完整 AVPlayer 状态快照。

**注意**：22 MB/s 是链路 / NAS 的硬上限。4K REMUX 想稳定播放，建议检查 NAS 到 Mac 的连接（优先有线 2.5G/10G，避免 Wi-Fi 半双工）；否则片源码率接近带宽时，任何抖动都会直接表现为缓冲。

## 19. HDR 屏判定：`NSScreen.main` 为 nil 时误转码（2026-11-22）

**现象**：4K60 HDR10 片源（`走马上任`）明明是 HDR 屏，却被送去 `libplacebo` 色调映射 + `hevc_videotoolbox` 转码，`缓冲等待` 每几十秒出现一次。

**根因**：`displaySupportsHDR` 只看 `NSScreen.main`。App 不在前台或窗口全屏切换的瞬间，`NSScreen.main` 为 nil → 判成 SDR 屏 → `needsToneMapping` 返回 true。实测该屏 `potentialEDR = 16.0`。

**修复**（[VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift)）：

- 优先用 `playerWindow?.screen`，其次 `NSScreen.main`；
- 窗口还没挂到屏幕上时，只要任意一块屏支持 EDR 就按 HDR 处理；
- 诊断日志补 `displayHDR=` / `edr=` / `override=`，下次直接看日志就能判断走了哪条策略。

## 20. ffprobe 探测把 MKV 误标成「原生可播」（2026-11-22）

**现象**：同一部 HDR MKV，11:07 还是 `mode=remux`，11:43 之后全部变成 `mode=transcode`，并且日志里多了一条：

```text
装片失败 …：AVFoundationErrorDomain -11828 incompatible=true
自动兼容转码 … at 1331s（AVFoundationErrorDomain -11828）
```

**根因**：为 NAS 适配新增的「网络卷只用 ffprobe 探测」路径（SMB 上的 MKV / AVI 跳过 AVFoundation，避免打开大文件黑屏）里，ffprobe 解析器无条件写了 `probe.isPlayable = true`。播放页据此认为系统能原生播放，把 MKV 直接交给 AVPlayer → `-11828` → 回退到「自动兼容转码」，于是 4K60 HDR 片被迫实时转码，转码速度追不上播放，表现为周期性缓冲。

**修复**（[VideoSupport.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/VideoSupport.swift)）：ffprobe 结果对本地文件统一走 `applyingNativePlayability`，复用 `VideoProbe.allowsNativePlayback` 的容器白名单——只有 `mp4 / m4v / mov / qt + HEVC` 才放宽为可直读，MKV / AVI / TS 等一律走 ffmpeg 转封装。这样既保留 `hev1` 误报的修复，也不会再把 MKV 送进原生播放。

**日志判据**：起流日志出现 `mode=remux` 即正确；若又看到 `装片失败 -11828 + 自动兼容转码`，说明探测仍把容器判成原生可播。

## 21. 播放中挂起 ffmpeg → AVPlayer 判定「流已结束」（2026-11-22）

**现象**：`走马上任 S01E06` 播到 350s 卡住，暂停态转圈；日志 `缓冲等待 16s：已生成领先 1129s · mode=remux · empty=true keepUp=false ranges=[188.7-239.1]`。分片明明都在，播放器就是不再拉。

**现场链**：

1. `12:29:55 生成挂起（提前量过大）`：领先量超过 1200s，`SIGSTOP` 停掉 ffmpeg；
2. 之后 `live.m3u8` 停在 327 个分片不再变化；
3. `12:30:50` 系统日志出现决定性错误：

```text
CoreMediaErrorDomain Code=-12888 "Playlist File unchanged for longer than 1.5 * target duration"
fpfs_BytePumpFn: At end of all streams; result = -12888, end flag Yes
```

4. AVPlayer 的 HLS 引擎把 EVENT 列表当直播流：超过 **1.5 × TARGETDURATION**（11s × 1.5 ≈ 16.5s）不更新就判定流已结束，不再请求新分片；
5. AVPlayer 手上约 75 秒缓冲播完（`350.7 - 275 ≈ 75s`），停在缓冲末尾，直到重建流才恢复。

**修复**（[VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoStreamSession.swift)）：

- 删除「提前量过大 → SIGSTOP」的生成节流：播放中 ffmpeg 一直生成到片尾，列表持续增长，最后写出 `#EXT-X-ENDLIST`，AVPlayer 转为 VOD 模式；
- 用户暂停也不再挂起生成（暂停后恢复同样会触发 -12888，恢复播放即卡死）；
- `setGenerationActive` 只保留给影院「预热下一集」：此时还没有播放器在读该列表，出首段后暂停是安全的，真正开播时恢复。

**代价**：播放期间会把该集完整写进工作目录（4K 一集约 1–2GB），会话结束统一清理；换来的是 EVENT 列表不再停更。

**判据**：日志不再出现 `生成挂起（提前量过大）`；如系统日志再次出现 `-12888`，说明还有别的路径在挂起生成。

## 22. 网盘直连被单连接限速（2026-11-22）

**现象**：网络视频播到 4634s 卡住；日志 `缓冲等待 … 领先 -4634s · mode=remux · empty=false keepUp=false ranges=[4604.8-4634.6]`。

`领先 -4634s` 说明当时没有本地 HLS 会话（`streamSession == nil`），是 AVPlayer 直连网盘直链在播。

**根因**（系统日志里的实测吞吐）：

```text
SEGPUMP MediaHandleDownloadTimer: bw 326.916 kbps required 856.179 dur 10.01
  received 409378 bytes in 10.0179 seconds latency 284 ms
```

CDN 只给了 **327 kbps**，片源需要 **856 kbps**，连实时都不到一半，缓冲只会越来越薄直到卡死。直连播放是单条 HTTP 连接，网盘按连接限速时没有任何余量。

**修复**：

- [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift)：新增 `onNativeStall`。直连播放（没有本地会话）卡住 8 秒就上报一次，提示「改用本地转封装」；
- [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift)：收到后从当前位置重建为 ffmpeg 转封装会话。远端输入走 `RemoteRangeSource`，按档位**并发预取**（流畅档 8 路），并对直链过期做 403 重解析 —— 单连接 327kbps 的场景下，多连接通常能到实时所需之上。

**判据**：日志出现 `直连播放卡住 8s，改用本地转封装（并行预取）` 后，`首段就绪 … mode=remux`，之后应出现 `播放心跳 pos=… 领先=…s` 且领先为正、随时间增长。若转封装后领先仍不增长，说明网盘对账号整体限速，需要开通会员或换链路。

## 23. 跳转起播「先声音、后画面、再卡一下」（2026-11-23）

**现象**：续播 / 拖动后起播，先出声音，隔一会才有画面，随后又顿一下。

**原因**（日志 `起播缓冲 5s / 目标 3s` + `缓冲等待 5s：已生成领先 10s · ranges=[0.0-9.9]`）：

1. 重建流只攒了约 3 秒生成量就装片，播放器出画面几秒后缓冲就耗尽 → 卡一下；
2. 装片用的是 `playImmediately(atRate:)`，音频轨先就绪就先出声，视频轨还在解首帧；
3. 起播定位用了零容差 seek，播放器必须从前一个关键帧解完整个 GOP 才出画面，
   这段时间正好只剩音频在响。

**修复**：

| 位置 | 改动 |
| --- | --- |
| [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoStreamSession.swift) | 起播提前量 1.5/2.5/3.5s → **3/4/5s**（省流 / 均衡 / 流畅），等待上限 6s → 8s |
| [VideoPlayerModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoPlayerModel.swift) | 装片后首播改用 `play()`（等缓冲就绪），不再用 `playImmediately`；用户手动暂停后恢复仍用立即播放 |
| 同上 | 起播定位容差 0 → 0.5s：就近关键帧解码，首帧更快出来，音画一起起播 |

**判据**：日志应出现 `起播缓冲 8s / 目标 8s`，并且起播后不再有 `缓冲等待`。

## 24. 「只有声音没画面」：系统不可解码的 hev1 被送去直连（2026-11-23）

**现象**：`长安二十四计 S01E03 … H265.50fps.mp4` 播放时有声音、画面全黑。

**实测**（同一文件用 AVFoundation 探测）：

```text
isPlayable=false  videoTracks=1
track decodable=false  size=3840x2160  fps=50  codec=hev1
```

系统明确判定这条视频轨**不可解码**（4K50 hev1），但音频轨正常，所以 AVPlayer 会出声、画面黑屏且不报错。

**根因**：`VideoProbe.allowsNativePlayback` 为了绕开「hev1 的 HEVC 被误报 isPlayable=false」，对
「mp4 / mov / qt + HEVC」直接放宽为可直读，没有检查 `AVAssetTrack.isDecodable`。
误报和真的解不了在这一层分不开，于是真正解不了的片源也被送去直连。

**修复**：

| 位置 | 改动 |
| --- | --- |
| [PlaybackModels.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackModels.swift) | `VideoProbe` 新增 `isVideoDecodable`（来自 `AVAssetTrack.isDecodable`） |
| [VideoSupport.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/VideoSupport.swift) | 视频轨不可解码时**不再放宽**：`isPlayable = isVideoDecodable && …` |
| [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift) | 不可解码时起流模式直接选 `.transcode`（转封装救不回来），并记录 `视频轨系统无法解码，改走重编码` |

**结论**：这类 4K50/60 hev1 片源只能重编码（输出按像素率档位降到 ~2844×1600）。直连 / 转封装都会黑屏。

**补充（同日）**：MKV 等容器走 ffprobe 探测时拿不到 `isDecodable`，但实测 4K 50/60fps 的 HEVC 在这台机器上同样解不出画面。
现在对「HEVC + 高≥1700 + 帧率≥45」的片源直接选 `.transcode`，直连与转封装都不再尝试，省掉「黑屏 5–8 秒再降级」。
日志：`4K 高帧率 HEVC 直接重编码：… 3840x2160 fps=60`。

## 25. 4K60 HDR 转码只有 ~0.4× 实时：软解 + 色调映射（2026-11-23）

**现象**：`走马上任 S01E08`（4K60 HDR10）转码播放，`播放心跳 领先=1~5s` 且每几十秒 `缓冲等待`；ffmpeg CPU 300%。

**实测**（同一段 10 秒 4K60 HDR10 素材，输出 1440p）：

| 配方 | 用时 | 相对实时 |
| --- | --- | --- |
| 只解码（ffmpeg 默认软解） | 16.4s | **0.61×** |
| 只解码（`-hwaccel videotoolbox`） | 6.6s | **1.52×** |
| 当前管线：软解 + libplacebo 映射 + H.264 VT | 24.2s | 0.41× |
| 硬解 + libplacebo 映射 + H.264 VT | 18.4s | 0.54× |
| 硬解 + CPU scale 1440p + H.264 VT（SDR） | 6.8s | 1.48× |
| **硬解 + CPU scale + HEVC VT 10bit（保留 HDR）** | **6.7s** | **1.49×** |

**根因**：

1. ffmpeg 默认**软解** 4K60 HEVC，单这一项就只有 0.6× 实时；
2. HDR 屏上也强制跑 libplacebo 色调映射（`needsToneMap` 没看屏幕能力），4K60 上再砍掉一截。

**修复**：

| 位置 | 改动 |
| --- | --- |
| [StreamPlanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/StreamPlanner.swift) | 重编码输入加 `-hwaccel videotoolbox`（硬解） |
| 同上 | HDR 屏 + HDR10 源：`preserveHDR` 时不跑色调映射，`scale=-2:1440` + `format=p010le`，强制 HEVC 10bit 输出并写回 bt2020/smpte2084 标记 |
| [VideoStreamSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/VideoStreamSession.swift) | `needsToneMap` 增加 `!preserveHDR`；记录 `重编码保留 HDR（不映射）` |
| [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift) / [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift) | 上下文新增 `preserveHDR`，由「HDR 屏 且 未被用户强制映射」决定 |

**验证**：输出片段 `hevc Main 10 2560×1440 60fps bt2020/smpte2084`，AVFoundation 探测 `isPlayable=true / decodable=true`。
杜比视界仍走 libplacebo 映射（RPU 只能由它应用）。
