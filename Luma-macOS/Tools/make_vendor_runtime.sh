#!/bin/sh
# 把 Homebrew 的 ffmpeg-full（含 libplacebo）连同全部依赖与 MoltenVK 打包成可搬移运行时，
# 输出到 Vendor/ffmpeg-dv。之后 build.sh 只复制 Vendor 里的产物，
# 不再依赖构建机当前装了哪个版本的 ffmpeg。
#
# 用法：sh Tools/make_vendor_runtime.sh
# 前置：brew install ffmpeg-full molten-vk（需要原生 arm64 Homebrew）
set -eu
cd "$(dirname "$0")/.."

PREFIX="${HOMEBREW_PREFIX:-}"
if [ -z "$PREFIX" ]; then
    for candidate in /opt/homebrew /usr/local; do
        if [ -x "$candidate/opt/ffmpeg-full/bin/ffmpeg" ]; then
            PREFIX="$candidate"
            break
        fi
    done
fi
if [ -z "$PREFIX" ]; then
    echo "未找到 ffmpeg-full：先执行 brew install ffmpeg-full molten-vk" >&2
    exit 1
fi

FFMPEG="$PREFIX/opt/ffmpeg-full/bin/ffmpeg"
FFPROBE="$PREFIX/opt/ffmpeg-full/bin/ffprobe"
MOLTENVK="$PREFIX/opt/molten-vk/lib/libMoltenVK.dylib"
for file in "$FFMPEG" "$FFPROBE" "$MOLTENVK"; do
    if [ ! -e "$file" ]; then
        echo "缺少 $file：先执行 brew install ffmpeg-full molten-vk" >&2
        exit 1
    fi
done
if ! "$FFMPEG" -hide_banner -filters 2>/dev/null | grep -q libplacebo; then
    echo "$FFMPEG 不含 libplacebo，无法处理杜比视界" >&2
    exit 1
fi

OUT="Vendor/ffmpeg-dv"
rm -rf "$OUT"
python3 Tools/bundle_ffmpeg.py \
    --ffmpeg "$FFMPEG" \
    --ffprobe "$FFPROBE" \
    --moltenvk "$MOLTENVK" \
    --out "$OUT"

{
    "$FFMPEG" -version 2>/dev/null | head -1
    echo "打包自：$PREFIX"
    "$PREFIX/bin/brew" list --versions ffmpeg-full molten-vk libplacebo vulkan-loader \
        libass dav1d libvpx x264 x265 aom svt-av1 rav1e tesseract gnutls 2>/dev/null || true
} > "$OUT/VERSIONS.txt"

du -sh "$OUT"
