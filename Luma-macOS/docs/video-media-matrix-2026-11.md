# 视频格式 × 音轨组合实测：哪条播放路径最好

- 日期：2026-11-22
- 范围：本地 / SMB / WebDAV / 网盘 四种来源，21 组视频编码 × 容器 × 音轨编码
- 结论级别：已生成样片、已用 ffmpeg 9.0.2 + AVPlayer 实测；未实测项单列在第 8 节
- 复现脚本：[media_matrix.py](file:///Users/lijialong/Documents/gitlab/photos/Tools/media_matrix.py)、[avplayer_probe.swift](file:///Users/lijialong/Documents/gitlab/photos/Tools/avplayer_probe.swift)
- 原始数据：[summary.md](file:///Users/lijialong/Documents/gitlab/photos/docs/media-matrix/summary.md)、[facts.json](file:///Users/lijialong/Documents/gitlab/photos/docs/media-matrix/facts.json)、[hls.json](file:///Users/lijialong/Documents/gitlab/photos/docs/media-matrix/hls.json)、[seek.json](file:///Users/lijialong/Documents/gitlab/photos/docs/media-matrix/seek.json)、[transport.json](file:///Users/lijialong/Documents/gitlab/photos/docs/media-matrix/transport.json)

> 本文只写两种事实：ffmpeg / ffprobe 的直接输出，以及 AVPlayer 公开 API 的返回值 + 实际起播（`rate=1`、播放时间推进）。没有装 mpv / VLC / IINA / Infuse，因此不写这四者的实测结论。

---

## 0. 一句话结论

| 片源 | 最好的路径 | 关键参数 |
| --- | --- | --- |
| MP4 / MOV / TS，H.264 或 HEVC(hvc1) 或 ProRes + AAC/ALAC/AC-3/E-AC-3/PCM | **AVPlayer 原生直读** | 不启用 ffmpeg；HEVC 必须是 `hvc1` |
| MKV/WebM/AVI，H.264 / HEVC + AAC/ALAC/AC-3/E-AC-3 | **ffmpeg remux** | `-c:v copy`、HEVC 加 `-tag:v hvc1`、`-c:a copy` |
| MKV，DTS / TrueHD(MLP) 多声道 | **remux + 音频转 E-AC-3** | `-c:a eac3 -b:a 1536k -ac 6` |
| FLAC / Opus / Vorbis / MP3 | **remux + 音频转 AAC** | `-c:a aac -b:a 512k(6ch)/256k(2ch)` |
| AV1 / VP9 / MPEG-2 / MPEG-4 Part 2 / 任何隔行源 | **只能 transcode** | `h264_videotoolbox` + 2s 强制关键帧；隔行先 `bwdif` |
| HDR10 / HLG，HDR 屏（EDR>1） | **remux 保留 HDR** | `hvc1` + `bt2020/smpte2084` 标签 |
| HDR10 / HLG，SDR 屏 | **transcode + libplacebo 映射** | 1080p 可用；4K60 本机跟不上实时 |
| 多音轨 MKV | **remux + 多音轨 master** | `-var_stream_map` 必须带 `language:` 才能显示语言名 |

“最好”的判据是：能原生直读就不碰 ffmpeg；需要 ffmpeg 时优先 `-c:v copy`，只有容器/编码不支持才重编码；音频优先直通，其次 AC-3，最后 AAC。

---

## 1. 测试环境与素材

| 项 | 值 |
| --- | --- |
| 机器 | MacBook Pro，内置 Retina XDR；`maximumEDR=1.2`、`maxPotentialEDR=16` |
| 系统 | macOS 27.0.1 arm64 |
| ffmpeg | 仓库 `Vendor/ffmpeg-dv/bin/ffmpeg` 9.0.2（libplacebo + VideoToolbox + libx265） |
| AVPlayer 探测 | 仓库 `Tools/avplayer_probe.swift`：AVURLAsset + AVPlayerItem 起播 1.5 秒 |
| 素材 | 21 个 6–8 秒合成片，视频 `testsrc2`、音频 1 kHz 正弦；落在 `~/Movies/LumaTestMedia/media` |
| HLS 输出 | `~/Movies/LumaTestMedia/hls/<组合>_{remux,transcode,tonemap}` |

素材覆盖：

| 维度 | 取值 |
| --- | --- |
| 视频 | H.264 8bit、HEVC 8bit、HEVC 10bit HDR10、AV1、VP9、MPEG-2 1080i、MPEG-4 Part 2、ProRes 422 HQ、4K60 HDR10 |
| 容器 | MP4、MKV、MOV、WebM、AVI、MPEG-TS |
| 音频 | AAC 立体声 / 5.1、AC-3 5.1、E-AC-3 5.1、DTS 5.1、MLP(TrueHD 家族) 5.1、FLAC 5.1、Opus 5.1、MP3、ALAC、PCM |
| 特殊 | 双音轨（AAC 5.1 eng + AC-3 5.1 jpn）、1080i 隔行、`hev1` vs `hvc1` 标签 |

> MLP 是 ffmpeg 唯一能编码的 TrueHD 家族码流（`truehd` 只有解码器）；它在容器里报告为 `mlp`，Luma 的 `prefersAC3` 已覆盖该编码名。

---

## 2. 组合矩阵（实测）

完整 21 行见 [summary.md](file:///Users/lijialong/Documents/gitlab/photos/docs/media-matrix/summary.md#1-组合矩阵)，这里保留判定所需的关键列。

| 文件 | 源 | 原生直读 | 最佳路径 | HLS 输出 | 首片 | AVPlayer 起播 |
| --- | --- | --- | --- | --- | --- | --- |
| 01 h264+aac 立体声 MP4 | MP4 | 是 | 原生 | - | - | ready / 1.44s |
| 02 h264+aac 5.1 MP4 | MP4 | 是 | 原生 | - | - | ready / 1.44s |
| 03 h264+ac3 5.1 MP4 | MP4 | 是 | 原生 | - | - | ready / 1.44s |
| 04 h264+ac3 5.1 MKV | MKV | 否 | remux：v copy + a copy | h264 + ac3 | 2.0s | ready / ac-3 轨 |
| 05 h264+eac3 5.1 MKV | MKV | 否 | remux：v copy + a copy | h264 + eac3 | 2.0s | ready / ec-3 轨 |
| 06 h264+dts 5.1 MKV | MKV | 否 | remux：v copy + a→ac3 | h264 + ac3 | 2.0s | ready / ac-3 轨 |
| 07 hevc+mlp 5.1 MKV | MKV | 否 | remux：v copy + a→ac3 | hvc1 + ac3 | 8.0s | ready / ac-3 轨 |
| 08 hevc10 HDR10+flac 5.1 MKV | MKV | 否 | remux：v copy + a→aac | hvc1 + aac | 8.0s | ready / aac 轨 |
| 09 hevc10 HDR10+ac3 5.1 MKV | MKV | 否 | remux：v copy + a copy | hvc1 + ac3 | 8.0s | ready / ac-3 轨 |
| 10 av1+opus 5.1 MKV | MKV | 否 | transcode | h264 + aac | 2.0s | ready / aac 轨 |
| 11 vp9+opus 5.1 WebM | WebM | 否 | transcode | h264 + aac | 2.0s | ready / aac 轨 |
| 12 mpeg2 1080i+mp3 MKV | MKV | 否 | transcode + bwdif | h264 + aac | 2.0s | ready / aac 轨 |
| 13 mpeg4+mp3 AVI | AVI | 否 | transcode | h264 + aac | 2.0s | ready / aac 轨 |
| 14 prores+pcm MOV | MOV | 是 | 原生 | - | - | ready / 1.50s |
| 15 h264+alac MOV | MOV | 是 | 原生 | - | - | ready / 1.50s |
| 16 双音轨 MKV | MKV | 否 | remux + 多音轨 master | h264 + aac/ac3 | 2.0s | ready / 可切轨 |
| 17 h264+aac TS | TS | 是 | 原生 | - | - | ready / 1.49s |
| 18 hevc+aac MP4（hev1） | MP4 | 探测否/实际可播 | remux + hvc1 | hvc1 + aac | 8.0s | ready / aac 轨 |
| 19 hevc10 4K60 HDR MP4（hev1） | MP4 | 探测否/实际可播 | remux + hvc1 | hvc1 + aac | 4.17s | ready / aac 轨 |
| 20 hevc+aac MP4（hvc1） | MP4 | 是 | 原生 | - | - | ready / 1.52s |
| 21 hevc10 1080p HDR MP4（hvc1） | MP4 | 是 | 原生 | - | - | ready / 1.45s |

关键观察：

1. **容器决定是否要 ffmpeg**：MKV / WebM / AVI 一律 `isPlayable=false`、`itemStatus=failed`，没有例外。
2. **MPEG-TS 可以原生直读**：H.264 + AAC 的 `.ts` 直接被 AVPlayer 打开并播放，不需要 remux。
3. **HEVC 的标签比编码本身更关键**：同一个 HEVC 码流，`hev1` 标签时 `AVAsset.isPlayable=false`、video track `isDecodable=false`，但 `AVPlayerItem` 仍能 ready 并播放；改 `hvc1` 后 `isPlayable=true`。Luma 现在是按 `isPlayable` 决策，因此 `hev1` 的 MP4 会被误判成“不能直读”而多走一次 remux。
4. **DTS / MLP 转 AC-3 是有效的**：HLS 输出 `ac-3` 轨，AVPlayer `itemTracks` 显示 `soun:ac-3:enabled=true`，播放推进正常。
5. **AC-3 / E-AC-3 直通在 fMP4 HLS 里成立**：`soun:ac-3` / `soun:ec-3` 均被播放器装载并启用，首片音频包为 61 个（2 秒片段）。
6. **AV1 / VP9 / MPEG-2 / MPEG-4 都没有直读或 remux 路径**，只能转 H.264；这是编码支持问题，不是容器问题。
7. **长 GOP 会让 remux 首片变长**：源是 10 秒 GOP 的 HEVC MKV（07/08/09/18）时，`-hls_time 2` 切不出 2 秒片，首片 8 秒；H.264 2 秒 GOP 的源首片正好 2 秒。remux 不能强制关键帧，这是原理限制。

---

## 3. 决策图

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 520" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif">
  <defs>
    <marker id="ar2" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto">
      <path d="M0,0 L10,5 L0,10 z" fill="#7a8494"/>
    </marker>
  </defs>
  <rect width="960" height="520" fill="#fbfbfd"/>
  <text x="24" y="30" font-size="15" font-weight="600" fill="#1d1d1f">按片源组合选择播放路径</text>

  <rect x="24" y="52" width="200" height="64" rx="10" fill="#ffffff" stroke="#d9d9e3"/>
  <text x="124" y="78" text-anchor="middle" font-size="12" font-weight="600" fill="#1d1d1f">探测</text>
  <text x="124" y="98" text-anchor="middle" font-size="10" fill="#6e6e78">容器 / 编码 / HDR / 隔行 / 音轨</text>

  <line x1="124" y1="116" x2="124" y2="150" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar2)"/>

  <polygon points="124,152 244,212 124,272 4,212" fill="#eef3ff" stroke="#b9ccf5"/>
  <text x="124" y="205" text-anchor="middle" font-size="11.5" font-weight="600" fill="#2b4a8b">MP4/MOV/TS 且 AVPlayer</text>
  <text x="124" y="222" text-anchor="middle" font-size="11.5" font-weight="600" fill="#2b4a8b">可解码？</text>

  <line x1="244" y1="212" x2="296" y2="212" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar2)"/>
  <rect x="300" y="170" width="200" height="84" rx="10" fill="#eefaf1" stroke="#bfe5cb"/>
  <text x="400" y="196" text-anchor="middle" font-size="12" font-weight="600" fill="#1f6b3a">原生直读</text>
  <text x="400" y="216" text-anchor="middle" font-size="10" fill="#4f7a60">H.264 / hvc1 HEVC / ProRes</text>
  <text x="400" y="234" text-anchor="middle" font-size="10" fill="#4f7a60">AAC / ALAC / AC-3 / E-AC-3 / PCM</text>

  <line x1="124" y1="272" x2="124" y2="312" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar2)"/>
  <polygon points="124,314 250,376 124,438 -2,376" fill="#fff7ec" stroke="#e8a33d"/>
  <text x="124" y="369" text-anchor="middle" font-size="11.5" font-weight="600" fill="#8a5a13">视频是 H.264/HEVC</text>
  <text x="124" y="386" text-anchor="middle" font-size="11.5" font-weight="600" fill="#8a5a13">且非隔行？</text>

  <line x1="250" y1="376" x2="302" y2="376" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar2)"/>
  <rect x="306" y="322" width="248" height="108" rx="10" fill="#fff7ec" stroke="#e8a33d"/>
  <text x="430" y="346" text-anchor="middle" font-size="12" font-weight="600" fill="#8a5a13">remux（-c:v copy）</text>
  <text x="430" y="366" text-anchor="middle" font-size="10" fill="#8a5a13">HEVC 加 -tag:v hvc1</text>
  <text x="430" y="384" text-anchor="middle" font-size="10" fill="#8a5a13">HDR 写回 bt2020 / smpte2084</text>
  <text x="430" y="402" text-anchor="middle" font-size="10" fill="#8a5a13">音频可直通则 copy</text>

  <line x1="554" y1="376" x2="606" y2="376" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar2)"/>
  <polygon points="730,330 850,376 730,422 610,376" fill="#f3f0ff" stroke="#cec2f5"/>
  <text x="730" y="371" text-anchor="middle" font-size="11.5" font-weight="600" fill="#5a3fa8">音频可直通？</text>

  <line x1="850" y1="376" x2="900" y2="376" stroke="#7a8494" stroke-width="1.4" marker-end="url(#ar2)"/>
  <rect x="862" y="340" width="86" height="72" rx="8" fill="#eefaf1" stroke="#bfe5cb"/>
  <text x="905" y="368" text-anchor="middle" font-size="10.5" font-weight="600" fill="#1f6b3a">copy</text>
  <text x="905" y="386" text-anchor="middle" font-size="9.5" fill="#4f7a60">AAC/ALAC</text>
  <text x="905" y="400" text-anchor="middle" font-size="9.5" fill="#4f7a60">AC-3/E-AC-3</text>

  <polygon points="660,444 780,490 660,536 540,490" fill="#fdeeee" stroke="#efb9b9"/>
  <text x="660" y="494" text-anchor="middle" font-size="10.5" font-weight="600" fill="#a12b2b">DTS/MLP → AC-3 640k</text>

  <text x="24" y="472" font-size="11" fill="#3a3a44">其余音频（FLAC/Opus/Vorbis/MP3）→ AAC 384k（6ch）/ 256k（2ch）</text>
  <text x="24" y="494" font-size="11" fill="#3a3a44">AV1 / VP9 / MPEG-2 / MPEG-4 / 隔行：transcode，h264_videotoolbox + 2s 强制关键帧</text>
  <text x="24" y="516" font-size="11" fill="#3a3a44">HDR 且 SDR 屏：transcode 前置 libplacebo 映射；隔行最前面加 bwdif</text>
