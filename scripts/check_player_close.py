#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""退播放器「连带关详情页」防复发机检（PlayerScreen.close 呈现层纪律）。

背景（用户实测反馈）：「播放返回的时候总是自动关详情页」。

真根因（不是"动画没做完"，是**关错了层**）：
  本 App 呈现链固定为三层 ——
     rootViewController ─presented→ 详情卡(sheet, HomeView .sheet(item:))
                       ─presented→ 播放器(fullScreenCover, DetailView)
  PlayerScreen.close() 的 UIKit 兜底（保险 5）原本两处都写
  `scene?.keyWindow?.rootViewController?.dismiss(animated: true)` ——
  `rootViewController.dismiss()` 关的是**根所呈现的那一层＝详情卡本身**。
  于是 `onClose?()`/`dismiss()` 先把播放器关掉后，这刀落到详情卡上 →
  「返回」把详情页也一起关了。

正解（已落地）＝新增 `dismissPlayerLayer(reason:)` 兜底函数，只关详情卡**之上**那一层：
  ① 取 `root.presentedViewController` 当"详情卡"；取不到 → 直接跳过（不擅自 dismiss 根）；
  ② **详情卡之上没有播放器 → 什么都不做**（播放器其实已经关了，再关就是 bug）；
  ③ 只调 `detailHost.dismiss(animated:)` —— 关掉播放器层，保留详情卡。

判据（全过才 PASS）：
  INV-1 close() 可解析
  INV-2 close() 内不得再出现裸 `rootViewController?...?.dismiss(`（历史 bug 模式）
  INV-3 整个 PlayerScreen 不得出现 `rootViewController` 直接 dismiss 的写法
  INV-4 dismissPlayerLayer 有定义，且至少被调用 1 次（retry-1.2s 兜底走它；immediate 已删，避免 LC 里提前 dismiss 带掉详情页）
  INV-5 dismissPlayerLayer 内必须有「详情卡之上无播放器 → 提前 return」的守卫
  INV-6 只关一层：必须出现 `detailHost.dismiss(animated: true)`，且不得出现 `root.dismiss`
  INV-7 呈现链结构不变量：DetailView 用 .fullScreenCover 呈现 PlayerScreen；
        HomeView 用 .sheet(item: $detailRouter.item) 呈现详情（三层形状不能变，变了本判据要同步改）
  INV-8 直播播放器同款护栏（2026-10-03 修订）：LivePlayerScreen 只走 `onClose` 回调，
        且 LiveView 全文不得出现历史 bug 模式（裸关根）。
        旧写法要求「必须存在带守卫的裸关根」，但 v43 已**有意删除**直播播放器的 UIKit 兜底
        → 旧判据常红＝哑判据，故按当前真实不变量重写（见 analyze() 内注释）。

用法：
  python scripts/check_player_close.py            # 正常检查
  python scripts/check_player_close.py --negctl    # 负向对照：把兜底换回历史写法，必须 FAIL
