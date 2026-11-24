#!/usr/bin/env bash
set -euo pipefail

# 可选高阶构建脚本：将 OpenList / xiaoya-alist (Go) 交叉编译为 macOS + Apple TV (tvOS) 静态库 LibXiaoya.xcframework
# 使 Apple TV 在局域网没有任何现成 NAS/Mac 小雅服务时，也能在 App 进程内独立启动 127.0.0.1:5678

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build_xiaoya_xcf"
mkdir -p "$BUILD_DIR"

if ! command -v go >/dev/null 2>&1; then
  echo "请先安装 Go (brew install go) 后再执行本脚本。"
  exit 1
fi

echo "==> [1/4] 拉取 OpenList / 小雅兼容 Go 内核源码..."
if [ ! -d "$BUILD_DIR/src" ]; then
  git clone --depth 1 https://github.com/OpenListTeam/OpenList.git "$BUILD_DIR/src"
fi

cat > "$BUILD_DIR/src/nano_c_bridge.go" << 'EOF'
package main

import "C"
import (
	"os"
)

//export StartEmbeddedXiaoya
func StartEmbeddedXiaoya(dataDir *C.char, port C.int) {
	dir := C.GoString(dataDir)
	go func() {
		os.Args = []string{"alist", "server", "--data", dir}
		main()
	}()
}
EOF

echo "==> [2/4] 编译 macOS arm64 静态库..."
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
(
  cd "$BUILD_DIR/src"
  CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
    CGO_CFLAGS="-isysroot $MAC_SDK -mmacosx-version-min=14.0" \
    CGO_LDFLAGS="-isysroot $MAC_SDK -mmacosx-version-min=14.0" \
    go build -buildmode=c-archive -o "$BUILD_DIR/macos/libxiaoya.a" .
)

echo "==> [3/4] 编译 Apple TV (tvOS arm64) 静态库..."
TV_SDK="$(xcrun --sdk appletvos --show-sdk-path)"
CC_TV="$(xcrun --sdk appletvos --find clang)"
(
  cd "$BUILD_DIR/src"
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$CC_TV" \
    CGO_CFLAGS="-isysroot $TV_SDK -mtvos-version-min=17.0 -fembed-bitcode" \
    CGO_LDFLAGS="-isysroot $TV_SDK -mtvos-version-min=17.0" \
    go build -buildmode=c-archive -o "$BUILD_DIR/tvos/libxiaoya.a" .
)

echo "==> [4/4] 封装生成 LibXiaoya.xcframework..."
rm -rf "$ROOT_DIR/Packages/NanoKit/Vendor/LibXiaoya.xcframework"
mkdir -p "$ROOT_DIR/Packages/NanoKit/Vendor"
xcodebuild -create-xcframework \
  -library "$BUILD_DIR/macos/libxiaoya.a" -headers "$BUILD_DIR/macos" \
  -library "$BUILD_DIR/tvos/libxiaoya.a" -headers "$BUILD_DIR/tvos" \
  -output "$ROOT_DIR/Packages/NanoKit/Vendor/LibXiaoya.xcframework"

echo "构建完成：Packages/NanoKit/Vendor/LibXiaoya.xcframework"