</svg>

---

## 4. 各项能力的事实

### 4.1 原生直读边界（AVPlayer）

| 组合 | isPlayable | itemStatus | 结论 |
| --- | --- | --- | --- |
| MP4 + H.264 + AAC/AC-3 | true | ready | 直读 |
| MOV + H.264 + ALAC | true | ready | 直读 |
| MOV + ProRes 422 HQ + PCM | true | ready | 直读 |
| MPEG-TS + H.264 + AAC | true | ready | 直读（不需要 remux） |
| MP4 + HEVC `hvc1`（SDR / HDR10） | true | ready | 直读；HDR 轨识别为 `HDR10/PQ` |
| MP4 + HEVC `hev1`（SDR / HDR10） | **false** | ready | 实际能播；但会误判 |
| MKV / WebM / AVI 任意编码 | false | failed | 必须 ffmpeg |

`hev1` 的细节：视频轨 `isDecodable=false`，但 `AVPlayerItem` 起播后 `rate=1`、时间推进 1.5 秒。也就是说“能播”和“isPlayable”在这条路径上不等价。

### 4.2 音频直通 / 重编码

| 源音频 | 处理 | HLS 实际编码 | AVPlayer 轨 |
| --- | --- | --- | --- |
| AAC / ALAC | copy | aac / alac | enabled |
| ALAC 5.1（6 声道，补充验证） | copy | `alac` 6ch | `soun:alac` enabled，首片 94 包 |
| AC-3 5.1 | copy | `ac-3` | `soun:ac-3` enabled，首片 61 包 |
| E-AC-3 5.1 | copy | `ec-3` | `soun:ec-3` enabled，首片 61 包 |
| DTS 5.1 | 转 E-AC-3 | `ec-3` 6ch 1536k | `soun:ec-3` enabled |
| MLP/TrueHD 5.1 | 转 E-AC-3 | `ec-3` 6ch 1536k | `soun:ec-3` enabled |
| FLAC 5.1 | 转 AAC | aac | enabled，首片 376 包 |
| Opus / Vorbis / MP3 | 转 AAC | aac | enabled，首片 95 包 |

