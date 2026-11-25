#!/usr/bin/env python3
"""生成 README 顶部的品牌动图（拾光 Luma）。

用法：python3 Tools/brand_hero_gif.py
产物：docs/assets/brand-hero.gif（Markdown 里可直接播放）
"""

import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 960, 560
FRAMES = 64
FRAME_MS = 50

CJK = "/System/Library/Fonts/Hiragino Sans GB.ttc"
LATIN_CANDIDATES = [
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/SFNS.ttf",
]


def font(path, size, index=0):
    try:
        return ImageFont.truetype(path, size, index=index)
    except OSError:
        return ImageFont.truetype(path, size)


def latin_font(size):
    for path in LATIN_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size, index=0)
            except OSError:
                continue
    return ImageFont.load_default()


TITLE_FONT = font(CJK, 118, index=2)
SLOGAN_FONT = font(CJK, 24, index=2)
BODY_FONT = font(CJK, 19, index=0)
SMALL_FONT = font(CJK, 16, index=0)
BRAND_FONT = latin_font(20)
LABEL_FONT = font(CJK, 17, index=2)

# 品牌色
CORAL = (255, 143, 122)
AMBER = (255, 196, 107)
PINK = (255, 122, 199)
VIOLET = (168, 140, 255)
CYAN = (94, 217, 255)
MINT = (125, 247, 191)

random.seed(20261125)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def gradient_row(stops, width):
    """横向多段渐变。"""
    img = Image.new("RGB", (width, 1))
    px = img.load()
    for x in range(width):
        t = x / max(1, width - 1) * (len(stops) - 1)
        i = min(int(t), len(stops) - 2)
        px[x, 0] = lerp(stops[i], stops[i + 1], t - i)
    return img


def add_glow(base, color, center, radius, strength):
    """在整张画布上叠一团柔光；椭圆完全落在画布内，边缘自然衰减，不留方框接缝。"""
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    cx, cy = center
    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius * 0.62))
    mask = mask.point(lambda v: int(v * strength))
    tint = Image.new("RGB", (W, H), color)
    base.paste(tint, (0, 0), mask)


def build_base():
    """深空底：上紫下青、三团品牌色光晕、四角压暗。"""
    base = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(base)
    top = (32, 22, 52)
    bottom = (7, 20, 26)
    for y in range(H):
        draw.line([(0, y), (W, y)], fill=lerp(top, bottom, (y / H) ** 0.92))

    add_glow(base, (120, 60, 150), (W * 0.20, H * 0.24), W * 0.34, 0.30)
    add_glow(base, (140, 84, 46), (W * 0.74, H * 0.30), W * 0.30, 0.20)
    add_glow(base, (24, 96, 128), (W * 0.52, H * 0.82), W * 0.36, 0.22)

    # 暗角
    vignette = Image.new("L", (W, H), 0)
    vd = ImageDraw.Draw(vignette)
    vd.ellipse([-W * 0.18, -H * 0.22, W * 1.18, H * 1.22], fill=255)
    vignette = vignette.filter(ImageFilter.GaussianBlur(90))
    shade = Image.new("RGB", (W, H), (0, 0, 0))
    base = Image.composite(base, Image.blend(base, shade, 0.55), vignette)
    return base


STARS = [
    (
        random.uniform(10, W - 10),
        random.uniform(10, H * 0.78),
        random.choice([1.4, 1.7, 2.0, 2.4, 2.9]),
        random.choice([AMBER, PINK, VIOLET, CYAN, MINT, (230, 233, 240)]),
        random.uniform(0, math.tau),
        random.uniform(0.7, 1.6),
    )
    for _ in range(96)
]

MOTES = [
    (
        random.uniform(20, W - 20),
        random.uniform(H * 0.12, H * 0.95),
        random.choice([2.0, 2.6, 3.2]),
        random.choice([AMBER, PINK, VIOLET, CYAN, MINT]),
        random.uniform(8, 26),
        random.uniform(0, math.tau),
    )
    for _ in range(34)
]


