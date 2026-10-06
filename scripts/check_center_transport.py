#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""居中控制行布局不变量（防「曲解用户意思」复发）。

用户原话（2026-09-28）：
  「中间放上一集、暂停播放、下一集，下面放快进快退10S」

历史事故（本判据要防的）：
  曾自作主张按「电影 vs 剧集」切形态 —— 剧集居中=上一集/暂停/下一集，
  电影居中=快退10/暂停/快进10（把 ±10s 又挪回中间）。用户原话是统一布局，
  电影无集可切 → 两侧应当置灰，而不是换形态。

不变量：
  INV-1  centerTransportRow 函数体存在
  INV-2  函数体内含 playPrev() 调用（上一集）
  INV-3  函数体内含 model.togglePlayPause()（暂停/播放）
  INV-4  函数体内含 playNext() 调用（下一集）
  INV-5  函数体内**不得**出现 model.skip(  （±10s 不许回到居中）
  INV-6  ±10s 图标只允许出现在 centerTransportRow **之后**（=底栏）
  INV-7  不得再出现 hasEpisodeList 分支切形态（函数体内无 `if model.hasEpisodeList {`）

退出码：全部 PASS → 0；任一 FAIL → 1。
"""
import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "Packages/FilmCore/Sources/FilmUI/Screens/PlayerScreen.swift"


def center_body(src: str) -> str:
    """截取 centerTransportRow 计算属性的函数体（到下一个 private var / func / MARK 为止）。"""
    m = re.search(r"private var centerTransportRow: some View \{", src)
    if not m:
        return ""
    start = m.end()
    rest = src[start:]
    stop = re.search(r"\n    (?:/// |// MARK|private (?:var|func)|public func)", rest)
    return rest[: stop.start()] if stop else rest


def main() -> int:
    if not SRC.exists():
        print(f"FAIL 源码不存在: {SRC}")
        return 1
    src = SRC.read_text(encoding="utf-8")
    negctl = "--negctl" in sys.argv
    if negctl:
        # 变异：把 ±10s 挪回居中（= 复现被用户否掉的那版）→ 判据必须抓到
        key = "private var centerTransportRow: some View {\n        HStack(spacing: 56) {"
        mut = key + '\n            Button { model.skip(-10) } label: { Image(systemName: "gobackward.10") }'
        if key in src:
            src = src.replace(key, mut, 1)
    body = center_body(src)
    results = []

    def inv(no, desc, ok, detail=""):
        results.append((no, desc, ok, detail))

    inv(1, "centerTransportRow 函数体存在", bool(body.strip()),
        f"{len(body)} 字符")
    inv(2, "居中含 playPrev()（上一集）", "playPrev()" in body)
    inv(3, "居中含 togglePlayPause()（暂停/播放）", "model.togglePlayPause()" in body)
    inv(4, "居中含 playNext()（下一集）", "playNext()" in body)
    inv(5, "居中**不含** model.skip(（±10s 不得回中间）",
        "model.skip(" not in body)
    inv(6, "居中含 ±10s 图标（应只在底栏）",
        ("gobackward.10" not in body and "goforward.10" not in body)
        and (("gobackward.10" in src and src.index("gobackward.10") > src.index("centerTransportRow"))
             or "gobackward.10" not in src))
    inv(7, "不再按 hasEpisodeList 切形态", "if model.hasEpisodeList {" not in body)

    print(f"源: {SRC.name}  居中控件块 {len(body)} 字符")
    print("-" * 72)
    ok_all = True
    for no, desc, ok, detail in results:
        ok_all &= ok
        print(f"  INV-{no} {'PASS' if ok else 'FAIL'}  {desc}" + (f"  [{detail}]" if detail else ""))
    print("-" * 72)
    if negctl:
        # 变异对照：期望判据抓到（至少 INV-5 与 INV-6 双 FAIL）→ 判据有鉴别力时自身 exit 0
        bad = [r for r in results if not r[2]]
        print(f"变异对照：{len(bad)} 条 FAIL → " + ("判据有效 PASS" if len(bad) >= 2 else "判据失效 FAIL"))
        print("RESULT:", "PASS" if len(bad) >= 2 else "FAIL")
        return 0 if len(bad) >= 2 else 1
    print("RESULT:", "PASS" if ok_all else "FAIL")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
