# Luma 视频 / 音轨组合测试结果

生成时间：2026-11-22 17:31:12

## 1. 组合矩阵

| 文件 | 源视频 | 源音频 | 原生直读 | 最佳路径 | HLS 输出 | 首片秒 | 首片音频包 | AVPlayer 实际起播 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 01_h264_aac_stereo.mp4 | h264 High yuv420p 640x360 | aac 2ch | 是 | AVPlayer 直读（无 ffmpeg） | - | - | - | ready / rate=1 / 1.44s |
| 02_h264_aac_51.mp4 | h264 High yuv420p 640x360 | aac 6ch | 是 | AVPlayer 直读（无 ffmpeg） | - | - | - | ready / rate=1 / 1.44s |
| 03_h264_ac3_51.mp4 | h264 High yuv420p 640x360 | ac3 6ch | 是 | AVPlayer 直读（无 ffmpeg） | - | - | - | ready / rate=1 / 1.44s |
| 04_h264_ac3_51.mkv | h264 High yuv420p 640x360 | ac3 6ch | 否 | remux：v copy + a copy | video:h264, audio:ac3 | 2.0 | 61 | readyToPlay / rate=1 / 1.32s / vide:avc1:enabled=true,soun:ac-3:enabled=true |
| 05_h264_eac3_51.mkv | h264 High yuv420p 640x360 | eac3 6ch | 否 | remux：v copy + a copy | video:h264, audio:eac3 | 2.0 | 61 | readyToPlay / rate=1 / 1.38s / vide:avc1:enabled=true,soun:ec-3:enabled=true |
| 06_h264_dts_51.mkv | h264 High yuv420p 640x360 | dts 6ch | 否 | remux：v copy + a →ac3 | video:h264, audio:ac3 | 2.0 | 61 | readyToPlay / rate=1 / 1.46s / vide:avc1:enabled=true,soun:ac-3:enabled=true |
| 07_hevc_mlp_51.mkv | hevc Main yuv420p 640x360 | mlp 6ch | 否 | remux：v copy + a →ac3 | video:hevc, audio:ac3 | 8.0 | 250 | readyToPlay / rate=1 / 1.44s / vide:hvc1:enabled=true,soun:ac-3:enabled=true |
| 08_hevc10_hdr10_flac_51.mkv | hevc Main 10 yuv420p10le 640x360 | flac 6ch | 否 | remux：v copy + a →aac | video:hevc, audio:aac | 8.0 | 376 | readyToPlay / rate=1 / 1.45s / vide:hvc1:enabled=true,soun:aac:enabled=true |
| 09_hevc10_hdr10_ac3_51.mkv | hevc Main 10 yuv420p10le 640x360 | ac3 6ch | 否 | remux：v copy + a copy | video:hevc, audio:ac3 | 8.0 | 250 | readyToPlay / rate=1 / 1.41s / vide:hvc1:enabled=true,soun:ac-3:enabled=true |
| 10_av1_opus_51.mkv | av1 Main yuv420p 640x360 | opus 6ch | 否 | transcode：VT H.264 + aac | video:h264, audio:aac | 2.0 | 95 | readyToPlay / rate=1 / 1.46s / vide:avc1:enabled=true,soun:aac:enabled=true |
| 11_vp9_opus_51.webm | vp9 Profile 0 yuv420p 640x360 | opus 6ch | 否 | transcode：VT H.264 + aac | video:h264, audio:aac | 2.0 | 95 | readyToPlay / rate=1 / 1.44s / vide:avc1:enabled=true,soun:aac:enabled=true |
| 12_mpeg2_1080i_mp3.mkv | mpeg2video Main yuv420p 1920x1080 | mp3 2ch | 否 | transcode：VT H.264 + aac | video:h264, audio:aac | 2.0 | 95 | readyToPlay / rate=1 / 1.52s / vide:avc1:enabled=true,soun:aac:enabled=true |
| 13_mpeg4_mp3.avi | mpeg4 Simple Profile yuv420p 640x360 | mp3 2ch | 否 | transcode：VT H.264 + aac | video:h264, audio:aac | 2.0 | 95 | readyToPlay / rate=1 / 1.46s / vide:avc1:enabled=true,soun:aac:enabled=true |
| 14_prores_pcm.mov | prores HQ yuv422p10le 640x360 | pcm_s16le 2ch | 是 | AVPlayer 直读（无 ffmpeg） | - | - | - | ready / rate=1 / 1.5s |
| 15_h264_alac.mov | h264 High yuv420p 640x360 | alac 2ch | 是 | AVPlayer 直读（无 ffmpeg） | - | - | - | ready / rate=1 / 1.5s |
| 16_h264_aac51_ac351.mkv | h264 High yuv420p 640x360 | aac 6ch / ac3 6ch | 否 | remux：v copy + a copy（多音轨 master） | video:h264, audio:aac, audio:ac3 | 2.0 | 94 | readyToPlay / rate=1 / 1.41s / vide:avc1:enabled=true,soun:aac:enabled=true |
| 17_h264_aac_stereo.ts | h264 High yuv420p 640x360 | aac 2ch | 是 | AVPlayer 直读（无 ffmpeg） | - | - | - | ready / rate=1 / 1.49s |
| 18_hevc_aac_stereo.mp4 | hevc Main yuv420p 640x360 | aac 2ch | 探测否/实际可播 | remux：v copy + a copy | video:hevc, audio:aac | 8.0 | 376 | readyToPlay / rate=1 / 1.52s / vide:hvc1:enabled=true,soun:aac:enabled=true |
| 19_hevc10_hdr10_4k60.mp4 | hevc Main 10 yuv420p10le 3840x2160 | aac 6ch | 探测否/实际可播 | remux：v copy + a copy | video:hevc, audio:aac | 4.166667 | 194 | readyToPlay / rate=1 / 1.41s / vide:hvc1:enabled=true,soun:aac:enabled=true |
| 20_hevc_aac_stereo_hvc1.mp4 | hevc Main yuv420p 640x360 | aac 2ch | 是 | AVPlayer 直读（无 ffmpeg） | - | - | - | ready / rate=1 / 1.52s |
| 21_hevc10_hdr10_hvc1.mp4 | hevc Main 10 yuv420p10le 1920x1080 | aac 6ch | 是 | AVPlayer 直读（无 ffmpeg） | - | - | - | ready / rate=1 / 1.45s |