TITLE_TOP = 74
TITLE_CANVAS_H = 260


def build_title_mask():
    """「拾光」的文字遮罩 + 外发光。"""
    mask = Image.new("L", (W, TITLE_CANVAS_H), 0)
    d = ImageDraw.Draw(mask)
    d.text((W / 2, 124), "拾光", font=TITLE_FONT, fill=255, anchor="mm")
    return mask


def build_title_gradient(mask):
    """渐变贴着文字实际宽度铺：左暖右冷，两个字各自跨到不同的色相。"""
    x0, _, x1, _ = mask.getbbox()
    pad = 24
    row = gradient_row([AMBER, CORAL, PINK, VIOLET, CYAN], max(1, x1 - x0 + pad * 2))
    grad = Image.new("RGB", (W, TITLE_CANVAS_H))
    for y in range(TITLE_CANVAS_H):
        grad.paste(row, (x0 - pad, y))
    return grad


TITLE_MASK = build_title_mask()
TITLE_GRAD = build_title_gradient(TITLE_MASK)
TITLE_GLOW = TITLE_MASK.filter(ImageFilter.GaussianBlur(26))


def wave_y(x, t):
    """历史 → 此刻 → 未来 的光线：两端起伏，中间汇聚在「此刻」。"""
    nx = x / W
    base = H * 0.815
    bend = 14 * math.sin(nx * math.pi * 2.1 + 0.4)
    dip = -26 * math.exp(-((nx - 0.5) ** 2) / 0.012)
    flow = 3.0 * math.sin(nx * 12 - t * math.tau * 1.4)
    return base + bend + dip + flow


def draw_wave(img, t):
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    glow_mask = Image.new("L", (W, H), 0)
    line = Image.new("RGB", (W, H), (0, 0, 0))
    line_mask = Image.new("L", (W, H), 0)
    gd = ImageDraw.Draw(glow)
    ld = ImageDraw.Draw(line)
    gm = ImageDraw.Draw(glow_mask)
    lm = ImageDraw.Draw(line_mask)

    points = [(x, wave_y(x, t)) for x in range(-10, W + 12, 4)]
    for i in range(len(points) - 1):
        nx = (points[i][0] / W) if points[i][0] > 0 else 0
        color = lerp(AMBER, PINK, min(1, nx * 2)) if nx < 0.5 else lerp(PINK, CYAN, (nx - 0.5) * 2)
        ld.line([points[i], points[i + 1]], fill=color, width=2)
        gm.line([points[i], points[i + 1]], fill=150, width=9)
        lm.line([points[i], points[i + 1]], fill=210, width=2)

    glow_mask = glow_mask.filter(ImageFilter.GaussianBlur(9))
    img.paste(glow, (0, 0), glow_mask)
    img.paste(line, (0, 0), line_mask)

    # 沿光线游走的光点：像被拾起的一束光
    for offset, radius, color in [(0.0, 5.0, (255, 246, 226)), (-0.06, 2.6, AMBER), (-0.13, 2.0, PINK)]:
        nx = (t + offset) % 1.0
        x = nx * W
        y = wave_y(x, t)
        halo = Image.new("L", (W, H), 0)
        hd = ImageDraw.Draw(halo)
        hd.ellipse([x - radius * 3.2, y - radius * 3.2, x + radius * 3.2, y + radius * 3.2], fill=120)
        halo = halo.filter(ImageFilter.GaussianBlur(radius * 2.4))
        img.paste(Image.new("RGB", (W, H), color), (0, 0), halo)
        ImageDraw.Draw(img).ellipse([x - radius, y - radius, x + radius, y + radius], fill=color)


