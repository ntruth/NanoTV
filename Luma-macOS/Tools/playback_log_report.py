#!/usr/bin/env python3
"""把 Luma 诊断日志汇总成播放端到端报告（T14）。

日志来源：~/Library/Logs/Luma/diagnostics.log
只做事实统计，不猜测：首段耗时、拖拽起流、卡顿、失败原因、缓存命中与自适应事件。

用法：
    python3 Tools/playback_log_report.py                      # 全量
    python3 Tools/playback_log_report.py --since 2026-11-22
    python3 Tools/playback_log_report.py --json               # 机器可读
    python3 Tools/playback_log_report.py --out report.md      # 另存 Markdown
"""

import argparse
import json
import math
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime

DEFAULT_LOG = os.path.expanduser("~/Library/Logs/Luma/diagnostics.log")

LINE = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T[^\]]+)\]\s?(.*)$")

FIRST_SEG = re.compile(
    r"首段就绪 (?P<title>.+?) (?P<source>本地|网盘) mode=(?P<mode>\w+) "
    r"offset=(?P<offset>\d+) 对齐=(?P<aligned>\d+) 用时 (?P<ms>\d+)ms")
DRAG_START = re.compile(
    r"拖拽起流 (?P<title>.+?) (?P<source>本地|网盘) → (?P<offset>\d+)s 用时 (?P<ms>\d+)ms")
BUFFER_WAIT = re.compile(r"缓冲等待 (?P<s>\d+)s：已生成领先 (?P<ahead>\d+)s · mode=(?P<mode>\w+)")
PLAYER_STUCK = re.compile(r"播放器卡住 (?P<s>\d+)s")
HEARTBEAT = re.compile(r"播放心跳 pos=(?P<pos>\d+)s 领先=(?P<ahead>\d+)s")
ADAPT = re.compile(r"网络自适应：(?P<from>.+?) → (?P<to>.+?) 吞吐 (?P<mbps>\d+)Mbps")
CACHE_HIT = re.compile(r"命中完整缓存 (?P<name>.+?) 起播")
FFMPEG_FAIL = re.compile(r"边下边播失败：(?P<reason>.+)")
FFMPEG_EXIT = re.compile(r"边下边播转换异常结束 status=(?P<status>-?\d+)：(?P<tail>.+)")
SESSION_ABORT = re.compile(r"边下边播会话提前结束")


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(pct / 100 * len(ordered)) - 1))
    return ordered[index]


def stats(values):
    if not values:
        return None
    return {
        "count": len(values),
        "min": min(values),
        "p50": percentile(values, 50),
        "p95": percentile(values, 95),
        "max": max(values),
        "avg": round(sum(values) / len(values), 1),
    }


def normalize(reason):
    """把文件名 / 数字等易变部分抹掉，便于按原因聚合。"""
    text = reason.strip()
    text = re.sub(r"https?://\S+", "<url>", text)
    text = re.sub(r"/[^\s:]+\.(?:mkv|mp4|mov|avi|ts|webm)", "<file>", text)
    text = re.sub(r"pos=\d+s", "pos=<n>s", text)
    text = re.sub(r"at \d+s", "at <n>s", text)
    text = re.sub(r"状态码\s*\d+|HTTP \d+", "HTTP <code>", text)
    return text[:80]


def parse(path, since=None, until=None):
    events = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = LINE.match(line.rstrip("\n"))
            if not match:
                continue
            stamp, message = match.group(1), match.group(2)
            if since and stamp[:10] < since:
                continue
            if until and stamp[:10] > until:
                continue
            events.append((stamp, message))
    return events