## 2. HDR / 杜比视界路径

| 文件 | 策略 | 输出尺寸 | 输出色彩 | 耗时 | 实时倍率 | AVPlayer |
| --- | --- | --- | --- | --- | --- | --- |
| 19_hevc10_hdr10_4k60.mp4 | 强制 HDR→SDR | 2560x1440 | bt709/bt709 | 7.13s | 0.84× | readyToPlay vide:avc1:enabled=true,soun:aac:enabled=true |
| 21_hevc10_hdr10_hvc1.mp4 | 强制 HDR→SDR | 1920x1080 | bt709/bt709 | 2.29s | 3.49× | readyToPlay vide:avc1:enabled=true,soun:aac:enabled=true |

## 3. 多音轨即时切换

16_h264_aac51_ac351.mkv：切到第 2 条音轨后 `selectedAudio=Japanese`，itemStatus=readyToPlay，itemTracks=['vide:avc1:enabled=true', 'soun:ac-3:enabled=true']，播放推进 1.42s。

## 4. 传输

| 方式 | 文件 | ffprobe | 远端 remux | 可靠 | 首片 | AVPlayer 直读 |
| --- | --- | --- | --- | --- | --- | --- |
| plain | 04_h264_ac3_51.mkv | True | True | True | 3 | - |
| plain | 06_h264_dts_51.mkv | True | True | True | 3 | - |
| plain | 01_h264_aac_stereo.mp4 | None | None | - | - | readyToPlay |
| plain | 18_hevc_aac_stereo.mp4 | None | None | - | - | readyToPlay |
| auth | 04_h264_ac3_51.mkv | True | True | True | 3 | - |
| auth | 06_h264_dts_51.mkv | True | True | True | 3 | - |
| auth | 01_h264_aac_stereo.mp4 | None | None | - | - | readyToPlay |
| auth | 18_hevc_aac_stereo.mp4 | None | None | - | - | readyToPlay |
| redirect | 04_h264_ac3_51.mkv | True | True | True | 3 | - |
| redirect | 06_h264_dts_51.mkv | True | True | True | 3 | - |
| redirect | 01_h264_aac_stereo.mp4 | None | None | - | - | readyToPlay |
| redirect | 18_hevc_aac_stereo.mp4 | None | None | - | - | readyToPlay |
| norange | 04_h264_ac3_51.mkv | True | True | False | 1 | - |
| norange | 06_h264_dts_51.mkv | True | True | False | 1 | - |
| norange | 01_h264_aac_stereo.mp4 | None | None | - | - | failed |
| norange | 18_hevc_aac_stereo.mp4 | None | None | - | - | failed |