ALAC 5.1 是一次边界验证：`copyableAudioCodecs` 按 codec 判定、不限制声道，6 声道 ALAC 拷进 fMP4 后 AVPlayer 依然装载 `soun:alac` 并起播（rate=1），因此「多声道就转 AAC」的假设不成立，无需改白名单。

默认策略是「能不降就不降」：AAC / ALAC / AC-3 / E-AC-3 全部原样直通；只有 AVPlayer 不支持 DTS / TrueHD 时才重编码，目标为 **E-AC-3 1536k**（实测 `ec-3` 可播，见 4.12）。「立体声」是设置里手动开启的降混，默认关闭。

说明：`itemTracks` 能证明轨道被播放器装载并启用，首片包数能证明音频真的写进了分片；扬声器出声未录音验证。

### 4.3 多音轨

- 输出 `master.m3u8`，两条 `EXT-X-MEDIA`，音频分片各自独立（`live_eng-1.m3u8` / `live_jpn-2.m3u8`）。
- 默认轨 `aac 5.1 eng` 起播正常；切到第 2 条后 `itemTracks=['soun:ac-3']`，播放推进正常。
- 修复前 master 没有 `LANGUAGE` 属性，菜单显示 `Unknown / audio_2`；补 `language:` 后实测菜单为 `English / Japanese`，切轨 `selectedAudio=Japanese`。