def analyze(events):
    first_segments = []
    drag_starts = []
    buffer_waits = []
    stuck = []
    heartbeats = []
    adaptations = []
    cache_hits = 0
    failures = Counter()
    ffmpeg_exits = Counter()
    aborted = 0
    rebuilds = 0
    fallbacks = 0

    for stamp, message in events:
        if match := FIRST_SEG.search(message):
            first_segments.append({
                "time": stamp, "title": match["title"], "source": match["source"],
                "mode": match["mode"], "offset": int(match["offset"]),
                "aligned": int(match["aligned"]), "ms": int(match["ms"]),
            })
        elif match := DRAG_START.search(message):
            drag_starts.append({"time": stamp, "source": match["source"],
                                "offset": int(match["offset"]), "ms": int(match["ms"])})
        elif match := BUFFER_WAIT.search(message):
            buffer_waits.append({"time": stamp, "seconds": int(match["s"]),
                                 "ahead": int(match["ahead"]), "mode": match["mode"]})
        elif match := PLAYER_STUCK.search(message):
            stuck.append({"time": stamp, "seconds": int(match["s"])})
        elif match := HEARTBEAT.search(message):
            heartbeats.append({"time": stamp, "pos": int(match["pos"]),
                               "ahead": int(match["ahead"])})
        elif match := ADAPT.search(message):
            adaptations.append({"time": stamp, "from": match["from"],
                                "to": match["to"], "mbps": int(match["mbps"])})
        elif CACHE_HIT.search(message):
            cache_hits += 1
        elif "卡住超过" in message and "重建流恢复播放" in message:
            rebuilds += 1
        elif "播放器读不到音轨" in message:
            fallbacks += 1
        elif match := FFMPEG_FAIL.search(message):
            failures[normalize(match["reason"])] += 1
        elif match := FFMPEG_EXIT.search(message):
            tail = normalize(match["tail"])
            ffmpeg_exits[f"status={match['status']} · {tail}"] += 1
        elif SESSION_ABORT.search(message):
            aborted += 1

    by_source = defaultdict(list)
    for item in first_segments:
        by_source[f'{item["source"]}/{item["mode"]}'].append(item["ms"])

    low_ahead = [h for h in heartbeats if h["ahead"] < 5]
    covered = len(heartbeats) * 10

    return {
        "log_range": {
            "first": events[0][0] if events else None,
            "last": events[-1][0] if events else None,
            "lines": len(events),
        },
        "first_segment": {
            "total": len(first_segments),
            "by_source": {key: stats(values) for key, values in sorted(by_source.items())},
            "worst": sorted(first_segments, key=lambda item: item["ms"], reverse=True)[:5],
        },
        "drag_start": {
            "total": len(drag_starts),
            "all": stats([item["ms"] for item in drag_starts]),
            "worst": sorted(drag_starts, key=lambda item: item["ms"], reverse=True)[:5],
        },
        "stall": {
            "buffer_wait_count": len(buffer_waits),
            "buffer_wait_over_10s": len([item for item in buffer_waits if item["seconds"] >= 10]),
            "buffer_wait_worst": max([item["seconds"] for item in buffer_waits], default=0),
            "player_stuck_count": len(stuck),
            "rebuild_count": rebuilds,
        },
        "heartbeat": {
            "count": len(heartbeats),
            "covered_seconds": covered,
            "ahead_below_5s": len(low_ahead),
            "ahead_below_5s_ratio": round(len(low_ahead) / len(heartbeats), 3) if heartbeats else None,
            "min_ahead": min([h["ahead"] for h in heartbeats], default=None),
        },
        "cache_hits": cache_hits,
        "audio_fallbacks": fallbacks,
        "adaptations": adaptations,
        "failures": failures.most_common(),
        "ffmpeg_exits": ffmpeg_exits.most_common(),
        "aborted_sessions": aborted,
    }


def fmt_stats(label, item):
    if not item:
        return f"| {label} | 0 | - | - | - | - | - |"
    return (f'| {label} | {item["count"]} | {item["min"]} | {item["p50"]} | '
            f'{item["p95"]} | {item["max"]} | {item["avg"]} |')