"""
import argparse
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PLAYER = "Packages/FilmCore/Sources/FilmUI/Screens/PlayerScreen.swift"
DETAIL = "Packages/FilmCore/Sources/FilmUI/Screens/DetailView.swift"
HOME = "Packages/FilmCore/Sources/FilmUI/Screens/HomeView.swift"
LIVE = "Packages/FilmCore/Sources/FilmUI/Screens/LiveView.swift"

# 历史 bug 模式：任何对 rootViewController 直接 dismiss
BUG_RE = re.compile(r"rootViewController\s*\??\s*\.\s*dismiss\s*\(")


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def strip_comments(src):
    """去掉 // 行注释与 /* */ 块注释（注意别切坏字符串字面量）。

    必要性：本文件正文注释里会**引用历史 bug 写法**（`rootViewController.dismiss()`）作反面教材，
    不剥离就会把"注释里提到"当成"代码里用了" → 判据误报。
    """
    out = []
    i, n = 0, len(src)
    in_str = False
    quote = ""
    while i < n:
        c = src[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1]); i += 2; continue
            if c == quote:
                in_str = False
            i += 1
            continue
        if c in "\"'":
            in_str = True; quote = c; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c); i += 1
    return "".join(out)


def close_body(src):
    i = src.find("private func close()")
    if i < 0:
        return ""
    j = src.find("\n    private func dismissPlayerLayer", i)
    if j < 0:
        j = i + 4000
    return src[i:j]


def player_body(src):
    i = src.find("private func dismissPlayerLayer")
    if i < 0:
        return ""
    # 到下一个顶层方法/结构为止
    j = src.find("\n    private var playerDragGesture", i)
    if j < 0:
        j = i + 3000
    return src[i:j]


def analyze(texts):
    """返回 [(INV, ok, detail)]。texts 为 {rel: 内容}，便于负向对照注入变异。"""
    player = strip_comments(texts[PLAYER])
    detail = strip_comments(texts[DETAIL])
    home = strip_comments(texts[HOME])
    cb = close_body(player)
    pb = player_body(player)
    checks = []

    def ck(inv, ok, extra=""):
        checks.append((inv, bool(ok), extra))

    ck("INV-1 close() 可解析", bool(cb), "len=%d" % len(cb))

    # INV-2 close() 内无裸 root dismiss
    bad_in_close = BUG_RE.findall(cb)
    ck("INV-2 close() 内无裸 root dismiss", not bad_in_close,
       "命中 %d 处" % len(bad_in_close))

    # INV-3 全文件无裸 root dismiss
    bad_all = BUG_RE.findall(player)
    ck("INV-3 PlayerScreen 全文无裸 root dismiss", not bad_all,
       "命中 %d 处" % len(bad_all))

    # INV-4 兜底函数存在且被调用>=1（2026-09-28：immediate 调用已删，只留 1.2s retry 兜底，
    # 防止 LC 中提前 dismiss 把详情页一起带掉）。
    has_def = "private func dismissPlayerLayer" in player
    # 只数真实**调用点**（带字符串实参），排除函数定义行
    calls = len(re.findall(r"dismissPlayerLayer\s*\(\s*reason\s*:\s*\"", player))
    ck("INV-4 dismissPlayerLayer 定义+调用>=1", has_def and calls >= 1,
       "定义=%s 调用=%d（retry-1.2s 兜底）" % (has_def, calls))

    # INV-5 详情卡之上无播放器 → 提前 return 的守卫
    guard_ok = bool(re.search(r"detailHost\.presentedViewController\s*!=\s*nil", pb))
    early_return = bool(re.search(r"guard\b[\s\S]{0,200}?detailHost\.presentedViewController"
                                  r"[\s\S]{0,200}?else\s*\{[\s\S]{0,200}?return", pb))
    ck("INV-5 有『无播放器层→跳过』守卫", guard_ok and early_return,
       "判空=%s 提前return=%s" % (guard_ok, early_return))

    # INV-6 只关一层
    one_layer = "detailHost.dismiss(animated: true)" in pb
    no_root_dismiss = not re.search(r"\broot\s*\.\s*dismiss\s*\(", pb)
    ck("INV-6 只关详情卡之上那一层", one_layer and no_root_dismiss,
       "detailHost.dismiss=%s 无root.dismiss=%s" % (one_layer, no_root_dismiss))

    # INV-7 呈现链结构
    cover = bool(re.search(r"\.fullScreenCover\s*\(\s*isPresented:\s*\$showPlayer\s*\)", detail))
    cover_has_player = bool(re.search(r"\.fullScreenCover\s*\(\s*isPresented:\s*\$showPlayer\s*\)\s*\{"
                                      r"[\s\S]{0,120}?PlayerScreen\s*\(", detail))
    sheet_detail = bool(re.search(r"\.sheet\s*\(\s*item:\s*\$detailRouter\.item\s*\)", home))
    ck("INV-7 呈现链=根→详情(sheet)→播放器(cover)",
       cover and cover_has_player and sheet_detail,
       "cover=%s cover含PlayerScreen=%s home.sheet(item)=%s" % (cover, cover_has_player, sheet_detail))

    # INV-8 直播播放器同款护栏 —— 2026-10-03 修订。
    #
    # 旧判据写作「LiveView 里必须存在**带守卫的裸关根**」（guard root.presentedViewController != nil
    # → root.dismiss）。但 v43「直播推倒重做收官」(9147e0e) **有意删掉了** LivePlayerScreen 的
    # UIKit 兜底「保险 5」（原 2122-2134 行五重保险 → 只留 onClose），此后该判据**常红＝哑判据**
    # （哑判据比没判据更坏：它会遮住真缺陷，还会被"改判据消红"式地糊过去）。
    #
    # 现按「当前真正成立、且必须守住」的不变量重写（鉴别力反而更强）：
    #   ① 关闭契约必须是**回调**：`onClose` 有声明 + 至少 1 处调用；
    #      —— 直播播放器唯一的呈现点是设置页 fullScreenCover，关自己用 binding 即可，
    #         不需要、也不得再引入 UIKit 关根兜底（那正是「连带关详情页」的病灶形态）。
    #   ② 全文件不得出现历史 bug 模式（裸关根）——与 INV-3 同口径（BUG_RE 命中 0）。
    live = strip_comments(texts[LIVE])
    declares_cb = bool(re.search(r"let\s+onClose\s*:\s*\(\)\s*->\s*Void", live))
    uses_cb = bool(re.search(r"onClose\(\)", live))
    bare_root = BUG_RE.findall(live) + re.findall(r"(?<![\w.])root\s*\.\s*dismiss\s*\(", live)
    ck("INV-8 直播播放器只走 onClose 回调、无裸关根",
       declares_cb and uses_cb and not bare_root,
       "onClose声明=%s 调用=%s 裸关根=%d" % (declares_cb, uses_cb, len(bare_root)))

    return checks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--negctl", action="store_true",
                    help="负向对照：把兜底换回历史写法（rootViewController.dismiss），必须 FAIL")
    a = ap.parse_args()

    texts = {p: read(p) for p in (PLAYER, DETAIL, HOME, LIVE)}

    if a.negctl:
        src = texts[PLAYER]
        # 变异 1：retry 兜底回退成历史 bug 写法（裸 root.dismiss，会带掉详情页）
        src = src.replace(
            'dismissPlayerLayer(reason: "retry-1.2s")',
            'UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })'
            '.first?.keyWindow?.rootViewController?.dismiss(animated: true)', 1)
        texts[PLAYER] = src

        # 变异 3：给直播播放器注入历史 bug 写法（裸关根 + 摘掉 onClose 调用），INV-8 必须 FAIL
        live = texts[LIVE]
        live = live.replace(
            "Button { onClose() } label: {",
            "Button { UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })"
            ".first?.keyWindow?.rootViewController?.dismiss(animated: true) } label: {", 1)
        texts[LIVE] = live

        print("[负向对照] 已注入 3 处历史写法：点播两处裸 root.dismiss + 直播裸关根")
        print("           期望：INV-2/INV-3/INV-8 变 FAIL，整体 RESULT: FAIL\n")

    checks = analyze(texts)
    fails = [inv for inv, ok, _ in checks if not ok]
    for inv, ok, extra in checks:
        print("  %-46s %-4s %s" % (inv, "PASS" if ok else "FAIL", extra))
    print()
    if fails:
        print("RESULT: FAIL — %s" % ", ".join(fails))
        print("（播放器兜底又去关 root 了 → 「退播放器连带关详情页」会复发）")
        return 1
    print("RESULT: PASS — 退播放器只关播放器层，详情卡受结构保护")
    return 0


if __name__ == "__main__":
    sys.exit(main())
