#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> [1/3] 运行 NanoKit 核心引擎单元测试 (macOS)..."
(cd Packages/NanoKit && swift test)

echo "==> [2/3] 检查 XcodeGen 是否安装..."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "未检测到 xcodegen，正在通过 Homebrew 安装 (或可直接双击 Packages/NanoKit/Package.swift 用 Xcode 打开调试)..."
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "请先执行: brew install xcodegen，然后重新运行本脚本。"
    exit 1
  fi
fi

echo "==> [3/3] 生成双端 Nano.xcodeproj (包含 Nano-macOS 与 Nano-tvOS)..."
xcodegen generate
echo "生成完毕！现在正在使用 Xcode 打开 Nano.xcodeproj..."
open Nano.xcodeproj
