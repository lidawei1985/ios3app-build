#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""主视觉接缝判据（HeroSlide 横线防复发机检）。

背景（2026-09-23 用户实测反馈）：原型上看不出横线，真机上 hero 上下仍各有一条。
根因不是"渐变参数不对"，而是 hero 内部存在**实色边界**：
  ① ZStack 首层铺了 theme.background 实底 → 与页面取色背景不同色；
  ② 底部落地层落**实色**去凑页面底色 → 径向渐变几何随屏宽变，永远对不齐；
  ③ 顶部压暗层用纯黑 → 顶边与页面取色背景色差形成暗横带。
本脚本把"必须成立的结构不变量"固化成机检，防止以后有人为了"调色"把实色加回来。

判据（全过才 PASS）：
  INV-1  HeroSlide 的 ZStack 首层必须是 Color.clear（不得铺实色底）
  INV-2  groundLayer 首端必须是 .clear
  INV-3  groundLayer 末端必须是 .clear 且内部不得出现 deep.scaled(（2026-09-24 六改：
         落地实色「凑同色」在轮播换页时与页面径向渐变有取色时序差，真机像素取证
         y≈860 处 RGB(22,13,8) vs RGB(22,27,18) 50px 硬过渡 = 用户点名的横线。
         结构性无缝 = hero 底部零实色，页面背景是唯一色源，比"同色"更强）
  INV-4  topScrim 只允许 .black 低α（<=0.35）压暗，禁止取色实色（mid/deep 实色
         与页面光晕产生色相差，滑动中相邻页把色相差带到页面两侧）
  INV-5  fadeLayer 的 mask 末端（location: 1.00）必须是 .clear
  INV-6  hazeLayer 的 mask 首尾都必须是 .clear

用法：
  python scripts/check_hero_seam.py            # 正常检查
  python scripts/check_hero_seam.py --negctl   # 负向对照：故意注入实色落点，必须 FAIL
"""
import re
import sys
import pathlib

SRC = (pathlib.Path(__file__).resolve().parents[1]
       / "Packages" / "FilmCore" / "Sources" / "FilmUI" / "Screens" / "HomeView.swift")

NEGCTL = "--negctl" in sys.argv


def grab(text: str, name: str) -> str:
    """取 `private var <name>: some View { ... }` 的整块（按 4 空格缩进收尾）。"""
    m = re.search(r"private var %s: some View \{(.*?)\n    \}" % re.escape(name), text, re.S)
    return m.group(1) if m else ""


def first_layer(body: str) -> str:
    """ZStack 首层（跳过注释行后的第一个实际语句）。"""
    m = re.search(r"ZStack\(alignment: \.bottomLeading\) \{(.*?)\n        \}", body, re.S)
    if not m:
        return ""
    for line in m.group(1).splitlines():
        t = line.strip()
        if not t or t.startswith("//"):
            continue
        return t
    return ""


def main() -> int:
    text = SRC.read_text(encoding="utf-8")

    if NEGCTL:
        # 负向对照：把 groundLayer 末端改回旧实色落点（deep×0.66）→ INV-3 必须挂
        text = text.replace(
            ".init(color: .clear, location: 1.00)\n        ], startPoint: .top, endPoint: .bottom)\n    }\n\n    /// 顶部压暗",
            ".init(color: palette.deep.scaled(0.66).color, location: 1.00)\n        ], startPoint: .top, endPoint: .bottom)\n    }\n\n    /// 顶部压暗")
        print("[负向对照] 已人为把 groundLayer 末端改回实色落点 deep×0.66\n")

    slide = grab(text, "HeroSlide") or text          # HeroSlide 是 struct，退化为全文
    hero_body = text
    ground = grab(text, "groundLayer")
    scrim = grab(text, "topScrim")
    fade = grab(text, "fadeLayer")
    haze = grab(text, "hazeLayer")
    bgblock = grab(text, "heroBackground")
    layer1 = first_layer(hero_body)

    fails, checks = [], []

    def ck(inv, ok, detail):
        checks.append((inv, ok, detail))
        if not ok:
            fails.append(inv)

    ck("INV-1 ZStack 首层 = Color.clear",
       layer1.startswith("Color.clear"),
       "实际首层: %r" % (layer1[:60] or "<未找到>"))

    g_first = re.search(r"\.init\(color: \.clear, location: 0\.00\)", ground) is not None
    ck("INV-2 groundLayer 首端透明", g_first,
       "首透明=%s" % g_first)

    # INV-3 结构性无缝：groundLayer 末端透明 + 内部零实色落点（deep.scaled 是实色落地标志）
    g_tail_clear = re.search(r"\.init\(color: \.clear, location: 1\.00\)", ground) is not None
    g_solid = "deep.scaled(" in ground or "palette.deep" in ground
    ck("INV-3 groundLayer 末端透明且无实色落点", g_tail_clear and not g_solid,
       "末端透明=%s 实色落点=%s" % (g_tail_clear, g_solid or bool(g_tail_clear and "deep.scaled(" in ground)))

    # INV-4 topScrim 只许黑色低α压暗（<=0.35），禁止取色实色
    black_alphas = [float(x) for x in re.findall(r"\.black\.opacity\(([\d.]+)\)", scrim)]
    plain_black = ".black," in scrim or ".black]" in scrim
    has_tint_solid = ("palette.mid" in scrim or "palette.deep" in scrim) and ".opacity(" not in scrim
    ok4 = (bool(black_alphas) and max(black_alphas) <= 0.35 and not has_tint_solid) and not plain_black
    ck("INV-4 topScrim 黑色低α(<=0.35)且无取色实色", ok4,
       "黑α=%s 纯黑=%s 取色实色=%s" % (black_alphas or "<无>", plain_black, has_tint_solid))

    f_last = re.search(r"\.init\(color: \.clear, location: 1\.00\)", fade) is not None
    ck("INV-5 fadeLayer 末端透明", f_last, "末端透明=%s" % f_last)

    h_first = re.search(r"\.init\(color: \.clear, location: 0\.00\)", haze) is not None
    h_last = re.search(r"\.init\(color: \.clear, location: 1\.00\)", haze) is not None
    ck("INV-6 hazeLayer 首尾透明", h_first and h_last,
       "首透明=%s 末透明=%s" % (h_first, h_last))

    # INV-7 防雾化过大：haze 第一个非透明 stop 的位置必须 >= 0.55
    h_locs = [float(x) for x in re.findall(r"location: ([\d.]+)\)", haze)]
    solid_locs = [x for x in h_locs if x >= 0.55]
    ck("INV-7 起雾位置>=0.55", bool(solid_locs),
       "mask 位置=%s" % h_locs)

    # INV-8 防下面没变化：heroBackground 必须有实体取色底（不得退回 theme.background 当底色）
    ck("INV-8 整页底色=取色实体", "deep.scaled(" in bgblock and "theme.background" not in bgblock,
       "含取色底=%s 无theme.background底=%s" % ("deep.scaled(" in bgblock, "theme.background" not in bgblock))

    for inv, ok, detail in checks:
        print("  %-34s %-4s %s" % (inv, "PASS" if ok else "FAIL", detail))

    print()
    if fails:
        print("RESULT: FAIL — %s" % ", ".join(fails))
        print("（hero 内又出现实色边界了，接缝横线会复发）")
        return 1
    print("RESULT: PASS — hero 内部零实色边界，上下接缝结构上不可能出现色差横线")
    return 0


if __name__ == "__main__":
    sys.exit(main())
