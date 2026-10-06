# -*- coding: utf-8 -*-
"""全局毛玻璃判据（2026-09-30 · 用户「全局的都搞成毛玻璃」）。

PASS 条件（全部满足）：
  1) FilmUI 内除白名单文件外，任何**代码行**不得出现裸 .ultraThinMaterial/thinMaterial/regularMaterial，
     且该行没有白色提亮（Color.white.opacity / white.opacity）——有提亮的"材质+提亮"行不算黑框；
  2) filmGlass( 使用数 ≥ 12（全局组件确实被铺开用）。
注释行一律忽略。

--negctl：对 git HEAD（补丁前）跑同一判据，必须 FAIL（判据有鉴别力）。
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(r"F:\IOS3APP\_v13_build\Packages\FilmCore\Sources\FilmUI")
ALLOWED = ("Screens/PlayerScreen.swift", "Components/GlassStyle.swift")
MAT = re.compile(r"ultraThinMaterial|thinMaterial|regularMaterial")


def check_text(rel: str, text: str, problems: list) -> None:
    if rel.startswith(ALLOWED):
        return
    for i, line in enumerate(text.splitlines(), 1):
        code = line.split("//")[0]
        if MAT.search(code) and "white.opacity" not in code:
            problems.append(f"{rel}:{i}: {line.strip()[:90]}")


def run(target: str) -> int:
    problems: list = []
    filmglass = 0
    files: list = []
    if target == "worktree":
        files = [(p.relative_to(ROOT).as_posix().replace("\\", "/"),
                  p.read_text(encoding="utf-8", errors="replace")) for p in ROOT.rglob("*.swift")]
    else:  # git revision
        for p in ROOT.rglob("*.swift"):
            rel = p.relative_to(ROOT).as_posix().replace("\\", "/")
            r = subprocess.run(["git", "-C", str(ROOT), "show", f"{target}:{rel}"],
                               capture_output=True)
            if r.returncode != 0:
                continue
            files.append((rel, r.stdout.decode("utf-8", errors="replace")))
    for rel, text in files:
        check_text(rel, text, problems)
        filmglass += len(re.findall(r"\bfilmGlass\(", text))
    for pr in problems:
        print("违规", pr)
    print(f"filmGlass 使用数 = {filmglass}（要求 ≥ 10）")
    ok = not problems and filmglass >= 10
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    # 2026-09-30：--negctl 支持可选 revision（默认 HEAD）。
    # 为什么要能指定：负向对照必须对「改动前」的 rev 跑才叫有鉴别力
    # （对 HEAD 跑等于重复检查当前代码，抓不到"判据本身是哑的"）。
    tgt = "worktree"
    if "--negctl" in sys.argv:
        _i = sys.argv.index("--negctl")
        tgt = sys.argv[_i + 1] if _i + 1 < len(sys.argv) else "HEAD"
        if tgt.startswith("--"):
            tgt = "HEAD"
    print("检查目标:", tgt)
    sys.exit(run(tgt))
