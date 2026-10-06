#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_update_channel.py — App 内一键更新链路机检（2026-10-04 修「LC不可用」后加）。

背景：2026-10-03 用户报「LC不可用」。根因三处：
  ① Info.plist 未声明 LSApplicationQueriesSchemes → canOpenURL("livecontainer://") 恒 false，
     「立即更新」永远掉进 GitHub 网页兜底（国内手机网络打不开）；
  ② 心屋跑在第二个 LC 容器实例，scheme 必须 livecontainer2（旧代码两 App 都硬编码 livecontainer）；
  ③ 裸 GitHub 直链国内常超时（网页端 2026-10-01 实测），App 内必须镜像竞速。

判据全部行级锚定；任何一条不满足 → EXIT 1。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
fails = []


def load(rel: str) -> str:
    p = ROOT / rel
    if not p.exists():
        fails.append(f"[缺失] {rel} 不存在")
        return ""
    return p.read_text(encoding="utf-8", errors="replace")


def check(name: str, text: str, pattern: str, rel: str):
    if not text:
        return
    if not re.search(pattern, text, re.M):
        fails.append(f"[FAIL] {name} —— {rel} 中找不到 /{pattern}/")


# ① 两个 target 的 Info 都要声明 LSApplicationQueriesSchemes（project.yml）
py = load("project.yml")
check("project.yml 声明 LSApplicationQueriesSchemes（两处：星幕+心屋）",
      py, r"LSApplicationQueriesSchemes:\s*\[livecontainer,\s*livecontainer2\]", "project.yml")
if py and len(re.findall(r"LSApplicationQueriesSchemes", py)) < 2:
    fails.append("[FAIL] project.yml 里 LSApplicationQueriesSchemes 只出现 "
                 f"{len(re.findall(r'LSApplicationQueriesSchemes', py))} 处（需两个 target 各一处）")

# ② UpdateChecker：容器 scheme 可配置 + 镜像竞速 + 兜底指向 pages（不是 github.com）
uc = load("Packages/FilmCore/Sources/FilmUI/Components/UpdateChecker.swift")
check("UpdateChecker 有 lcScheme 可配置字段", uc, r"public var lcScheme:\s*String", "UpdateChecker.swift")
check("UpdateChecker 用 lcScheme 拼 URL（不能硬编码 livecontainer://）",
      uc, r"\\\(lcScheme\)://install", "UpdateChecker.swift")
check("UpdateChecker 有镜像竞速 fastestDirectURL", uc, r"func fastestDirectURL", "UpdateChecker.swift")
check("镜像竞速覆盖 gh-proxy / ghproxy.net / ghfast 三通道",
      uc, r"gh-proxy\.com[\s\S]*ghproxy\.net[\s\S]*ghfast\.top", "UpdateChecker.swift")
check("竞速探测用 Range 小请求（不整包下载）", uc, r"bytes=0-1023", "UpdateChecker.swift")
check("LC 没装时兜底开 pages 指南页（pagesBase），不许再开 github.com Release 页",
      uc, r"pagesBase \+ \"/\"", "UpdateChecker.swift")
if re.search(r"releases/tag/", uc):
    fails.append("[FAIL] UpdateChecker 仍残留 github.com releases/tag 兜底（国内打不开）")

# ②b 2026-10-07 新增 P0 回归门禁：「官方直链」绝不许进竞速候选
# 病根：官方直链是 github.com → 302 → Azure blob，**首字节快、吞吐极慢**（实测 213~466 B/s），
# 一旦赢竞速就会卡死（34MB 要跑 3 小时+）。网页端 pickMirror() 一直是「官方直链垫底不参与选优」，
# App 端却把它塞进了 mirrors 数组 —— 这条门禁就是钉死这个口子。
_m = re.search(r"let mirrors:\s*\[String\]\s*=\s*\[([\s\S]*?)\]", uc)
if not _m:
    fails.append("[FAIL] UpdateChecker 找不到 `let mirrors: [String] = [...]` 竞速候选数组")
else:
    _body = _m.group(1)
    _urls = re.findall(r'"(https?://[^"]+)"', _body)
    if re.search(r'^\s*""\s*,?\s*$', _body, re.M):
        fails.append("[FAIL] 竞速候选里出现空串 \"\"（= 官方直链）——"
                     "官方直链首字节快、吞吐极慢，会赢竞速然后卡死，必须剔除、只作兜底")
    if len(_urls) != 3:
        fails.append(f"[FAIL] 竞速候选应为 3 个镜像站，实际 {len(_urls)} 个：{_urls}")
    if "gh-proxy.com" not in _body or "ghproxy.net" not in _body or "ghfast.top" not in _body:
        fails.append("[FAIL] 竞速候选缺少三个镜像站之一（gh-proxy.com / ghproxy.net / ghfast.top）")
if not re.search(r"return fastest \?\? rel", uc):
    fails.append("[FAIL] 竞速全挂时未回退官方直链（应 `return fastest ?? rel`，永不返回 nil）")

# ③ 两个 App 入口各自声明容器 scheme
xm = load("Apps/Xingmu/XingmuApp.swift")
xw = load("Apps/Xinwu/XinwuApp.swift")
check("星幕入口声明 lcScheme = livecontainer", xm,
      r'lcScheme\s*=\s*"livecontainer"', "XingmuApp.swift")
check("心屋入口声明 lcScheme = livecontainer2", xw,
      r'lcScheme\s*=\s*"livecontainer2"', "XinwuApp.swift")

if fails:
    print("\n".join(fails))
    print(f"\nRESULT: FAIL（{len(fails)} 条）")
    sys.exit(1)
print("RESULT: PASS — 更新链路机检 13 条全过（含 2026-10-07 新增：官方直链不得进竞速）")
