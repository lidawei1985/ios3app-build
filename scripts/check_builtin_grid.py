#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""内置源列表「双排网格」不变量（防回退成单排）。

用户钦定（2026-09-28）：「内置源的双排列表没做」→ 已改双排，此判据防再被改回单排。

不变量：
  INV-1  SiteBrowseView 源列表渲染使用 LazyVGrid
  INV-2  网格列数为 2（siteGridColumns 里两个 GridItem）
  INV-3  每个源用 siteChip 芯片渲染（毛玻璃 RoundedRectangle）
  INV-4  旧的单排写法（Button 内直接 HStack + listRowBackground）不得回归

退出码：全 PASS → 0；任一 FAIL → 1。--negctl 变异时期望判据抓到（自身 exit 0）。
"""
import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "Packages/FilmCore/Sources/FilmUI/Screens/SiteBrowseView.swift"


def main() -> int:
    if not SRC.exists():
        print(f"FAIL 源码不存在: {SRC}")
        return 1
    src = SRC.read_text(encoding="utf-8")
    negctl = "--negctl" in sys.argv
    if negctl:
        # 变异 1：把网格列数改成 1 列（= 复现"单排"）→ 触发 INV-2
        src = re.sub(
            r"private static let siteGridColumns = \[[^\]]*\]",
            "private static let siteGridColumns = [GridItem(.flexible())]",
            src, count=1, flags=re.S)
        # 变异 2：剥掉芯片的毛玻璃与圆角（= 复现"裸 HStack"）→ 触发 INV-4
        # 2026-09-30 加：INV-4 原判据只认旧写法 `ultraThinMaterial, in: RoundedRectangle`，
        # v21 全局毛玻璃根治把裸材质统一成 `filmGlass(...)` 后该判据恒 FAIL（判据与实现脱节）。
        src = src.replace(".filmGlass(cornerRadius: 12)", "")
        src = re.sub(r"\.overlay\(\s*\n\s*RoundedRectangle\(cornerRadius: 12, style: \.continuous\)[\s\S]*?\n\s*\)\s*\n",
                     "\n", src, count=1)

    cols = re.search(r"private static let siteGridColumns = \[(.*?)\]", src, re.S)
    col_src = cols.group(1) if cols else ""

    # siteChip 函数体（判据要盯着「芯片本身」而不是整个文件，避免别处一句 filmGlass 就给判 PASS）
    chip_m = re.search(r"private func siteChip\([^\n]*\n([\s\S]*?)\n    \}\n", src)
    chip_src = chip_m.group(1) if chip_m else ""

    results = []
    def inv(no, desc, ok, detail=""):
        results.append((no, desc, ok, detail))

    inv(1, "源列表使用 LazyVGrid", "LazyVGrid(columns:" in src)
    inv(2, "网格为 2 列", col_src.count("GridItem(") == 2,
        f"实际 {col_src.count('GridItem(')} 列")
    inv(3, "源用 siteChip 芯片渲染", "siteChip(s)" in src and "func siteChip(" in src)
    has_glass = ("filmGlass(" in chip_src) or ("ultraThinMaterial" in chip_src)
    has_round = "RoundedRectangle" in chip_src
    inv(4, "芯片带毛玻璃/圆角（不是裸 HStack）", has_glass and has_round,
        f"chip 内 filmGlass/ultraThin={has_glass} RoundedRectangle={has_round}")

    print(f"源: {SRC.name}")
    print("-" * 72)
    ok_all = True
    for no, desc, ok, detail in results:
        ok_all &= ok
        print(f"  INV-{no} {'PASS' if ok else 'FAIL'}  {desc}" + (f"  [{detail}]" if detail else ""))
    print("-" * 72)
    if negctl:
        bad = [r for r in results if not r[2]]
        print(f"变异对照：{len(bad)} 条 FAIL → " + ("判据有效 PASS" if bad else "判据失效 FAIL"))
        return 0 if bad else 1
    print("RESULT:", "PASS" if ok_all else "FAIL")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