def draw_stars(img, t):
    layer = Image.new("RGB", (W, H), (0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(layer)
    m = ImageDraw.Draw(mask)
    for x, y, r, color, phase, speed in STARS:
        twinkle = 0.5 + 0.5 * math.sin(t * math.tau * speed + phase)
        alpha = int(70 + 150 * twinkle)
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)
        m.ellipse([x - r, y - r, x + r, y + r], fill=alpha)
    mask = mask.filter(ImageFilter.GaussianBlur(0.6))
    img.paste(layer, (0, 0), mask)


def draw_motes(img, t):
    layer = Image.new("RGB", (W, H), (0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(layer)
    m = ImageDraw.Draw(mask)
    for x0, y0, r, color, speed, phase in MOTES:
        y = (y0 - speed * t) % (H * 0.96) + H * 0.02
        x = x0 + 8 * math.sin(t * math.tau + phase)
        alpha = int(90 + 110 * (0.5 + 0.5 * math.sin(t * math.tau * 1.3 + phase)))
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)
        m.ellipse([x - r, y - r, x + r, y + r], fill=alpha)
    mask = mask.filter(ImageFilter.GaussianBlur(1.4))
    img.paste(layer, (0, 0), mask)


def draw_brand_lines(img, t):
    d = ImageDraw.Draw(img)
    breathe = 0.5 + 0.5 * math.sin(t * math.tau)

    # SHIGUANG：字距拉开的小字母
    text = "SHIGUANG"
    tracking = 13
    widths = [d.textlength(ch, font=BRAND_FONT) for ch in text]
    total = sum(widths) + tracking * (len(text) - 1)
    x = (W - total) / 2
    y = 86
    for ch, w in zip(text, widths):
        d.text((x, y), ch, font=BRAND_FONT, fill=(196, 194, 206, 255))
        x += w + tracking

    # 品牌叙事
    lines = [
        ("拾，是拾起；光，是光影；拾光，也是时光。", SLOGAN_FONT, (240, 240, 246), 292),
        ("我们相信，每一张照片都是一束被留下的光。", BODY_FONT, (206, 208, 220), 337),
        ("拾光，就是替你把散落的光，一片一片捡回来。", BODY_FONT, (206, 208, 220), 366),
        ("从历史拾起光，向未来写下光", SMALL_FONT, (146, 150, 168), 400 + int(2 * breathe)),
    ]
    for text, fnt, color, y in lines:
        d.text((W / 2, y), text, font=fnt, fill=color, anchor="mm")

    # 时间轴标签
    for nx, label, color in [(0.17, "历史", (255, 176, 128)), (0.50, "此刻", (198, 176, 255)),
                             (0.83, "未来", (118, 214, 255))]:
        x = nx * W
        y = wave_y(x, t) + 44
        d.text((x, y), label, font=LABEL_FONT, fill=color, anchor="mm")


def main():
    base = build_base()
    frames = []
    for index in range(FRAMES):
        t = index / FRAMES
        img = base.copy()

        # 标题背后的呼吸光
        pulse = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(t * math.tau))
        aura = Image.new("RGB", (W, TITLE_CANVAS_H), (255, 150, 180))
        aura_mask = TITLE_GLOW.point(lambda v: int(v * (0.22 + 0.16 * pulse)))
        img.paste(aura, (0, TITLE_TOP - 6), aura_mask)

        draw_stars(img, t)
        draw_motes(img, t)
        draw_wave(img, t)

        float_y = int(4 * math.sin(t * math.tau))
        img.paste(TITLE_GRAD, (0, TITLE_TOP + float_y), TITLE_MASK)

        draw_brand_lines(img, t)
        frames.append(img)

    os.makedirs("docs/assets", exist_ok=True)
    palette_source = frames[0].quantize(colors=192, method=Image.MEDIANCUT, dither=Image.NONE)
    quantized = [f.quantize(palette=palette_source, dither=Image.NONE) for f in frames]
    out = "docs/assets/brand-hero.gif"
    quantized[0].save(out, save_all=True, append_images=quantized[1:],
                      duration=FRAME_MS, loop=0, optimize=True, disposal=2)
    frames[24].save("docs/assets/brand-hero.png")
    print("wrote", out, os.path.getsize(out) // 1024, "KB")


if __name__ == "__main__":
    main()