## 5. AVPlayer 原生直读事实

| 文件 | isPlayable | itemStatus | 轨道 | 视频 codec | 音频 codec | videoRange | 起播 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 01_h264_aac_stereo.mp4 | True | readyToPlay | 2 | avc1 | aac | SDR | rate=1 1.44s |
| 02_h264_aac_51.mp4 | True | readyToPlay | 2 | avc1 | aac | SDR | rate=1 1.44s |
| 03_h264_ac3_51.mp4 | True | readyToPlay | 2 | avc1 | ac-3 | SDR | rate=1 1.44s |
| 04_h264_ac3_51.mkv | False | failed | 0 |  |  | None | rate=None 0s |
| 05_h264_eac3_51.mkv | False | failed | 0 |  |  | None | rate=None 0s |
| 06_h264_dts_51.mkv | False | failed | 0 |  |  | None | rate=None 0s |
| 07_hevc_mlp_51.mkv | False | failed | 0 |  |  | None | rate=None 0s |
| 08_hevc10_hdr10_flac_51.mkv | False | failed | 0 |  |  | None | rate=None 0s |
| 09_hevc10_hdr10_ac3_51.mkv | False | failed | 0 |  |  | None | rate=None 0s |
| 10_av1_opus_51.mkv | False | failed | 0 |  |  | None | rate=None 0s |
| 11_vp9_opus_51.webm | False | failed | 0 |  |  | None | rate=None 0s |
| 12_mpeg2_1080i_mp3.mkv | False | failed | 0 |  |  | None | rate=None 0s |
| 13_mpeg4_mp3.avi | False | failed | 0 |  |  | None | rate=None 0s |
| 14_prores_pcm.mov | True | readyToPlay | 2 | apch | lpcm | SDR | rate=1 1.5s |
| 15_h264_alac.mov | True | readyToPlay | 2 | avc1 | alac | SDR | rate=1 1.5s |
| 16_h264_aac51_ac351.mkv | False | failed | 0 |  |  | None | rate=None 0s |
| 17_h264_aac_stereo.ts | True | readyToPlay | 2 | avc1 | aac | SDR | rate=1 1.49s |
| 18_hevc_aac_stereo.mp4 | False | readyToPlay | 2 | hev1 | aac | SDR | rate=1 1.51s |
| 19_hevc10_hdr10_4k60.mp4 | False | readyToPlay | 2 | hev1 | aac | HDR10/PQ | rate=1 1.45s |
| 20_hevc_aac_stereo_hvc1.mp4 | True | readyToPlay | 2 | hvc1 | aac | SDR | rate=1 1.52s |
| 21_hevc10_hdr10_hvc1.mp4 | True | readyToPlay | 2 | hvc1 | aac | HDR10/PQ | rate=1 1.45s |
