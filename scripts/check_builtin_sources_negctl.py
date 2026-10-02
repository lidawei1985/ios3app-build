# -*- coding: utf-8 -*-
"""
负向对照（变异式）：把「违规」真的注入源码副本，判据必须 FAIL。

为什么重写（2026-09-27）：
  旧版从 git 取 `HEAD~1` 当"修复前代码"。修复一旦比 HEAD~1 更早，HEAD~1 就不再是坏代码，
  负向对照要么退化成"锚点找不到"的假检出，要么直接失效（旧版实测：HEAD~1 已含 builtinChip，
  新判据在它上面 PASS → 对照 FAIL）。**判据绑 git 历史必然腐烂**，故改为"就地变异"：
  每次都对**当前工作区**源码注入一条真实违规，验证判据仍能抓住 → 与历史无关，永远有鉴别力。

做法：复制当前 3 个源文件到 build/_negctl/ → 逐条注入违规 → 用 CHK_* 指给检查脚本 →
      基线（未变异）必须 PASS(0)，每条变异必须 FAIL(1)。

用法：python scripts/check_builtin_sources_negctl.py        （退出码 0 = 对照通过）
      python scripts/check_builtin_sources_negctl.py <ref>  （附加：仅报告该 ref 的结果，不作为门禁）
"""
import io
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = os.path.join(ROOT, "build", "_negctl")

SRC = {
    "CHK_SWIFT": "Packages/FilmCore/Sources/FilmCore/Config/DefaultSites.swift",
    "CHK_CONFIG": "Packages/FilmCore/Sources/FilmCore/Config/TVBoxConfig.swift",
    "CHK_SETTINGS": "Packages/FilmCore/Sources/FilmUI/Screens/SettingsView.swift",
}


def read(p):
    with io.open(p, "r", encoding="utf-8") as f:
        return f.read()


def write(p, s):
    with io.open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


def body_span(src, header_re):
    """返回 (start, end) —— 用与主检查相同的 `header ... \\n    }` 规则。"""
    m = re.search(header_re + r".*?\n    \}", src, re.S)
    return (m.start(), m.end()) if m else (-1, -1)


def sub_in_body(src, header_re, old, new, count=1):
    """在某个函数/属性体内做替换；找不到 → 抛错（防止变异静默失效）。"""
    a, b = body_span(src, header_re)
    if a < 0:
        raise RuntimeError("找不到函数体: %s" % header_re)
    seg = src[a:b]
    if old not in seg:
        raise RuntimeError("函数体内找不到待替换串 [%s]: %s" % (old, header_re))
    seg2 = seg.replace(old, new, count)
    return src[:a] + seg2 + src[b:]


def case_activate_into_chip(files):
    """违规①：把激活调用塞进线路胶囊（= 删除键被套进激活按钮的老毛病）。"""
    files = dict(files)
    files["CHK_SETTINGS"] = sub_in_body(
        files["CHK_SETTINGS"], r"private func builtinChip\(",
        "            delBtn { tvbox.removeBuiltinRepo(repo) }",
        "            tvbox.activateBuiltinRepo(repo)\n            delBtn { tvbox.removeBuiltinRepo(repo) }")
    return files


def case_tombstone_mix(files):
    """违规②：恢复入口改用点播源墓碑计数（串台）。"""
    files = dict(files)
    files["CHK_SETTINGS"] = sub_in_body(
        files["CHK_SETTINGS"], r"private var restoreBuiltinBtn",
        "tvbox.deletedBuiltinRepoURLs.count", "tvbox.deletedBuiltinSiteKeys.count")
    return files


def case_hide_whole_section(files):
    """违规③：内置线路区改回 `if !isEmpty` 整段隐藏（心屋看不到说明、成人端串台）。"""
    files = dict(files)
    files["CHK_SETTINGS"] = sub_in_body(
        files["CHK_SETTINGS"], r"private var builtinReposCard",
        "if tvbox.builtinRepoOptions.isEmpty {",
        "if !tvbox.builtinRepoOptions.isEmpty {")
    return files


CASES = [
    ("违规①激活调用混入线路胶囊", case_activate_into_chip),
    ("违规②恢复入口混用点播源墓碑", case_tombstone_mix),
    ("违规③内置线路区整段隐藏", case_hide_whole_section),
]


def run_check(files, tag):
    if os.path.isdir(TMP):
        shutil.rmtree(TMP)
    os.makedirs(TMP, exist_ok=True)
    env = dict(os.environ)
    for var, rel in SRC.items():
        p = os.path.join(TMP, tag + "_" + os.path.basename(rel))
        write(p, files[var])
        env[var] = p
    r = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "check_builtin_sources.py")],
                       cwd=ROOT, capture_output=True, text=True, errors="replace", env=env)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main():
    base = {var: read(os.path.join(ROOT, rel)) for var, rel in SRC.items()}
    bad = 0

    code, out = run_check(base, "base")
    ok = (code == 0)
    print("[基线] 未变异的当前源码 → 退出码 %d（期望 0）%s" % (code, "PASS" if ok else "FAIL"))
    if not ok:
        print(out[-1200:])
        bad += 1

    for label, fn in CASES:
        try:
            mutated = fn(base)
        except RuntimeError as e:
            print("[%s] 变异失败：%s → 判据锚点已漂移，必须修检查脚本" % (label, e))
            bad += 1
            continue
        code, out = run_check(mutated, "mut")
        caught = (code == 1)
        print("[%s] 注入违规 → 退出码 %d（期望 1）%s" % (label, code, "已检出" if caught else "漏检！"))
        if not caught:
            print(out[-1200:])
            bad += 1

    print("")
    if bad == 0:
        print("结论: PASS —— 判据有鉴别力（基线过 + %d 条注入违规全部被检出）" % len(CASES))
        return 0
    print("结论: FAIL —— 判据是哑的或已漂移（%d 项不达标），必须重写" % bad)
    return 1


if __name__ == "__main__":
    sys.exit(main())
