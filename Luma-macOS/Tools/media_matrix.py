#!/usr/bin/env python3
"""Luma 视频 × 音轨组合测试矩阵。

生成一批可控样片（视频编码 / 容器 / 音轨编码 × 声道），用 ffprobe 与 AVPlayer
采集事实，再按 Luma 现有 StreamPlanner 参数跑 remux / transcode HLS，验证输出
是否真的可播、音轨是否还在。最后用本地 / Range HTTP(WebDAV) / 302 签名(网盘)
三种传输方式对比。

产物默认写到 ~/Movies/LumaTestMedia（不放进仓库）：
  media/      样片
  hls/        每个组合的 HLS 输出
  reports/    facts.json / hls.json / transport.json / summary.md

用法：
  ./Tools/media_matrix.py generate
  ./Tools/media_matrix.py probe
  ./Tools/media_matrix.py avplayer
  ./Tools/media_matrix.py hls
  ./Tools/media_matrix.py transport
  ./Tools/media_matrix.py all

只依赖 Python 标准库 + 仓库内置 ffmpeg/ffprobe + swiftc。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FFMPEG = ROOT / "Vendor/ffmpeg-dv/bin/ffmpeg"
FFPROBE = ROOT / "Vendor/ffmpeg-dv/bin/ffprobe"
STATIC_FFMPEG = ROOT / "Vendor/ffmpeg/ffmpeg"
OUT = Path.home() / "Movies/LumaTestMedia"
MEDIA = OUT / "media"
HLS = OUT / "hls"
REPORTS = OUT / "reports"
PROBE_BIN = OUT / "bin/avprobe"
PROBE_SRC = ROOT / "Tools/avplayer_probe.swift"

COPYABLE_AUDIO = {"aac", "alac", "ac3", "eac3"}

# ---------------------------------------------------------------------------
# 样片定义
# ---------------------------------------------------------------------------

H264 = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
        "-pix_fmt", "yuv420p", "-g", "50"]
HEVC8 = ["-c:v", "libx265", "-preset", "veryfast", "-crf", "26",
         "-pix_fmt", "yuv420p", "-x265-params", "log-level=error"]
HEVC10_HDR = [
    "-c:v", "libx265", "-preset", "veryfast", "-crf", "26",
    "-pix_fmt", "yuv420p10le",
    "-x265-params",
    "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
    ":master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
    ":max-cll=1000,400",
    "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
]
HEVC10_HDR_4K60 = [
    "-c:v", "libx265", "-preset", "ultrafast", "-crf", "30",
    "-pix_fmt", "yuv420p10le",
    "-x265-params",
    "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
    ":master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
    ":max-cll=1000,400",
    "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
]

CASES: list[dict] = [
    dict(file="01_h264_aac_stereo.mp4", video=H264,
         audio=["-c:a", "aac", "-b:a", "128k", "-ac", "2"],
         mux=["-f", "mp4", "-movflags", "+faststart"],
         note="最通用基线：H.264 8bit + AAC 立体声"),
    dict(file="02_h264_aac_51.mp4", video=H264,
         audio=["-c:a", "aac", "-b:a", "384k", "-ac", "6"],
         mux=["-f", "mp4", "-movflags", "+faststart"],
         note="MP4 多声道 AAC 5.1"),
    dict(file="03_h264_ac3_51.mp4", video=H264,
         audio=["-c:a", "ac3", "-b:a", "640k", "-ac", "6", "-strict", "-2"],
         mux=["-f", "mp4", "-movflags", "+faststart"],
         note="MP4 + AC-3 5.1（蓝光常见，验证 AVPlayer 原生直读）"),
    dict(file="04_h264_ac3_51.mkv", video=H264,
         audio=["-c:a", "ac3", "-b:a", "640k", "-ac", "6"],
         mux=["-f", "matroska"],
         note="MKV + AC-3 5.1（remux 音频直通候选）"),
    dict(file="05_h264_eac3_51.mkv", video=H264,
         audio=["-c:a", "eac3", "-b:a", "640k", "-ac", "6"],
         mux=["-f", "matroska"],
         note="MKV + E-AC-3 5.1（直通候选）"),
    dict(file="06_h264_dts_51.mkv", video=H264,
         audio=["-c:a", "dca", "-strict", "-2", "-b:a", "768k", "-ac", "6"],
         mux=["-f", "matroska"],
         note="MKV + DTS 5.1（必须重编码音频）"),
    dict(file="07_hevc_mlp_51.mkv", video=HEVC8,
         audio=["-c:a", "mlp", "-strict", "-2", "-ac", "6"],
         mux=["-f", "matroska"],
         note="MKV + TrueHD 家族（MLP）5.1，验证 AC-3 降级策略"),
    dict(file="08_hevc10_hdr10_flac_51.mkv", video=HEVC10_HDR,
         audio=["-c:a", "flac", "-ac", "6"],
         mux=["-f", "matroska"],
         note="HEVC 10bit HDR10 + FLAC 5.1（HDR + 音频重编码）"),
    dict(file="09_hevc10_hdr10_ac3_51.mkv", video=HEVC10_HDR,
         audio=["-c:a", "ac3", "-b:a", "640k", "-ac", "6"],
         mux=["-f", "matroska"],
         note="HEVC 10bit HDR10 + AC-3 5.1（HDR + 音频直通）"),
    dict(file="10_av1_opus_51.mkv", video=["-c:v", "libsvtav1", "-preset", "10",
                                           "-crf", "40", "-pix_fmt", "yuv420p"],
         audio=["-c:a", "libopus", "-b:a", "384k", "-ac", "6"],
         mux=["-f", "matroska"],
         note="AV1 + Opus 5.1（AV1 是否可 remux 由实测决定）"),
    dict(file="11_vp9_opus_51.webm", video=["-c:v", "libvpx-vp9", "-deadline", "realtime",
                                            "-cpu-used", "8", "-crf", "40", "-b:v", "0",
                                            "-row-mt", "1", "-pix_fmt", "yuv420p"],
         audio=["-c:a", "libopus", "-b:a", "384k", "-ac", "6"],
         mux=["-f", "webm"],
         note="VP9 + Opus 5.1 WebM"),
    dict(file="12_mpeg2_1080i_mp3.mkv", video=["-c:v", "mpeg2video", "-b:v", "12M",
                                               "-flags", "+ilme+ildct",
                                               "-field_order", "tt"],
         size="1920x1080", audio=["-c:a", "libmp3lame", "-b:a", "192k", "-ac", "2"],
         mux=["-f", "matroska"],
         note="MPEG-2 1080i 隔行 + MP3（去隔行能力）"),
    dict(file="13_mpeg4_mp3.avi", video=["-c:v", "mpeg4", "-qscale:v", "4"],
         audio=["-c:a", "libmp3lame", "-b:a", "192k", "-ac", "2"],
         mux=["-f", "avi"],
         note="MPEG-4 Part 2 + MP3 AVI（老片库）"),
    dict(file="14_prores_pcm.mov", video=["-c:v", "prores_ks", "-profile:v", "3",
                                          "-pix_fmt", "yuv422p10le"],
         audio=["-c:a", "pcm_s16le", "-ac", "2"],
         mux=["-f", "mov"],
         note="ProRes 422 HQ + PCM（剪辑母版）"),
    dict(file="15_h264_alac.mov", video=H264,
         audio=["-c:a", "alac", "-ac", "2"],
         mux=["-f", "mov"],
         note="MOV + ALAC（Apple 无损）"),
    dict(file="16_h264_aac51_ac351.mkv", video=H264, dual_audio=True,
         tones=[440, 880], mux=["-f", "matroska"],
         note="双音轨：AAC 5.1(eng) + AC-3 5.1(jpn)，验证多音轨 master"),
    dict(file="17_h264_aac_stereo.ts", video=H264,
         audio=["-c:a", "aac", "-b:a", "128k", "-ac", "2"],
         mux=["-f", "mpegts"],
         note="MPEG-TS + AAC（直播录制）"),
    dict(file="18_hevc_aac_stereo.mp4", video=HEVC8,
         audio=["-c:a", "aac", "-b:a", "128k", "-ac", "2"],
         mux=["-f", "mp4", "-movflags", "+faststart"],
         note="HEVC 8bit MP4（hvc1 标签与原生直读）"),
    dict(file="19_hevc10_hdr10_4k60.mp4", video=HEVC10_HDR_4K60, size="3840x2160",
         fps=60, dur=6, audio=["-c:a", "aac", "-b:a", "384k", "-ac", "6"],
         mux=["-f", "mp4", "-movflags", "+faststart"],
         note="4K60 HDR10 HEVC（像素率降档 + libplacebo 映射）"),
    dict(file="20_hevc_aac_stereo_hvc1.mp4", video=HEVC8,
         audio=["-c:a", "aac", "-b:a", "128k", "-ac", "2"],
         mux=["-f", "mp4", "-movflags", "+faststart", "-tag:v", "hvc1"],
         note="HEVC MP4（hvc1 标签）：验证 isPlayable 与 hev1 的差异"),
    dict(file="21_hevc10_hdr10_hvc1.mp4", video=HEVC10_HDR, size="1920x1080",
         audio=["-c:a", "aac", "-b:a", "384k", "-ac", "6"],
         mux=["-f", "mp4", "-movflags", "+faststart", "-tag:v", "hvc1"],
         note="1080p HDR10 HEVC hvc1：验证原生 HDR 直读"),
]


def log(message: str) -> None:
    print(message, flush=True)


def run(cmd: list[str], timeout: float = 900,
        env: dict | None = None) -> tuple[int, str, str, float]:
    started = time.time()
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, env=env)
    return (proc.returncode,
            proc.stdout.decode("utf-8", "replace"),
            proc.stderr.decode("utf-8", "replace"),
            time.time() - started)


# ---------------------------------------------------------------------------
# 1. 生成
# ---------------------------------------------------------------------------

def generate(force: bool = False) -> None:
    MEDIA.mkdir(parents=True, exist_ok=True)
    for case in CASES:
        target = MEDIA / case["file"]
        if target.exists() and not force:
            log(f"跳过（已存在） {case['file']}")
            continue
        width, height = (case.get("size") or "640x360").split("x")
        fps = case.get("fps", 25)
        duration = case.get("dur", 8)
        cmd = [str(FFMPEG), "-y", "-v", "error",
               "-f", "lavfi", "-i",
               f"testsrc2=size={width}x{height}:rate={fps}:duration={duration}"]
        tones = case.get("tones", [440])
        for tone in tones:
            cmd += ["-f", "lavfi", "-i",
                    f"sine=frequency={tone}:sample_rate=48000:duration={duration}"]
        if case.get("dual_audio"):
            cmd += ["-map", "0:v:0", *case["video"]]
            cmd += ["-map", "1:a:0", "-c:a:0", "aac", "-b:a:0", "384k", "-ac:a:0", "6",
                    "-metadata:s:a:0", "language=eng",
                    "-metadata:s:a:0", "title=English AAC 5.1"]
            cmd += ["-map", "2:a:0", "-c:a:1", "ac3", "-b:a:1", "640k", "-ac:a:1", "6",
                    "-metadata:s:a:1", "language=jpn",
                    "-metadata:s:a:1", "title=Japanese AC-3 5.1"]
        else:
            cmd += ["-map", "0:v:0", *case["video"]]
            cmd += ["-map", "1:a:0", *case["audio"]]
        cmd += case["mux"] + ["-shortest", str(target)]
        log(f"生成 {case['file']} …")
        code, _, err, elapsed = run(cmd)
        if code != 0:
            log(f"  失败（{elapsed:.1f}s）：{err.strip()[:400]}")
        else:
            size_mb = target.stat().st_size / 1024 / 1024
            log(f"  完成 {size_mb:.1f} MB / {elapsed:.1f}s")


# ---------------------------------------------------------------------------
# 2. ffprobe
# ---------------------------------------------------------------------------

def ffprobe_json(path: str | Path) -> dict:
    cmd = [str(FFPROBE), "-v", "error", "-show_streams", "-show_format", "-of", "json",
           str(path)]
    code, out, err, _ = run(cmd, timeout=120)
    if code != 0:
        return {"error": err.strip()}
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"error": "invalid json"}


def probe_all() -> dict:
    reports = {"files": {}, "avplayer": None}
    for case in CASES:
        path = MEDIA / case["file"]
        if not path.exists():
            continue
        report = ffprobe_json(path)
        video = next((s for s in report.get("streams", [])
                      if s.get("codec_type") == "video"), {})
        audios = [s for s in report.get("streams", [])
                  if s.get("codec_type") == "audio"]
        subs = [s for s in report.get("streams", [])
                if s.get("codec_type") == "subtitle"]
        report["summary"] = {
            "file": case["file"],
            "note": case["note"],
            "container": report.get("format", {}).get("format_name"),
            "duration": float(report.get("format", {}).get("duration") or 0),
            "size_mb": round(path.stat().st_size / 1024 / 1024, 2),
            "video": {
                "codec": video.get("codec_name"),
                "profile": video.get("profile"),
                "pix_fmt": video.get("pix_fmt"),
                "size": f"{video.get('width')}x{video.get('height')}",
                "fps": video.get("avg_frame_rate"),
                "primaries": video.get("color_primaries"),
                "transfer": video.get("color_transfer"),
                "matrix": video.get("color_space"),
                "range": video.get("color_range"),
                "codec_tag": video.get("codec_tag_string"),
                "field_order": video.get("field_order"),
                "bitrate": int(video.get("bit_rate") or 0),
            },
            "audio": [{
                "codec": a.get("codec_name"),
                "profile": a.get("profile"),
                "channels": a.get("channels"),
                "layout": a.get("channel_layout"),
                "sample_rate": int(a.get("sample_rate") or 0),
                "bitrate": int(a.get("bit_rate") or 0),
                "language": (a.get("tags") or {}).get("language"),
                "title": (a.get("tags") or {}).get("title"),
                "default": (a.get("disposition") or {}).get("default"),
            } for a in audios],
            "subtitle_count": len(subs),
            "format_bitrate": int(report.get("format", {}).get("bit_rate") or 0),
        }
        reports["files"][case["file"]] = report["summary"]
    REPORTS.mkdir(parents=True, exist_ok=True)
    (REPORTS / "facts.json").write_text(json.dumps(reports, ensure_ascii=False, indent=2))
    log(f"ffprobe 完成：{len(reports['files'])} 个文件 → {REPORTS/'facts.json'}")
    return reports


# ---------------------------------------------------------------------------
# 3. AVPlayer 探测
# ---------------------------------------------------------------------------

def build_probe_binary() -> None:
    if PROBE_BIN.exists() and PROBE_BIN.stat().st_mtime > PROBE_SRC.stat().st_mtime:
        return
    PROBE_BIN.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["swiftc", "-O", "-parse-as-library", str(PROBE_SRC), "-o", str(PROBE_BIN)]
    log("编译 avplayer_probe.swift …")
    code, _, err, _ = run(cmd, timeout=300)
    if code != 0:
        raise SystemExit(f"avprobe 编译失败：{err[:800]}")


def avprobe(inputs: list[str], headers: dict | None = None,
            audio_index: int | None = None) -> list[dict]:
    build_probe_binary()
    if not inputs:
        return []
    env = os.environ.copy()
    if headers:
        env["AVPROBE_HEADERS"] = json.dumps(headers)
    if audio_index is not None:
        env["AVPROBE_AUDIO_INDEX"] = str(audio_index)
    code, out, err, elapsed = run([str(PROBE_BIN), *inputs],
                                  timeout=120 + 20 * len(inputs), env=env)
    if code != 0:
        log(f"avprobe 失败：{err[:400]}")
        return []
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        log(f"avprobe 输出无法解析：{out[:400]}")
        return []
    for item in data:
        item["wallSeconds"] = round(elapsed, 2)
    return data


def probe_avplayer() -> dict:
    paths = [str(MEDIA / c["file"]) for c in CASES if (MEDIA / c["file"]).exists()]
    results = avprobe(paths)
    facts = json.loads((REPORTS / "facts.json").read_text()) if (REPORTS / "facts.json").exists() else {"files": {}}
    facts["avplayer"] = {Path(r["input"]).name: r for r in results}
    (REPORTS / "facts.json").write_text(json.dumps(facts, ensure_ascii=False, indent=2))
    for r in results:
        audio_opts = len([o for o in r.get("audioOptions", [])])
        log(f"AVPlayer {Path(r['input']).name}: playable={r.get('isPlayable')} "
            f"status={r.get('itemStatus')} tracks={len(r.get('tracks', []))} "
            f"audioOptions={audio_opts} range={r.get('videoRange')}")
    return facts


# ---------------------------------------------------------------------------
# 4. 播放计划 + HLS 验证
# ---------------------------------------------------------------------------

def transcode_profile(width: int, height: int, fps: float) -> dict:
    steps = [2160, 1600, 1440, 1200, 1080, 720]
    ceiling = 250_000_000.0
    if width <= 0 or height <= 0:
        return {"height": 1080, "width": None, "bitrate": 8_000_000}
    fps = fps if fps > 0 else 30
    if width * height * fps <= ceiling:
        chosen = height
    else:
        chosen = steps[-1]
        for candidate in steps:
            if candidate >= height:
                continue
            scaled_w = max(2, int(round(width * candidate / height)) & ~1)
            if scaled_w * candidate * fps <= ceiling:
                chosen = candidate
                break
    out_h = min(chosen, height)
    if out_h >= 2000:
        bitrate = 20_000_000
    elif out_h >= 1400:
        bitrate = 12_000_000
    elif out_h >= 1000:
        bitrate = 8_000_000
    else:
        bitrate = 5_000_000
    if out_h >= height:
        return {"height": height, "width": None, "bitrate": bitrate}
    out_w = max(2, int(round(width * out_h / height)) & ~1)
    return {"height": out_h, "width": out_w, "bitrate": bitrate}


def parse_fps(value: str | None) -> float:
    if not value or value in ("0/0", "N/A"):
        return 0
    if "/" in value:
        num, den = value.split("/", 1)
        try:
            return float(num) / float(den) if float(den) else 0
        except ValueError:
            return 0
    try:
        return float(value)
    except ValueError:
        return 0


def build_plan(facts: dict, native: dict | None, edr: float) -> dict:
    video = facts["video"]
    audios = facts.get("audio") or []
    audio = audios[0] if audios else {}
    codec = video.get("codec") or ""
    audio_codec = (audio.get("codec") or "").lower()
    channels = int(audio.get("channels") or 2)
    primaries = (video.get("primaries") or "").lower()
    transfer = (video.get("transfer") or "").lower()
    is_hdr = primaries == "bt2020" or transfer in ("smpte2084", "arib-std-b67")
    interlaced = (video.get("field_order") or "progressive") in ("tt", "bb", "tb", "bt")
    native_playable = bool(native and native.get("isPlayable")
                           and native.get("itemStatus") == "readyToPlay")
    tone_map = is_hdr and edr <= 1.0

    if native_playable and not tone_map:
        return {"path": "native", "mode": "native",
                "reason": "AVPlayer 可直接打开，无需 ffmpeg",
                "audio_copy": False, "multi_audio": False, "tone_map": False,
                "interlaced": interlaced}

    copies_video = codec in ("h264", "hevc") and not interlaced
    mode = "remux" if copies_video else "transcode"
    multi_audio = (mode == "remux" and not is_hdr and len(audios) > 1
                   and all((a.get("codec") or "").lower() in COPYABLE_AUDIO for a in audios))
    audio_copy = (mode == "remux" and audio_codec in COPYABLE_AUDIO)
    audio_encoder = None
    if not audio_copy:
        if audio_codec in ("dts", "dts-hd", "truehd", "mlp") and channels > 2:
            audio_encoder = "ac3"
        else:
            audio_encoder = "aac"
    return {"path": mode, "mode": mode, "audio_copy": audio_copy,
            "multi_audio": multi_audio, "tone_map": is_hdr and tone_map,
            "interlaced": interlaced, "audio_encoder": audio_encoder,
            "reason": "MKV/AVI/WebM 容器或非原生视频编码，需 ffmpeg"}


def hls_arguments(input_path: str, output_dir: Path, plan: dict, facts: dict) -> list[str]:
    video = facts["video"]
    audios = facts.get("audio") or []
    audio = audios[0] if audios else {}
    codec = (video.get("codec") or "").lower()
    color = {
        "primaries": video.get("primaries"),
        "transfer": video.get("transfer"),
        "matrix": video.get("matrix"),
        "range": video.get("range"),
    }
    args = ["-y", "-v", "error", "-probesize", "2M", "-analyzeduration", "2M",
            "-readrate", "12", "-i", input_path]
    if plan["mode"] == "remux":
        args += ["-map", "0:v:0", "-c:v", "copy"]
        if codec == "hevc":
            args += ["-tag:v", "hvc1"]
        for key, option in (("primaries", "-color_primaries"),
                            ("transfer", "-color_trc"),
                            ("matrix", "-colorspace"),
                            ("range", "-color_range")):
            value = color.get(key)
            if value and value.lower() not in ("unknown", "reserved"):
                args += [option, value]
        if plan["multi_audio"]:
            for index, _ in enumerate(audios):
                args += ["-map", f"0:a:{index}"]
            args += ["-c:a", "copy"]
            for index, item in enumerate(audios):
                language = (item.get("language") or "").lower()
                if language and language != "und":
                    args += [f"-metadata:s:a:{index}", f"language={language}"]
        elif plan["audio_copy"]:
            args += ["-c:a", "copy"]
        else:
            args += encode_audio_args(plan, audio)
    else:
        width = int(video.get("size", "0x0").split("x")[0])
        height = int(video.get("size", "0x0").split("x")[1])
        fps = parse_fps(video.get("fps"))
        profile = transcode_profile(width, height, fps)
        args += ["-map", "0:v:0",
                 "-c:v", "h264_videotoolbox",
                 "-b:v", str(profile["bitrate"]),
                 "-maxrate", str(int(profile["bitrate"] * 1.35)),
                 "-bufsize", str(profile["bitrate"] * 2),
                 "-allow_sw", "1", "-pix_fmt", "yuv420p",
                 "-force_key_frames", "expr:gte(t,n_forced*2)"]
        filters: list[str] = []
        if plan["interlaced"]:
            filters.append("bwdif=mode=send_frame:parity=auto:deint=all")
        if plan["tone_map"]:
            size = ""
            if profile["width"]:
                size = f"w={profile['width']}:h={profile['height']}:"
            filters.append(
                f"setparams=color_primaries={color['primaries'] or 'bt2020'}"
                f":color_trc={color['transfer'] or 'smpte2084'}"
                f":colorspace={color['matrix'] or 'bt2020nc'},"
                f"libplacebo={size}apply_dolbyvision=1:tonemapping=bt.2390"
                f":colorspace=bt709:color_primaries=bt709:color_trc=bt709:format=yuv420p")
        elif profile["width"]:
            filters.append(f"scale=-2:{profile['height']}")
        if filters:
            args += ["-vf", ",".join(filters)]
        if plan["tone_map"]:
            args += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        args += encode_audio_args(plan, audio)
    if not plan["multi_audio"]:
        args += ["-map", "0:a:0?"]
    args += ["-max_muxing_queue_size", "2048",
             "-f", "hls", "-hls_time", "2", "-hls_init_time", "0.5",
             "-hls_list_size", "0", "-hls_playlist_type", "event",
             "-hls_flags", "temp_file", "-hls_segment_type", "fmp4"]
    if plan["multi_audio"]:
        args += ["-hls_fmp4_init_filename", "init_%v.mp4",
                 "-hls_segment_filename", str(output_dir / "seg_%v_%05d.m4s"),
                 "-var_stream_map", var_stream_map(audios),
                 "-master_pl_name", "master.m3u8",
                 str(output_dir / "live_%v.m3u8")]
    else:
        args += ["-hls_fmp4_init_filename", "init.mp4",
                 "-hls_segment_filename", str(output_dir / "seg%05d.m4s"),
                 str(output_dir / "live.m3u8")]
    return args


def var_stream_map(audios: list[dict]) -> str:
    parts = ["v:0,agroup:aud"]
    for index, item in enumerate(audios):
        entry = f"a:{index},agroup:aud"
        if index == 0:
            entry += ",default:yes"
        language = (item.get("language") or "").lower()
        if language and language != "und":
            # LANGUAGE 才会写进 master；AVPlayer 菜单据此显示 English / Japanese。
            entry += f",language:{language},name:{language}-{index + 1}"
        parts.append(entry)
    return " ".join(parts)


def encode_audio_args(plan: dict, audio: dict) -> list[str]:
    channels = int(audio.get("channels") or 2)
    if plan.get("audio_encoder") == "ac3":
        return ["-async", "1", "-c:a", "ac3", "-b:a", "640k", "-ac", "6"]
    return ["-async", "1", "-c:a", "aac", "-b:a",
            "384k" if channels > 2 else "256k"]


def hls_verify(output_dir: Path, multi_audio: bool) -> dict:
    result: dict = {"exists": False, "variants": [], "streams": []}
    if multi_audio:
        master = output_dir / "master.m3u8"
        result["master_exists"] = master.exists()
        result["entry"] = str(master)
        if master.exists():
            master_text = master.read_text(errors="replace")
            result["audio_renditions"] = master_text.count("#EXT-X-MEDIA:TYPE=AUDIO")
        playlists = sorted(output_dir.glob("live_*.m3u8"))
        result["variants"] = [p.name for p in playlists]
        if not playlists:
            return result
        entry = playlists[0]
    else:
        entry = output_dir / "live.m3u8"
        result["entry"] = str(entry)
    result["exists"] = entry.exists()
    if not entry.exists():
        return result
    playlist = entry.read_text(errors="replace")
    result["segments"] = playlist.count("#EXTINF")
    durations = [float(line.split(":")[1].split(",")[0])
                 for line in playlist.splitlines() if line.startswith("#EXTINF")]
    result["duration"] = round(sum(durations), 2)
    result["first_segment_seconds"] = durations[0] if durations else None
    result["variant"] = "master" if multi_audio else "media"

    probes = [entry] + ([output_dir / name for name in result["variants"][1:]]
                        if multi_audio else [])
    seen = set()
    for probe_path in probes:
        probe = ffprobe_json(probe_path)
        for stream in probe.get("streams", []):
            key = (stream.get("codec_type"), stream.get("codec_name"),
                   (stream.get("tags") or {}).get("language"))
            if key in seen:
                continue
            seen.add(key)
            result["streams"].append({
                "type": stream.get("codec_type"),
                "codec": stream.get("codec_name"),
                "channels": stream.get("channels"),
                "language": (stream.get("tags") or {}).get("language"),
            })

    # 第一片里的音视频包数：验证「有画面没声音」不会发生。
    if multi_audio:
        # 多音轨时视频 variant 里没有音频：音频在各自的 media playlist 里。
        first = output_dir / "seg_0_00000.m4s"
        init = output_dir / "init_0.mp4"
        audio_init = audio_first = None
        audio_playlist = playlists[1] if len(playlists) > 1 else None
        if audio_playlist:
            for line in audio_playlist.read_text(errors="replace").splitlines():
                if line.startswith("#EXT-X-MAP:URI="):
                    audio_init = output_dir / line.split('"')[1]
                elif line and not line.startswith("#"):
                    audio_first = output_dir / line
                    break
        if audio_init and audio_first and audio_init.exists() and audio_first.exists():
            merged_audio = output_dir / "first_audio_segment.mp4"
            merged_audio.write_bytes(audio_init.read_bytes() + audio_first.read_bytes())
            result["first_segment_audio_packets"] = packet_count(merged_audio, "a:0")
            result["first_segment_audio_codec"] = next(
                (s["codec"] for s in result["streams"] if s["type"] == "audio"), None)
    else:
        first = output_dir / "seg00000.m4s"
        init = output_dir / "init.mp4"
    if first.exists() and init.exists():
        merged = output_dir / "first_segment.mp4"
        merged.write_bytes(init.read_bytes() + first.read_bytes())
        if not multi_audio:
            result["first_segment_audio_packets"] = packet_count(merged, "a:0")
        result["first_segment_video_packets"] = packet_count(merged, "v:0")
    return result


def packet_count(path: Path, specifier: str) -> int:
    cmd = [str(FFPROBE), "-v", "error", "-select_streams", specifier,
           "-count_packets", "-show_entries", "stream=nb_read_packets",
           "-of", "csv=p=0", str(path)]
    _, out, _, _ = run(cmd, timeout=60)
    try:
        # csv=p=0 对多字段流会带尾随逗号（例如 "61,"），只取第一段。
        token = out.strip().splitlines()[0].split(",")[0].strip()
        return int(token)
    except (ValueError, IndexError):
        return 0


def forced_tonemap(name: str, summary: dict, plan: dict) -> dict | None:
    """HDR 片源额外跑一次强制映射：自动策略在 HDR 屏会保留原样，
    但 SDR 屏路径必须验证 libplacebo 链、降档尺寸与输出色彩标签。"""
    video = summary["video"]
    is_hdr = ((video.get("primaries") or "").lower() == "bt2020"
              or (video.get("transfer") or "").lower() in ("smpte2084", "arib-std-b67"))
    if not is_hdr:
        return None
    plan_tm = dict(plan)
    plan_tm.update({"mode": "transcode", "path": "transcode",
                    "audio_copy": False, "multi_audio": False,
                    "audio_encoder": None, "tone_map": True, "interlaced": False})
    output_tm = HLS / f"{Path(name).stem}_tonemap"
    if output_tm.exists():
        shutil.rmtree(output_tm)
    output_tm.mkdir(parents=True)
    args_tm = hls_arguments(str(MEDIA / name), output_tm, plan_tm, summary)
    log(f"{name}: 强制 HDR→SDR 映射验证 …")
    code_tm, _, err_tm, elapsed_tm = run([str(FFMPEG), *args_tm])
    verify_tm = hls_verify(output_tm, False)
    color = {}
    entry_probe = ffprobe_json(output_tm / "live.m3u8") if verify_tm.get("exists") else {}
    for stream in entry_probe.get("streams", []):
        if stream.get("codec_type") == "video":
            color = {
                "primaries": stream.get("color_primaries"),
                "transfer": stream.get("color_transfer"),
                "matrix": stream.get("color_space"),
                "size": f"{stream.get('width')}x{stream.get('height')}",
            }
    log(f"  映射完成 {elapsed_tm:.1f}s → {color.get('size')} "
        f"{color.get('primaries')}/{color.get('transfer')}")
    return {"exit": code_tm, "seconds": round(elapsed_tm, 2),
            "stderr": err_tm.strip()[:400], "verify": verify_tm, "color": color}


def run_hls(facts: dict) -> dict:
    hls_reports = {"cases": {}}
    edr = 16.0
    if facts.get("avplayer"):
        sample = next(iter(facts["avplayer"].values()), {})
        edr = float(sample.get("displayPotentialEDR") or 16.0)
    HLS.mkdir(parents=True, exist_ok=True)
    for case in CASES:
        name = case["file"]
        summary = facts["files"].get(name)
        if not summary:
            continue
        native = (facts.get("avplayer") or {}).get(name)
        plan = build_plan(summary, native, edr)
        record = {"plan": plan}
        if plan["path"] == "native":
            log(f"{name}: 原生直读，跳过 ffmpeg")
            tonemap = forced_tonemap(name, summary, plan)
            if tonemap:
                record["tonemap"] = tonemap
            hls_reports["cases"][name] = record
            continue
        output_dir = HLS / f"{Path(name).stem}_{plan['mode']}"
        if output_dir.exists():
            shutil.rmtree(output_dir)
        output_dir.mkdir(parents=True)
        args = hls_arguments(str(MEDIA / name), output_dir, plan, summary)
        log(f"{name}: {plan['mode']} 生成中 …")
        code, _, err, elapsed = run([str(FFMPEG), *args])
        record.update({"exit": code, "seconds": round(elapsed, 2),
                       "stderr": err.strip()[:600]})
        verify = hls_verify(output_dir, plan["multi_audio"])
        record["verify"] = verify
        # 失败时按 App 的兜底逻辑改成重编码再跑一次。
        if code != 0 or not verify.get("exists"):
            log(f"  remux 失败，降级 transcode：{err.strip()[:200]}")
            plan2 = dict(plan)
            plan2.update({"mode": "transcode", "path": "transcode",
                          "audio_copy": False, "multi_audio": False,
                          "audio_encoder": None})
            output_dir2 = HLS / f"{Path(name).stem}_transcode"
            if output_dir2.exists():
                shutil.rmtree(output_dir2)
            output_dir2.mkdir(parents=True)
            args2 = hls_arguments(str(MEDIA / name), output_dir2, plan2, summary)
            code2, _, err2, elapsed2 = run([str(FFMPEG), *args2])
            record["fallback"] = {
                "exit": code2, "seconds": round(elapsed2, 2),
                "stderr": err2.strip()[:600],
                "verify": hls_verify(output_dir2, False),
            }
            record["effective"] = "transcode"
        else:
            record["effective"] = plan["mode"]
        tonemap = forced_tonemap(name, summary, plan)
        if tonemap:
            record["tonemap"] = tonemap
        hls_reports["cases"][name] = record
        log(f"  完成 {record['seconds']}s / {record['effective']}")
    probe_hls_playability(hls_reports)
    (REPORTS / "hls.json").write_text(json.dumps(hls_reports, ensure_ascii=False, indent=2))
    return hls_reports


def probe_hls_playability(hls_reports: dict) -> None:
    """把生成的 HLS 用本机 HTTP 服务起来，交给 AVPlayer 真正起播一次。
    这一步回答的是「参数产出能不能播、音轨菜单在不在」，不是只有 ffmpeg 退出码。"""
    server = start_server(HLS, "plain")
    requests: list[tuple[str, str, str]] = []
    try:
        for name, record in (hls_reports.get("cases") or {}).items():
            plan = record.get("plan") or {}
            stem = Path(name).stem
            jobs = []
            if record.get("effective") in ("remux", "transcode"):
                jobs.append((f"{stem}_{record['effective']}", "main"))
            if record.get("fallback"):
                jobs.append((f"{stem}_transcode", "fallback"))
            if record.get("tonemap"):
                jobs.append((f"{stem}_tonemap", "tonemap"))
            for directory, kind in jobs:
                multi = bool(plan.get("multi_audio")) and kind == "main"
                entry = "master.m3u8" if multi else "live.m3u8"
                path = HLS / directory / entry
                if not path.exists():
                    continue
                url = f"{server.base}/{directory}/{entry}"
                requests.append((url, name, kind))
        results = avprobe([url for url, _, _ in requests])
        by_url = {item["input"]: item for item in results}
        for url, name, kind in requests:
            item = by_url.get(url)
            if not item:
                continue
            record = hls_reports["cases"][name]
            plan = record.get("plan") or {}
            payload = {
                "isPlayable": item.get("isPlayable"),
                "itemStatus": item.get("itemStatus"),
                "itemError": item.get("itemError"),
                "audioOptions": [option.get("displayName")
                                 for option in item.get("audioOptions", [])],
                "itemTracks": item.get("itemTracks") or [],
                "videoRange": item.get("videoRange"),
                "tracks": [{"type": track.get("type"),
                            "codecs": track.get("codecs"),
                            "channels": track.get("channels"),
                            "decodable": track.get("decodable")}
                           for track in item.get("tracks", [])],
                "playedRate": item.get("playedRate"),
                "playedSeconds": item.get("playedSeconds"),
                "presentationSize": item.get("presentationSize"),
            }
            if kind == "main":
                record["avplayer"] = payload
                # 多音轨 master：切到第二条音轨再起播，验证「不重启 ffmpeg 的即时换轨」。
                if plan.get("multi_audio"):
                    switched = avprobe([url], audio_index=1)
                    if switched:
                        item2 = switched[0]
                        record["audioSwitch"] = {
                            "selectedAudio": item2.get("selectedAudio"),
                            "itemStatus": item2.get("itemStatus"),
                            "playedRate": item2.get("playedRate"),
                            "playedSeconds": item2.get("playedSeconds"),
                            "itemTracks": item2.get("itemTracks") or [],
                            "audioOptions": [option.get("displayName")
                                             for option in item2.get("audioOptions", [])],
                        }
                        log(f"AVPlayer 切轨 {name}: {item2.get('selectedAudio')} "
                            f"status={item2.get('itemStatus')} "
                            f"tracks={item2.get('itemTracks')}")
            elif kind == "tonemap":
                record.setdefault("tonemap", {})["avplayer"] = payload
            else:
                record.setdefault("fallback", {})["avplayer"] = payload
            log(f"AVPlayer HLS {url.rsplit('/', 2)[-2]}: status={payload['itemStatus']} "
                f"audioOptions={len(payload['audioOptions'])} "
                f"itemTracks={payload['itemTracks']} rate={payload['playedRate']} "
                f"sec={payload['playedSeconds']}")
    finally:
        server.shutdown()
        server.server_close()


# ---------------------------------------------------------------------------
# 5. 传输：本地 / Range HTTP(WebDAV) / 302 签名(网盘)
# ---------------------------------------------------------------------------

class FileServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, root: Path, mode: str, latency_ms: int = 0,
                 throughput_mbps: float = 0):
        self.root = root
        self.mode = mode
        self.latency_ms = latency_ms
        self.throughput = throughput_mbps * 1024 * 1024 / 8
        super().__init__(("127.0.0.1", 0), FileHandler)
        self.token = "signed-token-2026"

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.server_address[1]}"


class FileHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # 静默
        pass

    def handle(self) -> None:
        # 播放器会主动掐断连接（拖动 / 换片），不要让服务线程刷 traceback。
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            pass

    @property
    def server_ref(self) -> FileServer:
        return self.server  # type: ignore[return-value]

    def _throttle(self, payload: bytes) -> None:
        server = self.server_ref
        if server.latency_ms:
            time.sleep(server.latency_ms / 1000)
        if server.throughput:
            time.sleep(len(payload) / server.throughput)
        self.wfile.write(payload)

    def _resolve(self, target: str) -> Path:
        parsed = urllib.parse.urlparse(target)
        query = urllib.parse.parse_qs(parsed.query)
        name = query.get("file", [parsed.path])[0]
        name = name.lstrip("/").replace("files/", "", 1)
        return self.server_ref.root / name

    def _auth_ok(self) -> bool:
        server = self.server_ref
        if server.mode == "auth":
            expected = "Basic " + base64.b64encode(b"user:pass").decode()
            if self.headers.get("Authorization") != expected:
                return False
            if "pan.example.com" not in (self.headers.get("Referer") or ""):
                return False
        if server.mode == "redirect":
            parsed = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(parsed.query)
            if query.get("sig", [""])[0] != server.token:
                return False
        return True

    def _send_redirect(self) -> None:
        server = self.server_ref
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        name = query.get("file", [parsed.path])[0].lstrip("/").replace("files/", "", 1)
        location = f"/files/{urllib.parse.quote(name)}?sig={server.token}"
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_PROPFIND(self) -> None:
        if not self._auth_ok():
            self._unauthorized()
            return
        body = ("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">"
                f"<d:response><d:href>{self.path}</d:href></d:response>"
                "</d:multistatus>").encode()
        self.send_response(207)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _unauthorized(self) -> None:
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="luma-test"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self) -> None:
        self._serve(head_only=True)

    def do_GET(self) -> None:
        server = self.server_ref
        if server.mode == "redirect" and "sig=" not in self.path:
            self._send_redirect()
            return
        if not self._auth_ok():
            self._unauthorized()
            return
        self._serve(head_only=False)

    def _serve(self, head_only: bool) -> None:
        server = self.server_ref
        path = self._resolve(self.path)
        if not path.exists() or not path.is_file():
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        total = path.stat().st_size
        content_type = {
            ".mp4": "video/mp4", ".m4s": "video/iso.segment", ".mkv": "video/x-matroska",
            ".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t",
            ".mov": "video/quicktime", ".webm": "video/webm", ".avi": "video/x-msvideo",
        }.get(path.suffix.lower(), "application/octet-stream")
        start, end = 0, total - 1
        status = 200
        range_header = self.headers.get("Range")
        if range_header and server.mode != "norange":
            try:
                unit, _, spec = range_header.partition("=")
                if unit.strip().lower() == "bytes":
                    first, _, last = spec.partition("-")
                    start = int(first) if first else 0
                    end = int(last) if last else total - 1
                    end = min(end, total - 1)
                    status = 206
            except ValueError:
                start, end = 0, total - 1
                status = 200
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
        self.end_headers()
        if head_only:
            return
        try:
            with path.open("rb") as handle:
                handle.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = handle.read(min(256 * 1024, remaining))
                    if not chunk:
                        break
                    self._throttle(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass


def start_server(root: Path, mode: str, latency_ms: int = 0,
                 throughput_mbps: float = 0) -> FileServer:
    server = FileServer(root, mode, latency_ms=latency_ms, throughput_mbps=throughput_mbps)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def test_url(url: str, timeout: float = 60,
             headers: dict | None = None) -> dict:
    """用 ffprobe 读一次，验证服务端 Range / 302 / 鉴权是否可用。"""
    result = {}
    started = time.time()
    cmd = [str(FFPROBE), "-v", "error"]
    if headers:
        cmd += ["-headers", "".join(f"{k}: {v}\r\n" for k, v in headers.items())]
    cmd += ["-show_entries", "format=duration,size", "-of", "json", url]
    code, out, err, _ = run(cmd, timeout=timeout)
    result["ffprobe"] = {"ok": code == 0, "seconds": round(time.time() - started, 2),
                         "error": err.strip()[:300]}
    if code == 0:
        try:
            result["ffprobe"]["duration"] = float(json.loads(out)["format"]["duration"])
        except (KeyError, ValueError, json.JSONDecodeError):
            pass
    return result


def transport_tests(facts: dict) -> dict:
    report = {"servers": {}, "avplayer": {}}
    mkvs = ["04_h264_ac3_51.mkv", "06_h264_dts_51.mkv"]
    mp4s = ["01_h264_aac_stereo.mp4", "18_hevc_aac_stereo.mp4"]

    scenarios = [
        ("plain", "WebDAV / 普通 Range 直链", 0, 0),
        ("auth", "WebDAV + Basic 鉴权 + Referer", 20, 12),
        ("redirect", "网盘 302 签名直链 + Range", 40, 8),
        ("norange", "不支持 Range（只能顺序转发）", 20, 12),
    ]
    for mode, title, latency, mbps in scenarios:
        server = start_server(MEDIA, mode, latency_ms=latency, throughput_mbps=mbps)
        headers = {}
        if mode == "auth":
            # 模拟 App 注入的 WebDAV 凭据与防盗链请求头。
            headers = {
                "Authorization": "Basic " + base64.b64encode(b"user:pass").decode(),
                "Referer": "https://pan.example.com/",
            }
        entry = {"title": title, "latency_ms": latency, "throughput_mbps": mbps,
                 "headers_injected": sorted(headers.keys()), "tests": {}}
        try:
            for name in mkvs:
                url = f"{server.base}/files/{urllib.parse.quote(name)}"
                started = time.time()
                result = test_url(url, headers=headers)
                # 与 App 一致的远端转封装：readrate 10 + 跳 3 秒。
                out_dir = OUT / "transport" / f"{mode}_{Path(name).stem}"
                if out_dir.exists():
                    shutil.rmtree(out_dir)
                out_dir.mkdir(parents=True)
                args = ["-y", "-v", "error", "-probesize", "2M", "-analyzeduration", "2M"]
                if headers:
                    args += ["-headers",
                             "".join(f"{k}: {v}\r\n" for k, v in headers.items())]
                args += ["-readrate", "10", "-noaccurate_seek", "-ss", "3.000",
                         "-i", url, "-copyts", "-start_at_zero", "-avoid_negative_ts", "make_zero",
                         "-map", "0:v:0", "-c:v", "copy", "-c:a", "copy",
                         "-max_muxing_queue_size", "2048",
                         "-f", "hls", "-hls_time", "2", "-hls_init_time", "0.5",
                         "-hls_list_size", "0", "-hls_playlist_type", "event",
                         "-hls_flags", "temp_file", "-hls_segment_type", "fmp4",
                         "-hls_fmp4_init_filename", "init.mp4",
                         "-hls_segment_filename", str(out_dir / "seg%05d.m4s"),
                         str(out_dir / "live.m3u8")]
                code, _, err, elapsed = run([str(FFMPEG), *args], timeout=120)
                playlist = out_dir / "live.m3u8"
                entry["tests"][name] = {
                    **result,
                    "remux": {"ok": code == 0, "seconds": round(elapsed, 2),
                              "stderr": err.strip()[:300],
                              "reliable": "Unexpected offset" not in err,
                              "segments": playlist.exists()
                              and playlist.read_text().count("#EXTINF")},
                    "ttfb_seconds": round(time.time() - started, 2),
                }
            for name in mp4s:
                url = f"{server.base}/files/{urllib.parse.quote(name)}"
                results = avprobe([url], headers=headers)
                entry["tests"][name] = {"avplayer": results[0] if results else None}
        finally:
            server.shutdown()
            server.server_close()
        report["servers"][mode] = entry
        summary = {}
        for name, item in entry["tests"].items():
            if "remux" in item:
                remux = item["remux"]
                summary[name] = ("ok" if remux.get("ok") and remux.get("reliable")
                                 else "fail")
            else:
                player = item.get("avplayer") or {}
                summary[name] = ("ok" if player.get("itemStatus") == "readyToPlay"
                                 else "fail")
        log(f"传输 {mode}：{json.dumps(summary, ensure_ascii=False)}")
    (REPORTS / "transport.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    return report


# ---------------------------------------------------------------------------
# 6. 汇总
# ---------------------------------------------------------------------------

def seek_tests(facts: dict) -> dict:
    """转封装 seek：AC-3 / E-AC-3 直通、DTS→AC-3、多音轨 master 各跳 3 秒起流。
    这是 AV 同步文档里 `-noaccurate_seek` 修复在新增音频策略上的回归验证。"""
    plan_ac3 = {"mode": "remux", "audio_copy": True, "multi_audio": False,
                "tone_map": False, "interlaced": False, "audio_encoder": None}
    plan_dts = {"mode": "remux", "audio_copy": False, "multi_audio": False,
                "tone_map": False, "interlaced": False, "audio_encoder": "ac3"}
    plan_multi = {"mode": "remux", "audio_copy": True, "multi_audio": True,
                  "tone_map": False, "interlaced": False, "audio_encoder": None}
    jobs = [
        ("04_h264_ac3_51.mkv", plan_ac3),
        ("05_h264_eac3_51.mkv", plan_ac3),
        ("06_h264_dts_51.mkv", plan_dts),
        ("16_h264_aac51_ac351.mkv", plan_multi),
    ]
    report = {"cases": {}}
    outputs: list[tuple[str, Path]] = []
    for name, plan in jobs:
        summary = facts["files"].get(name)
        if not summary:
            continue
        out_dir = HLS / f"seek_{Path(name).stem}"
        if out_dir.exists():
            shutil.rmtree(out_dir)
        out_dir.mkdir(parents=True)
        args = hls_arguments(str(MEDIA / name), out_dir, plan, summary)
        # 与 VideoStreamSession 一致：输入侧关掉 accurate_seek，再带 copyts 起流。
        index = args.index("-i")
        args[index:index] = ["-noaccurate_seek", "-ss", "3.000"]
        after_input = args.index("-i") + 2
        args[after_input:after_input] = ["-copyts", "-start_at_zero",
                                         "-avoid_negative_ts", "make_zero"]
        code, _, err, elapsed = run([str(FFMPEG), *args])
        verify = hls_verify(out_dir, plan["multi_audio"])
        report["cases"][name] = {"exit": code, "seconds": round(elapsed, 2),
                                 "stderr": err.strip()[:400], "verify": verify}
        outputs.append((name, out_dir))
        log(f"seek {name}: exit={code} seg={verify.get('segments')} "
            f"aPkt={verify.get('first_segment_audio_packets')}")
    server = start_server(HLS, "plain")
    try:
        urls: list[tuple[str, str]] = []
        for name, out_dir in outputs:
            entry = "master.m3u8" if (out_dir / "master.m3u8").exists() else "live.m3u8"
            urls.append((name, f"{server.base}/{out_dir.name}/{entry}"))
        results = avprobe([url for _, url in urls])
        for (name, _), item in zip(urls, results):
            record = report["cases"][name]
            record["avplayer"] = {
                "itemStatus": item.get("itemStatus"),
                "audioOptions": [option.get("displayName")
                                 for option in item.get("audioOptions", [])],
                "itemTracks": item.get("itemTracks") or [],
                "playedRate": item.get("playedRate"),
                "playedSeconds": item.get("playedSeconds"),
            }
    finally:
        server.shutdown()
        server.server_close()
    (REPORTS / "seek.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    return report


def summarize(facts: dict, hls: dict, transport: dict) -> None:
    lines = ["# Luma 视频 / 音轨组合测试结果", "",
             f"生成时间：{time.strftime('%Y-%m-%d %H:%M:%S')}", ""]
    lines += ["## 1. 组合矩阵", "",
              "| 文件 | 源视频 | 源音频 | 原生直读 | 最佳路径 | HLS 输出 | 首片秒 | 首片音频包 | AVPlayer 实际起播 |",
              "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for case in CASES:
        name = case["file"]
        summary = facts["files"].get(name)
        if not summary:
            continue
        native = (facts.get("avplayer") or {}).get(name) or {}
        record = (hls.get("cases") or {}).get(name) or {}
        plan = record.get("plan") or {}
        verify = record.get("verify") or {}
        fallback = record.get("fallback") or {}
        player = record.get("avplayer") or {}
        effective = record.get("effective") or plan.get("path") or "-"
        if native.get("isPlayable") and native.get("itemStatus") == "readyToPlay":
            native_desc = "是"
        elif native.get("itemStatus") == "readyToPlay":
            native_desc = "探测否/实际可播"
        else:
            native_desc = "否"
        if effective == "native":
            path_desc = "AVPlayer 直读（无 ffmpeg）"
        elif effective == "remux":
            audio = "copy" if plan.get("audio_copy") else f"→{plan.get('audio_encoder')}"
            path_desc = f"remux：v copy + a {audio}"
            if plan.get("multi_audio"):
                path_desc += "（多音轨 master）"
        else:
            path_desc = "transcode：VT H.264 + " + str(plan.get("audio_encoder") or "aac")
            if plan.get("tone_map"):
                path_desc += " + libplacebo 映射"
        target = verify if effective == plan.get("mode") else fallback.get("verify", {})
        streams = target.get("streams") or []
        hls_desc = "-" if effective == "native" else ", ".join(
            f"{s['type']}:{s['codec']}" for s in streams if s.get("codec")) or "失败"
        packets = target.get("first_segment_audio_packets")
        first_seconds = target.get("first_segment_seconds")
        if effective == "native":
            actual = (f"ready / rate={native.get('playedRate')} / "
                      f"{round(native.get('playedSeconds') or 0, 2)}s")
        else:
            actual = (f"{player.get('itemStatus')} / rate={player.get('playedRate')} / "
                      f"{round(player.get('playedSeconds') or 0, 2)}s")
            if player.get("itemTracks"):
                actual += " / " + ",".join(player["itemTracks"])
        audio_desc = " / ".join(
            f"{a['codec']} {a['channels']}ch" for a in summary.get("audio", [])) or "-"
        lines.append(
            f"| {name} | {summary['video']['codec']} {summary['video']['profile'] or ''} "
            f"{summary['video']['pix_fmt']} {summary['video']['size']} | {audio_desc} | "
            f"{native_desc} | {path_desc} | {hls_desc} | {first_seconds or '-'} | "
            f"{packets if packets is not None else '-'} | {actual} |")

    lines += ["", "## 2. HDR / 杜比视界路径", ""]
    lines.append("| 文件 | 策略 | 输出尺寸 | 输出色彩 | 耗时 | 实时倍率 | AVPlayer |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- |")
    for name, record in (hls.get("cases") or {}).items():
        tm = record.get("tonemap")
        if not tm:
            continue
        color = tm.get("color") or {}
        summary = facts["files"].get(name) or {}
        source_duration = float(summary.get("duration") or 0)
        speed = (round(source_duration / tm["seconds"], 2)
                 if tm.get("seconds") and source_duration else "-")
        player = tm.get("avplayer") or {}
        lines.append(f"| {name} | 强制 HDR→SDR | {color.get('size')} | "
                     f"{color.get('primaries')}/{color.get('transfer')} | "
                     f"{tm.get('seconds')}s | {speed}× | {player.get('itemStatus')} "
                     f"{','.join(player.get('itemTracks') or [])} |")

    switch = next(((name, record["audioSwitch"])
                   for name, record in (hls.get("cases") or {}).items()
                   if record.get("audioSwitch")), None)
    if switch:
        name, info = switch
        lines += ["", "## 3. 多音轨即时切换", "",
                  f"{name}：切到第 2 条音轨后 `selectedAudio={info.get('selectedAudio')}`，"
                  f"itemStatus={info.get('itemStatus')}，"
                  f"itemTracks={info.get('itemTracks')}，"
                  f"播放推进 {round(info.get('playedSeconds') or 0, 2)}s。", ""]

    lines += ["## 4. 传输", "",
              "| 方式 | 文件 | ffprobe | 远端 remux | 可靠 | 首片 | AVPlayer 直读 |",
              "| --- | --- | --- | --- | --- | --- | --- |"]
    for mode, entry in (transport.get("servers") or {}).items():
        for name, item in entry.get("tests", {}).items():
            remux = item.get("remux") or {}
            player = item.get("avplayer") or {}
            lines.append(
                f"| {mode} | {name} | {(item.get('ffprobe') or {}).get('ok')} | "
                f"{remux.get('ok')} | {remux.get('reliable', '-')} | "
                f"{remux.get('segments', '-')} | {player.get('itemStatus', '-')} |")

    lines += ["", "## 5. AVPlayer 原生直读事实", "",
              "| 文件 | isPlayable | itemStatus | 轨道 | 视频 codec | 音频 codec | videoRange | 起播 |",
              "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for name, item in (facts.get("avplayer") or {}).items():
        tracks = item.get("tracks", [])
        video = next((t for t in tracks if t.get("type") in ("video", "vide")), {})
        audio = next((t for t in tracks if t.get("type") in ("audio", "soun")), {})
        lines.append(
            f"| {name} | {item.get('isPlayable')} | {item.get('itemStatus')} | "
            f"{len(tracks)} | {','.join(video.get('codecs') or [])} | "
            f"{','.join(audio.get('codecs') or [])} | {item.get('videoRange')} | "
            f"rate={item.get('playedRate')} {round(item.get('playedSeconds') or 0, 2)}s |")
    lines.append("")
    (REPORTS / "summary.md").write_text("\n".join(lines))
    log(f"汇总写入 {REPORTS/'summary.md'}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Luma 视频 / 音轨组合测试矩阵")
    parser.add_argument("step", nargs="?", default="all",
                        choices=["generate", "probe", "avplayer", "hls", "seek", "transport", "all"])
    parser.add_argument("--force", action="store_true", help="重新生成已存在的样片")
    args = parser.parse_args()

    for directory in (MEDIA, HLS, REPORTS):
        directory.mkdir(parents=True, exist_ok=True)

    if args.step in ("generate", "all"):
        generate(force=args.force)
    if args.step in ("probe", "all"):
        probe_all()
    if args.step in ("avplayer", "all"):
        probe_avplayer()
    if args.step in ("hls", "all"):
        facts = json.loads((REPORTS / "facts.json").read_text())
        run_hls(facts)
    if args.step in ("seek", "all"):
        facts = json.loads((REPORTS / "facts.json").read_text())
        seek_tests(facts)
    if args.step in ("transport", "all"):
        facts = json.loads((REPORTS / "facts.json").read_text())
        transport_tests(facts)
    if args.step == "all":
        facts = json.loads((REPORTS / "facts.json").read_text())
        hls = json.loads((REPORTS / "hls.json").read_text())
        transport = json.loads((REPORTS / "transport.json").read_text())
        summarize(facts, hls, transport)


if __name__ == "__main__":
    main()
