# -*- coding: utf-8 -*-
"""首页视觉改版的静态自检（Swift 在 Windows 上编译不了，先用纯文本守一层）：
1) 括号/花括号配平（剥掉注释与字符串后统计）
2) 我这次新引入的符号是否都在本仓定义（防「类型不存在」类编译错）
用法：python scripts/check_home_visual.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "Packages")

TARGETS = [
    "Packages/FilmCore/Sources/FilmUI/Screens/HomeView.swift",
    "Packages/FilmCore/Sources/FilmUI/Screens/TVSeriesView.swift",
    "Packages/FilmCore/Sources/FilmUI/Screens/DetailView.swift",
    "Packages/FilmCore/Sources/FilmUI/Components/HeroTint.swift",
]

# 本次改版依赖的符号（必须能在本仓找到定义，否则 CI 必挂）
SYMBOLS = {
    "struct HeroSlide": "主视觉单帧（新）",
    "struct HeroCarousel": "主视觉轮播（改）",
    "struct HeroPalette": "取色调色板",
    "final class HeroTintStore": "取色缓存",
    "struct SearchView": "搜索页",
    "struct PosterImage": "海报组件",
    "enum HomePolicy": "首页选片口径",
    "struct FeedItem": "片源条目",
    "struct ProductProfile": "产品配置",
}


def strip_code(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"//[^\n]*", "", s)
    s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)
    return s


def main() -> int:
    bad = 0
    print("── 1) 括号配平 ──")
    for rel in TARGETS:
        p = os.path.join(ROOT, rel)
        if not os.path.exists(p):
            print(f"  [MISS] {rel}")
            bad += 1
            continue
        s = strip_code(open(p, encoding="utf-8").read())
        b = {k: s.count(a) - s.count(z) for k, (a, z) in
             {"()": ("(", ")"), "{}": ("{", "}"), "[]": ("[", "]")}.items()}
        ok = all(v == 0 for v in b.values())
        print(f"  {'[OK]  ' if ok else '[FAIL]'} {os.path.basename(rel):22s} {b}")
        if not ok:
            bad += 1

    print("── 2) 新依赖符号是否存在于本仓 ──")
    blob = []
    for dirpath, _, files in os.walk(PKG):
        for f in files:
            if f.endswith(".swift"):
                blob.append(open(os.path.join(dirpath, f), encoding="utf-8", errors="ignore").read())
    blob = "\n".join(blob)
    for sig, desc in SYMBOLS.items():
        hit = sig in blob
        print(f"  {'[OK]  ' if hit else '[FAIL]'} {sig:28s} {desc}")
        if not hit:
            bad += 1

    print()
    print("RESULT: " + ("PASS — 首页视觉改版静态自检通过" if bad == 0 else f"FAIL — {bad} 项不通过"))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
