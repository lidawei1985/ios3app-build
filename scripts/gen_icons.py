#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_icons.py — 三产品 iOS 图标与资产目录生成（1024x1024，单尺寸 AppIcon 规范）。
品牌核心视觉：星幕=星（红底金星），心屋=屋+圆（暖橙），夜航=月+星（深紫）。
不复制任何第三方资产，纯程序化绘制。
"""
import json
import os
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(__file__), "..", "Apps")
SIZE = 1024


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient_bg(c1, c2):
    img = Image.new("RGB", (SIZE, SIZE))
    d = ImageDraw.Draw(img)
    for y in range(SIZE):
        d.line([(0, y), (SIZE, y)], fill=lerp(c1, c2, y / SIZE))
    return img


def draw_star(d, cx, cy, r, color, points=5):
    import math
    pts = []
    for i in range(points * 2):
        ang = math.pi * i / points - math.pi / 2
        rad = r if i % 2 == 0 else r * 0.42
        pts.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
    d.polygon(pts, fill=color)


def icon_xingmu():
    img = gradient_bg((232, 68, 58), (120, 20, 18))
    d = ImageDraw.Draw(img)
    draw_star(d, SIZE // 2, SIZE // 2 - 60, 260, (255, 214, 92))
    for x, y, r in [(200, 220, 22), (820, 260, 26), (760, 780, 18), (240, 820, 16), (512, 160, 14)]:
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, 230))
    return img


def icon_xinwu():
    img = gradient_bg((245, 166, 35), (214, 108, 24))
    d = ImageDraw.Draw(img)
    # 屋顶
    d.polygon([(512, 200), (872, 520), (152, 520)], fill=(255, 240, 210))
    # 屋身
    d.rounded_rectangle([262, 520, 762, 860], radius=40, fill=(255, 248, 232))
    # 门 + 圆窗
    d.rounded_rectangle([432, 640, 592, 860], radius=24, fill=(214, 108, 24))
    d.ellipse([452, 560, 572, 680], fill=(120, 60, 10))
    return img


def icon_yehang():
    img = gradient_bg((44, 20, 80), (12, 8, 24))
    d = ImageDraw.Draw(img)
    # 月牙（两圆相减效果：亮圆上叠背景色圆）
    d.ellipse([312, 212, 712, 612], fill=(238, 226, 255))
    d.ellipse([452, 152, 802, 502], fill=lerp((44, 20, 80), (12, 8, 24), 0.25))
    for x, y, r in [(250, 700, 20), (330, 810, 14), (740, 680, 24), (820, 800, 14), (180, 560, 12)]:
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 214, 92))
    return img


ASSET_CONTENTS = json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2)
APPICON_CONTENTS = json.dumps({
    "images": [{"filename": "icon1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
    "info": {"author": "xcode", "version": 1},
}, indent=2)


def accent_colorset(hex_color):
    r, g, b = int(hex_color[1:3], 16), int(hex_color[3:5], 16), int(hex_color[5:7], 16)
    return json.dumps({
        "colors": [{
            "color": {
                "color-space": "srgb",
                "components": {"alpha": "1.000", "blue": f"0x{b:02X}", "green": f"0x{g:02X}", "red": f"0x{r:02X}"},
            },
            "idiom": "universal",
        }],
        "info": {"author": "xcode", "version": 1},
    }, indent=2)


PRODUCTS = [
    ("Xingmu", icon_xingmu, "#E8443A"),
    ("Xinwu", icon_xinwu, "#F5A623"),
    ("Yehang", icon_yehang, "#7C4DFF"),
]

for name, painter, accent in PRODUCTS:
    base = os.path.join(ROOT, name, "Assets.xcassets")
    icon_dir = os.path.join(base, "AppIcon.appiconset")
    accent_dir = os.path.join(base, "AccentColor.colorset")
    os.makedirs(icon_dir, exist_ok=True)
    os.makedirs(accent_dir, exist_ok=True)
    painter().save(os.path.join(icon_dir, "icon1024.png"))
    with open(os.path.join(base, "Contents.json"), "w") as f:
        f.write(ASSET_CONTENTS)
    with open(os.path.join(icon_dir, "Contents.json"), "w") as f:
        f.write(APPICON_CONTENTS)
    with open(os.path.join(accent_dir, "Contents.json"), "w") as f:
        f.write(accent_colorset(accent))
    print(f"[{name}] icon + accent -> {base}")

print("DONE")