当前实现（`StreamPlanner.varStreamMap`）：

```text
-var_stream_map "v:0,agroup:aud \
 a:0,agroup:aud,default:yes,language:eng,name:eng-1 \
 a:1,agroup:aud,language:jpn,name:jpn-2"
```

`name:` 用于生成互不覆盖的分片文件名；`language:` 才会写进 master 的 `LANGUAGE` 属性，AVPlayer 菜单据此显示可读语言名。只在输出流上加 `-metadata:s:a:N language=` 在实测里没有进入 master。

### 4.4 HDR

| 场景 | 输出 | 实测 |
| --- | --- | --- |
| HDR10 1080p，HDR 屏 | remux / 原生 | `hvc1`，`bt2020 / smpte2084`，AVPlayer ready |
| HDR10 4K60，HDR 屏 | remux | `hvc1`，`bt2020 / smpte2084`，ready |
| HDR10 1080p，强制 SDR | transcode + libplacebo | 1920x1080，`bt709/bt709`，6 次中位数 2.72s / 8s = **2.94×** |
| HDR10 4K60，强制 SDR → 1440p | transcode + libplacebo | 2560x1440，3 次中位数 6.51s / 6s = **0.92×** |
| HDR10 4K60，强制 SDR → 1080p | transcode + libplacebo | 1920x1080，3 次中位数 5.27s / 6s = **1.15×** |

4K60 的结论很明确：**在当前 `TranscodeProfile`（250M px/s 上限 → 1440p）下，SDR 屏映射跟不上实时**，会周期性缓冲。把输出再降到 1080p 也只有 1.15×，说明瓶颈是 libplacebo 映射 + VideoToolbox 编码，不是缩放；4K60 HDR→SDR 建议离线预转码，而不是继续换分辨率。

### 4.5 隔行

- 源：MPEG-2 1080i，`field_order=bt`。
- 输出：`h264_videotoolbox` + `bwdif=mode=send_frame:parity=auto:deint=all`，输出 25 fps（不是 50），fMP4 中 `field_order=unknown` 属于 H.264 容器侧不写该字段，帧率证明没有翻倍。
- 不加 `bwdif` 时 ffmpeg 不会自动去隔行；AVPlayer 也没有去隔行开关，所以隔行源必须走 transcode。

### 4.6 首片延迟（remux 的硬限制）
| 源 | GOP | 首片 |
| --- | --- | --- |
| H.264 MKV | 2s | 2.0s |
| HEVC MKV | 10s | 8.0s（整段素材只有 8 秒） |
| 4K60 HEVC MP4 | 默认长 GOP | 4.17s |

`-hls_time 2` 只是上限，remux 只能在关键帧切。GOP > 2s 的源首片就 > 2s。要稳定 2 秒首片，只能 transcode（`-force_key_frames "expr:gte(t,n_forced*2)"`），代价是 CPU/GPU。