def render(report):
    out = []
    span = report["log_range"]
    out.append("# 播放端到端日志报告（T14）\n")
    out.append(f'- 日志范围：{span["first"] or "-"} → {span["last"] or "-"}（{span["lines"]} 行）')
    out.append(f'- 首段就绪会话：{report["first_segment"]["total"]} 次')
    out.append(f'- 心跳覆盖播放时长：约 {report["heartbeat"]["covered_seconds"]} 秒')
    out.append("")

    out.append("## 首段就绪耗时（ms）\n")
    out.append("| 来源/mode | 次数 | min | p50 | p95 | max | avg |")
    out.append("| --- | --- | --- | --- | --- | --- | --- |")
    for key, item in report["first_segment"]["by_source"].items():
        out.append(fmt_stats(key, item))
    out.append("")

    worst = report["first_segment"]["worst"]
    if worst:
        out.append("最慢的 5 次：\n")
        out.append("| 时间 | 来源 | mode | offset | 用时 | 片名 |")
        out.append("| --- | --- | --- | --- | --- | --- |")
        for item in worst:
            out.append(f'| {item["time"]} | {item["source"]} | {item["mode"]} | '
                       f'{item["offset"]}s | {item["ms"]}ms | {item["title"][:60]} |')
        out.append("")

    drag = report["drag_start"]
    out.append("## 拖拽起流（ms）\n")
    out.append("| 次数 | min | p50 | p95 | max | avg |")
    out.append("| --- | --- | --- | --- | --- | --- |")
    item = drag["all"]
    if item:
        out.append(f'| {item["count"]} | {item["min"]} | {item["p50"]} | '
                   f'{item["p95"]} | {item["max"]} | {item["avg"]} |')
    else:
        out.append("| 0 | - | - | - | - | - |")
    out.append("")

    stall = report["stall"]
    beat = report["heartbeat"]
    out.append("## 卡顿与生成领先\n")
    out.append(f'- 缓冲等待：{stall["buffer_wait_count"]} 次（≥10s 的 {stall["buffer_wait_over_10s"]} 次，'
               f'最长 {stall["buffer_wait_worst"]}s）')
    out.append(f'- 播放器卡住轻推：{stall["player_stuck_count"]} 次；40s 重建流：{stall["rebuild_count"]} 次')
    out.append(f'- 心跳 {beat["count"]} 条；领先 <5s 的比例 '
               f'{beat["ahead_below_5s_ratio"] if beat["ahead_below_5s_ratio"] is not None else "-"}'
               f'（最低 {beat["min_ahead"]}s）')
    out.append(f'- 命中完整缓存：{report["cache_hits"]} 次；音频兜底重建：{report["audio_fallbacks"]} 次；'
               f'首段前中断：{report["aborted_sessions"]} 次')
    out.append("")

    if report["adaptations"]:
        out.append("## 网络自适应\n")
        out.append("| 时间 | 档位 | 实测吞吐 |")
        out.append("| --- | --- | --- |")
        for item in report["adaptations"]:
            out.append(f'| {item["time"]} | {item["from"]} → {item["to"]} | {item["mbps"]}Mbps |')
        out.append("")

    if report["failures"]:
        out.append("## 失败原因 Top\n")
        out.append("| 次数 | 原因 |")
        out.append("| --- | --- |")
        for reason, count in report["failures"][:10]:
            out.append(f"| {count} | {reason} |")
        out.append("")

    if report["ffmpeg_exits"]:
        out.append("## ffmpeg 异常退出 Top\n")
        out.append("| 次数 | 退出信息 |")
        out.append("| --- | --- |")
        for reason, count in report["ffmpeg_exits"][:10]:
            out.append(f"| {count} | {reason} |")
        out.append("")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description="汇总 Luma 播放端到端日志")
    parser.add_argument("--log", default=DEFAULT_LOG, help="诊断日志路径")
    parser.add_argument("--since", help="起始日期，YYYY-MM-DD")
    parser.add_argument("--until", help="结束日期，YYYY-MM-DD")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    parser.add_argument("--out", help="另存 Markdown 报告路径")
    args = parser.parse_args()

    if not os.path.exists(args.log):
        print(f"找不到日志：{args.log}", file=sys.stderr)
        print("先在 Luma 里播放几个样片，或把日志路径传给 --log", file=sys.stderr)
        return 1

    report = analyze(parse(args.log, args.since, args.until))
    text = json.dumps(report, ensure_ascii=False, indent=2) if args.json else render(report)
    print(text)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
        print(f"\n已写入 {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
