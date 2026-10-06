# -*- coding: utf-8 -*-
"""本机预检：被删掉的类型是否还有残留引用（CI 之前就该拦住的一类错）。

为什么需要（2026-10-03 实测浪费）：
  直播重写把 `LivePlayerScreen` / `LiveHealthIndex` 删了，别处仍在引用，
  本机 `check_syntax_bal`（只查括号）与 `check_swift_cross_module`（只查 FilmUI→FilmCore 成员）
  都查不出**同模块内的类型引用**，只能等 CI 编译才暴露 → 一轮 CI + 一次下载白费。

判据（精确、无白名单噪音）：
  1) 从 `git show HEAD:<file>` 收集 HEAD 里声明过的类型名（struct/class/enum/actor/protocol/extension 目标）。
  2) 从工作区收集现存的类型名。
  3) `被删 = HEAD有 且 现在没有` → 在**整个工作区源码**里搜这些名字：
     还有引用 = FAIL（列出文件:行）；零引用 = PASS。

用法：python scripts/check_removed_types.py [--negctl]
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GLOBS = ("Packages", "Apps")
DECL = re.compile(r"^\s*(?:public |internal |private |fileprivate |final |open )*"
                  r"(?:struct|class|enum|actor|protocol)\s+([A-Z][A-Za-z0-9_]*)", re.M)


def swift_files():
    out = []
    for g in GLOBS:
        for dirpath, _, files in os.walk(os.path.join(ROOT, g)):
            for f in files:
                if f.endswith(".swift"):
                    out.append(os.path.join(dirpath, f))
    return out


def declared_in(text):
    return set(DECL.findall(text))


def worktree_types():
    names = set()
    for p in swift_files():
        try:
            names |= declared_in(open(p, encoding="utf-8", errors="replace").read())
        except OSError:
            pass
    return names


def head_types(rev="HEAD"):
    """指定版本里所有 .swift 的声明（一次 git ls-tree + 逐个 show）。"""
    names = set()
    ls = subprocess.run(["git", "ls-tree", "-r", "--name-only", rev],
                        cwd=ROOT, capture_output=True, text=True)
    for path in (ls.stdout or "").splitlines():
        if not path.endswith(".swift"):
            continue
        blk = subprocess.run(["git", "show", "%s:%s" % (rev, path)],
                             cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                             errors="replace")
        names |= declared_in(blk.stdout or "")
    return names


def main():
    # --base <rev>：以哪个版本的类型清单为基准（默认 HEAD，也就是"上一版已发布的包"）
    # --at   <rev>：判定哪个版本的源码（默认工作区；传 rev = 对历史版本回放，用于鉴别力自证）
    base = "HEAD"
    at = None
    if "--base" in sys.argv:
        base = sys.argv[sys.argv.index("--base") + 1]
    if "--at" in sys.argv:
        at = sys.argv[sys.argv.index("--at") + 1]

    if at:
        names_at = set()
        hits = []
        ls = subprocess.run(["git", "ls-tree", "-r", "--name-only", at],
                            cwd=ROOT, capture_output=True, text=True)
        paths = [p for p in (ls.stdout or "").splitlines() if p.endswith(".swift")]
        base_names = set()
        lsb = subprocess.run(["git", "ls-tree", "-r", "--name-only", base],
                             cwd=ROOT, capture_output=True, text=True)
        for p in (lsb.stdout or "").splitlines():
            if not p.endswith(".swift"):
                continue
            blk = subprocess.run(["git", "show", "%s:%s" % (base, p)], cwd=ROOT,
                                 capture_output=True, text=True, encoding="utf-8", errors="replace")
            base_names |= declared_in(blk.stdout or "")
        for p in paths:
            blk = subprocess.run(["git", "show", "%s:%s" % (at, p)], cwd=ROOT,
                                 capture_output=True, text=True, encoding="utf-8", errors="replace")
            names_at |= declared_in(blk.stdout or "")
        removed = sorted(base_names - names_at)
        # 第二遍扫描引用（必须先扫完全部声明，否则先扫到的文件会把后面的类型当成"被删"）
        for p in paths:
            blk = subprocess.run(["git", "show", "%s:%s" % (at, p)], cwd=ROOT,
                                 capture_output=True, text=True, encoding="utf-8", errors="replace")
            txt = blk.stdout or ""
            for name in removed:
                for i, ln in enumerate(txt.splitlines(), 1):
                    if re.search(r"\b%s\b" % re.escape(name), ln) and not ln.strip().startswith("//"):
                        hits.append((name, "%s@%s:%d" % (p, at, i), ln.strip()[:90]))
        print("[预检@%s] 基准 %s 声明 %d｜该版现存 %d｜被删 %d"
              % (at, base, len(base_names), len(names_at), len(removed)))
        if hits:
            print("[预检] 残留引用 %d 处（例）：" % len(hits))
            for name, f, ln in hits[:6]:
                print("  %s  %s  %s" % (name, f, ln))
            print("RESULT: FAIL —— 判据有鉴别力（坏样本被抓住）")
            sys.exit(1)
        print("RESULT: PASS —— 该版无残留引用")
        return

    head = head_types(base)
    now = worktree_types()
    removed = sorted(head - now)
    print("[预检] HEAD 声明类型 %d 个｜现存 %d 个｜被删 %d 个" % (len(head), len(now), len(removed)))
    if not removed:
        print("RESULT: PASS —— 无被删类型")
        return
    hits = []
    for p in swift_files():
        txt = open(p, encoding="utf-8", errors="replace").read()
        lines = txt.splitlines()
        for name in removed:
            # 允许「同名重新声明」（现存类型里没有它，但文件里可能有注释提及）——只认代码引用
            for i, ln in enumerate(lines, 1):
                if re.search(r"\b%s\b" % re.escape(name), ln) and not ln.strip().startswith("//"):
                    hits.append((name, os.path.relpath(p, ROOT), i, ln.strip()[:100]))
    if not hits:
        print("[预检] 被删类型 %s 已无引用" % "、".join(removed[:8]))
        print("RESULT: PASS —— 无残留引用")
        return
    print("[预检] 残留引用 %d 处：" % len(hits))
    for name, f, i, ln in hits[:20]:
        print("  %s  %s:%d  %s" % (name, f, i, ln))
    print("RESULT: FAIL —— 被删类型仍被引用（CI 必挂，先修再推）")
    sys.exit(1)


main()