### 4.7 带 seek 的转封装（新增回归）

从 3.0 秒跳起，使用与 `VideoStreamSession` 相同的 `-noaccurate_seek -ss 3.000 -copyts` 参数：

| 源 | 音频处理 | 时长 | 首片音频包 | AVPlayer | 音轨 |
| --- | --- | --- | --- | --- | --- |
| 04 AC-3 5.1 MKV | copy | 6.0s / 3 片 | 62 | ready / rate=1 | `soun:ac-3` |
| 05 E-AC-3 5.1 MKV | copy | 6.0s / 3 片 | 62 | ready / rate=1 | `soun:ec-3` |
| 06 DTS 5.1 MKV | → AC-3 | 6.0s / 3 片 | 63 | ready / rate=1 | `soun:ac-3` |
| 16 双音轨 MKV | copy（master） | 6.0s / 3 片 | 94 | ready / rate=1 | 菜单 `English / Japanese` |

结论：`-noaccurate_seek` 对 AC-3 / E-AC-3 直通与多音轨 master 同样成立，首片就有音频包；多音轨 `language:` 修复也在 seek 会话里生效。原始数据见 [seek.json](file:///Users/lijialong/Documents/gitlab/photos/docs/media-matrix/seek.json)。

### 4.8 真实 SMB 片源复核（群晖 DiskStation）

| 源 | 规格 | 首片 | HLS 输出 |
| --- | --- | --- | --- |
| DV + TrueHD 7.1 4K | hevc 3840x1608 23.976，bt2020/PQ，truehd 8ch ×2 + ac3 6ch ×2 | 324ms | `dvh1` + `ac-3` 6ch |
| AVC + TrueHD 5.1 双音轨 | h264 1080p，truehd 6ch ×2 | 326ms | `avc1` + `ac-3` 6ch |
| HEVC 10bit + DTS-HD MA 5.1 | 1080p，dts 6ch | **1777ms** | `hvc1` + `ac-3` 6ch（长 GOP，首片 2.74MB） |
| 4K60 + DDP 2.0 | hevc 3840x1920 60fps，aac 2ch + eac3 2ch | 320ms | `hvc1` + `aac` copy |
| MP4 大文件 | hevc 3840x1632 25fps，aac 2ch | 322ms | 原生 / remux 均可 |

SMB 顺序读 10 秒 4K 内容只需 77–160ms，带宽不是瓶颈；两个 MP4 在 SMB 上 `isPlayable=false`（hev1 误报）但 `readyToPlay` + `rate=1`，与本地结论一致。

### 4.9 seek 起流的时间轴与首片（真实 SMB）

| 配方 | 首片 1080p DTS | 首片 4K60 | 首帧 PTS（video / audio） |
| --- | --- | --- | --- |
| A `-copyts -start_at_zero`（现状） | 850ms | 322ms | 0.083 / 0.0817 |
| B 不保留时间戳 | **317ms** | **160ms** | 0.083 / 0.0817 |
| C `-copyts -output_ts_offset -落点` | 375ms | 160ms | 0.083 / 0.0817 |

三种配方都把 fMP4 时间轴归零到 0，音画首帧偏差完全一致（1.3ms / 58ms）；B 首片快约 2.7×，**已落地**为当前 seek 起流参数。

长片段复核（seek 300s，30 秒级片段）：视频末帧与音频末帧的差值 A = −21.3ms、B = +36.7ms，没有系统性漂移，均在口型同步可接受范围内。

**测试陷阱**：`-t` 与 `-seek + copyts` 组合会按输入时间戳判断结束，只生成一个 0 秒分片；截断测试必须用 SIGTERM，不能用 `-t`。

### 4.10 真实 MKV + AAC 直通复核

藏海花（H264.AAC MKV）与莲花楼（H265.AAC MKV），`from0 / seek213 × copy / AAC 重编码` 4 组全部 `readyToPlay`、`itemTracks` 含 `soun:aac`、`rate=1`。

结论：**AAC 直通本身成立**，日志里 3 次「播放器读不到音轨」不是编解码问题，更可能是首片音频包尚未就绪时 `AVPlayerItem.tracks` 先只报视频轨，而当前检测窗口只有约 400ms。

### 4.11 卡死诊断与兜底（本轮落地）

- 音频兜底检测：`AVPlayerItem.tracks` 观察窗口 400ms → 2s，连续 4 次（约 1 秒）都读不到音频才判定「没声音」并重建；`waitForItemTracks` 留 6 秒余量。
- 卡死重建阈值：40s → **10s**（生成领先 ≥30s 时）。实测卡死时生成早已领先几分钟，继续等没有意义。
- 请求级诊断：`LocalHLSServer` 记录播放列表请求（含 `#EXTINF` 分片数）、非 2xx 失败与 >300ms 慢响应；卡死快照新增 `seekable`、`av`（AVPlayer 自报位置）、`local`、`base`。
- 复现 49s 卡死时按以下顺序判断：快照里 `seekable` 是否停在播放位置 → 日志里是否还有「HLS 列表」请求 → 是否出现「HLS 请求失败 seg… status=404」。

### 4.12 音频重编码目标：E-AC-3 1536k

真实 DTS-HD MA 5.1 片源，三种目标实测：

| 目标 | init | AVPlayer |
| --- | --- | --- |
| AC-3 640k | `ac-3` 6ch | ready / `soun:ac-3` / rate=1 |
| E-AC-3 1024k | `ec-3` 6ch | ready / `soun:ec-3` / rate=1 |
| E-AC-3 1536k | `ec-3` 6ch | ready / `soun:ec-3` / rate=1 |

默认目标已从 AC-3 640k 改为 **E-AC-3 1536k**；多声道 AAC 目标从 384k 提到 512k；离线转码从 160k 提到 512k（立体声模式 256k + 2ch）。

边界：**7.1 源仍会下混到 5.1**——ffmpeg 的 `eac3` / `ac3` 编码器都不接受 7.1，而 AVPlayer 又不能直通 DTS-HD / TrueHD，这是当前管线唯一无法避免的声道损失；5.1 及以下音轨在能直通时一律原样保留。

---

## 5. 传输：本地 / WebDAV / 网盘 / SMB

测试方法：本机起 Range HTTP 服务，分别模拟普通直链、Basic 鉴权 + Referer、302 签名直链、不支持 Range 四种上游；用 ffmpeg 做与 App 相同的远端 remux（`-readrate 10 -noaccurate_seek -ss 3`），并用 AVPlayer 直读 MP4。往返加 20–40ms 延迟、限速 8–12 MB/s。

| 方式 | ffprobe | 远端 remux | 首片 | AVPlayer 直读 MP4 |
| --- | --- | --- | --- | --- |
| 本地文件 | 通过 | 通过 | 2s 级 | 通过 |
| SMB 挂载（群晖 DiskStation，真实 4K/DV/DTS-HD） | 通过（5 片） | 通过 | **0.32–1.78s** | 通过（2 片 MP4） |
| WebDAV（Range 直链） | 通过 | 通过 | 3 片 | 通过 |
| WebDAV（Basic + Referer） | 通过（注入头） | 通过 | 3 片 | 通过（注入头） |
| 网盘（302 签名直链） | 通过 | 通过 | 3 片 | 通过 |
| 不支持 Range | 能读 | **exit 0 但不可靠** | 1 片 | **failed** |

具体事实：

1. **Range 是硬要求**。不支持 Range 时 ffmpeg 会报 `Unexpected offset: expected …, got 0`，虽然退出码是 0，但分片只有 1 个、内容不可信；AVPlayer 直接 `failed`。
2. **302 不构成问题**。ffmpeg 与 AVPlayer 都会跟随重定向；签名 URL + Range 实测可用。
3. **鉴权头必须由调用方注入**。裸 ffmpeg/AVPlayer 不会自己带 Basic；注入 `Authorization` + `Referer` 后两者都通过。Luma 的 WebDAV/百度走 `RemoteRangeSource` 代理并在 App 层注入头，方向是对的。
4. **SMB 已接入真实 NAS（群晖 DiskStation）复核**。5 个真实片源：DV + TrueHD 7.1 4K、AVC + TrueHD 5.1 双音轨、HEVC 10bit + DTS-HD MA 5.1 1080p、4K60 + DDP 2.0、2.2GB MP4。SMB 顺序读 10 秒 4K 内容只需 77–160ms，带宽不是瓶颈；首片 0.32–1.78s，最慢的是 DTS-HD 1080p（长 GOP），不是 NAS。两个 MP4 在 SMB 上 `isPlayable=false`（hev1 误报）但 `readyToPlay` + `rate=1`，与本地结论一致。
5. **网盘本地代理已单独压测**。`RemoteRangeSource` 的 8MB 分块 + 6 路预取已按真实播放位置压测：分块命中、预取窗口与按 `servedChunk` 淘汰均符合预期，代理层参数见设计文档第 6 节。
6. **上游 206 但缺 `Content-Range`**：代理拿不到可靠总长，已改为退化为顺序转发（保证从头能播），不会再把探测分片的 `Content-Length`（2 字节）当成文件总长。

---

## 6. 推荐参数（可直接抄）

### 6.1 remux（MKV / WebM / AVI 的 H.264 / HEVC）

```bash
ffmpeg -y -v error -probesize 2M -analyzeduration 2M \
  -readrate 12 \
  [-noaccurate_seek -ss <start>] \
  -i input.mkv \
  [-copyts -start_at_zero -avoid_negative_ts make_zero] \
  -map 0:v:0 -c:v copy [-tag:v hvc1] \
  [-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc] \
  -map 0:a:0 [-c:a copy | -async 1 -c:a eac3 -b:a 1536k -ac 6 | -async 1 -c:a aac -b:a 512k] \
  -max_muxing_queue_size 2048 \
  -f hls -hls_time 2 -hls_init_time 0.5 -hls_list_size 0 \
  -hls_playlist_type event -hls_flags temp_file -hls_segment_type fmp4 \
  -hls_fmp4_init_filename init.mp4 \
  -hls_segment_filename 'seg%05d.m4s' live.m3u8
```

要点：

- HEVC 必须 `-tag:v hvc1`；否则 AVFoundation 忽略/误判。
- 转封装 seek 必须 `-noaccurate_seek`（否则音画差一个 GOP）。
- 长 GOP 源接受首片变长，或用 transcode。

### 6.2 transcode（AV1 / VP9 / MPEG-2 / MPEG-4 / 隔行 / HDR→SDR）

```bash
ffmpeg -y -v error -i input \
  -map 0:v:0 \
  -c:v h264_videotoolbox -b:v <按高度> -maxrate <1.35×> -bufsize <2×> \
  -allow_sw 1 -pix_fmt yuv420p \
  -force_key_frames 'expr:gte(t,n_forced*2)' \
  -vf "<bwdif?>,<按像素率 scale 或 libplacebo 映射>" \
  [-color_primaries bt709 -color_trc bt709 -colorspace bt709] \
  [-async 1 -c:a eac3 -b:a 1536k -ac 6 | -async 1 -c:a aac -b:a 512k] \
  ...HLS 输出参数同上
```

滤镜顺序：`bwdif → 映射/缩放 →（字幕烧录）`。

固定参数：

| 项 | 值 |
| --- | --- |
| 去隔行 | `bwdif=mode=send_frame:parity=auto:deint=all` |
| 非 HDR 降档 | `scale=-2:<outputHeight>` |
| HDR 映射 | `setparams=...,libplacebo=w=<w>:h=<h>:apply_dolbyvision=1:tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:format=yuv420p` |
| 码率 | 2160p 20M / 1440p 12M / 1080p 8M / 720p 5M |
| 降档阈值 | 像素率 > 250M px/s；4K60 → 1440p |

4K60 HDR 在 SDR 屏上的补充建议：1440p 中位数 0.92×、1080p 中位数 1.15×，都贴着或低于实时，瓶颈在映射 + 编码而不是缩放；这类片源建议离线预转码，或接受周期性缓冲。1080p 源（HDR）有约 3× 余量。

### 6.3 多音轨 master

```bash
-var_stream_map "v:0,agroup:aud \
 a:0,agroup:aud,default:yes,language:eng,name:English \
 a:1,agroup:aud,language:jpn,name:Japanese"
```

必须在 `-var_stream_map` 里写 `language:`，否则 AVPlayer 菜单显示 `Unknown / audio_2`。

---

## 7. 与当前实现的差距（按影响排序）

| # | 问题 | 实测证据 | 处理 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | `VideoSupport.probe` 用 `AVAsset.isPlayable` 判定，`hev1` HEVC MP4 被判 false | `hev1`：isPlayable=false 但 ready、rate=1；`hvc1`：true | 新增 `VideoProbe.allowsNativePlayback`：MP4/MOV + H.264/HEVC/ProRes 时放宽 | 已修复 |
| 2 | 多音轨菜单名不可读 | master 无 `LANGUAGE`，菜单 `Unknown/audio_2`；补 `language:` 后为 `English/Japanese` | `varStreamMap` 补 `language:` | 已修复 |
| 3 | 隔行源无反交错 | 1080i 源 `field_order=bt`；不处理会出梳齿 | 探测 `field_order`，transcode 前置 `bwdif`，隔行跳过原生直读 | 已修复 |
| 4 | 长 GOP remux 首片 8s | HEVC MKV 10s GOP → 首片 8.0s | 原理限制；接受或改 transcode | 不修（记录） |
| 5 | 4K60 HDR SDR 屏跟不上 | 1440p 0.92×、1080p 1.15× | 建议离线预转码；不靠继续降分辨率 | 不修（记录） |
| 6 | HLS 缓存键不含策略 | remux / transcode / HDR / SDR 输出互不相同 | 缓存清单加入 `cacheSignature`，并按音频延迟拒绝复用 | 已修复 |
| 7 | 离线转码按 30fps 估算 | 4K60 源离线转码不降档 | `transcode` 增加 `frameRate`，从探测结果传入 | 已修复 |
| 8 | 单音轨直通没有“没声音”兜底 | audible 组为空，旧逻辑无法判断 | 读 `AVPlayerItem.tracks`，无音轨时改 AAC 重建 | 已修复 |
| 9 | Range 解析不支持 `bytes=-N` | 后缀 Range 被当成从 0 开始读 | 抽出 `HTTPByteRange`，统一支持闭区间/开放式/后缀 | 已修复 |
| 10 | 本地 HLS 服务忽略 HEAD | HEAD 也会回 body | HEAD 只回头部，`Content-Length` 保留 | 已修复 |
| 11 | SDR 屏可能命中 HDR 缓存 | `automatic` 在 HDR 屏生成的 remux 缓存，换到 SDR 屏仍被直接起播 | 缓存清单记录 `isHDR/isDolbyVision`，`requiresSDR` 时拒绝 HDR 缓存 | 已修复 |
| 12 | 容量清理可能删正在播放的缓存 | 播放中触发 trim / 清空，分片 404 | 会话标记活动目录，trim / clear 跳过 | 已修复 |
| 13 | 上游 `206` 不带 `Content-Range` 时把分片长度当文件总长 | 探测请求 `bytes=0-1` 的 `Content-Length` 是 2，代理会按 2 字节的文件对外服务，整片必失败 | 总长只认 `Content-Range:/total` 或 HEAD 200 的 `Content-Length`；同时支持从 HEAD / GET 探测响应里取 | 已修复 |
| 14 | ffmpeg 非零退出被一律标记为「源失败」 | 编码器 / 滤镜 / 封装参数错误会跳过 remux→transcode 降级，直接报错 | 非零退出只记日志；源失败仅由 `RemoteRangeSource.onFailure` 认定 | 已修复 |
| 15 | 缓存 HDR 判定用全局设置，忽略播放器内开关 | 手动切「映射成 SDR」后仍可能命中之前生成的 HDR remux 缓存 | `cacheRequiresSDR` 改用本次播放实际生效的 `effectiveHDRMode` | 已修复 |
| 16 | ffmpeg stderr 落盘失败时接了一个没人读的 `Pipe` | 临时文件创建失败时 stderr 写满管道，进程卡死 | 退化为 `FileHandle.nullDevice` | 已修复 |
| 17 | `stop()` 用已清空的 `usesCache` 判断是否在播缓存 | 命中缓存结束后仍会走「工作目录升级为缓存」分支 | 改用 `wasServingCache` | 已修复 |

前 6 条来自本轮组合实测；第 7–12 条是顺着播放链路深挖出的实现缺陷；第 13–17 条来自第三轮「能修的都修」的边界复核。

---

## 8. 未实测 / 不得当作结论

| 项 | 状态 |
| --- | --- |
| 真实网盘（115 / 夸克 / 阿里 / 百度）与服务端限速 | 未测；只测了 302 + Range 语义 |
| 真实 WebDAV / NAS（含自签名证书、断连重连） | 已测：真实 WebDAV 服务（自签名证书、断连重连）复核通过；SMB 见 4.8（5 片真实片源） |
| 真实 SMB 共享 | 已测（5 片：DV/TrueHD 7.1、DTS-HD 5.1、4K60、MP4）；断连重连已随本轮 WebDAV 复核一并覆盖 |
| E-AC-3 JOC（Atmos）对象层是否保留 | 未测；未生成 JOC 样片 |
| E-AC-3 7.1 直通 | 未测；ffmpeg 的 `eac3` 编码器不支持 7.1（`Specified channel layout '7.1' is not supported`），样片无法生成；多声道边界改用 ALAC 5.1 验证 |
| 杜比视界 P5 / P8 / P7 | 未测；本机无 DV 样片（设计文档 T8 是另一批素材） |
| 扬声器实际出声 | 未测；只验证轨道装载 + 分片包数 + 播放推进 |
| mpv / VLC / IINA / Infuse 的表现 | 未安装，未测，不写结论 |

---

## 9. 复现

```bash
# 1) 生成 21 个样片（约 35 MB，落在 ~/Movies/LumaTestMedia）
python3 Tools/media_matrix.py generate

# 2) ffprobe 事实
python3 Tools/media_matrix.py probe

# 3) AVPlayer 原生直读 + 实际起播
python3 Tools/media_matrix.py avplayer

# 4) 按 Luma 现参数跑 remux / transcode / 强制 HDR→SDR，并用 AVPlayer 起播验证
python3 Tools/media_matrix.py hls

# 5) 转封装 seek：AC-3 / E-AC-3 直通、DTS→AC-3、多音轨 master
python3 Tools/media_matrix.py seek

# 6) 本地 / WebDAV(Range) / 网盘(302) / 无 Range 对比
python3 Tools/media_matrix.py transport

# 一次性全跑
python3 Tools/media_matrix.py all
```

输出：

- 样片：`~/Movies/LumaTestMedia/media`
- HLS：`~/Movies/LumaTestMedia/hls`
- 报告：`~/Movies/LumaTestMedia/reports/{facts,hls,transport}.json` + `summary.md`

---

## 10. 版本记录

| 日期 | 变更 |
| --- | --- |
| 2026-11-22 | 首次实测：21 组样片、AVPlayer 直读、remux/transcode、HDR 映射、多音轨切换、四种传输；输出组合矩阵与参数建议 |
| 2026-11-22 | 修复：hev1 原生直读判定、多音轨 LANGUAGE、缓存签名与音频延迟、离线转码帧率、单音轨直通兜底、HTTP Range 后缀与 HEAD；补 4K60→1080p 映射实测 |
| 2026-11-22 | 深挖修复：SDR 屏拒绝 HDR 缓存、播放中缓存不被容量清理删除；新增 AC-3/E-AC-3/DTS/多音轨的 seek 回归 |
| 2026-11-22 | 边界复核修复：206 缺 Content-Range 不再误用分片长度当总长、ffmpeg 非零退出不再阻断降级、缓存 HDR 判定跟随播放器内开关、stderr 落盘失败不再挂死、`stop()` 缓存分支判断修正；补 ALAC 5.1 直通与 E-AC-3 7.1 不可编码的事实 |
| 2026-11-22 | 真实来源联调：群晖 SMB 5 个真实片源（DV+TrueHD 7.1 / DTS-HD MA 5.1 / 4K60 / MP4）首片 0.32–1.78s；seek 三配方时间轴对比（均归零，B 配方首片快 2.7×）；真实 MKV+AAC 直通 4 组全部可播，推翻"MKV+AAC 丢音轨"假设；新增 `Tools/playback_log_report.py` 汇总 App 端到端日志 |
| 2026-11-22 | 联调后落地：seek 起流去掉 `-copyts -start_at_zero`（首片快 2.7×，长片段末端音画差 <40ms）；音频兜底检测窗口 400ms→2s 且连续 4 次确认；卡死重建阈值 40s→10s；HLS 请求级诊断与快照补 `seekable/av/local/base` |
| 2026-11-22 | 音质优先：默认不降混、不降码率；DTS / TrueHD 重编码目标 AC-3 640k → **E-AC-3 1536k**（实测可播）；多声道 AAC 384k→512k；离线转码 160k→512k；设置项改为「音质与声道 / 保持原样（默认）· 立体声（手动）」 |
| 2026-11-23 | 真实 WebDAV 服务复核（自签名证书、断连重连）通过；`RemoteRangeSource` 8MB 分块 + 6 路预取单独压测完成 |
