# -*- coding: utf-8 -*-
"""分区口径判据（2026-09-30 用户钦定：「星幕可以有，不止夜航；心屋不行」）。

PASS 条件（源码级，可反证）：
  1) NavPolicy.allowsCategory：成人分类 = `mode != "child"`（星幕/夜航放行，心屋拦截）；
  2) NavPolicy.allowsItem default 分支：星幕不再按片名挡（含 2026-09-30 标记注释）；
  3) DefaultSites.sources(for:)：仅 child 不挂成人源；
  4) FilmCoreTests 的 child 隔离断言仍在（isolationReject(adult, mode:"child") 非 nil）。
--negctl：对 git HEAD（旧口径「只有夜航」）跑同一判据，必须 FAIL。
"""
import re
import subprocess
import sys
from pathlib import Path

PKG = Path(r"F:\IOS3APP\_v13_build\Packages\FilmCore")

REQUIRED = [
    ("Sources/FilmCore/Config/NavPolicy.swift",
     r'if isAdultCategory\(n\) \{ return mode != "child" \}'),
    ("Sources/FilmCore/Config/NavPolicy.swift",
     r"2026-09-30 用户钦定：星幕（normal）可以有成人内容"),
    # 3) 心屋源池级隔离（2026-10-01 收紧）：child 走**独立分支**且只挂纯影视源，
    #    混合源（索倪，61 分类里 55+ 类成人）与成人源物理不进心屋池 —— 不再靠浏览层闸门兜底。
    ("Sources/FilmCore/Config/DefaultSites.swift",
     r'if mode == "child" \{'),
    ("Sources/FilmCore/Config/DefaultSites.swift",
     r'2026-10-01 用户钦定改口径'),
    ("Tests/FilmCoreTests/FilmCoreTests.swift",
     r'isolationReject\(adult, mode: "child"\)'),
    ("Tests/FilmCoreTests/FilmCoreTests.swift",
     r'isolationReject\(qingse, mode: "child"\)'),
]


def run(target: str) -> int:
    ok = True
    for rel, pat in REQUIRED:
        if target == "worktree":
            text = (PKG / rel).read_text(encoding="utf-8", errors="replace")
        else:
            r = subprocess.run(["git", "-C", str(PKG), "show", f"{target}:Packages/FilmCore/{rel}"],
                               capture_output=True)
            if r.returncode != 0:
                print(f"MISSING {rel}（{target} 无此文件）")
                ok = False
                continue
            text = r.stdout.decode("utf-8", errors="replace")
        hit = re.search(pat, text)
        print(("OK  " if hit else "FAIL"), rel, "←", pat[:58])
        ok = ok and bool(hit)
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    # 2026-09-30：--negctl 支持可选 revision（默认 HEAD）；负向对照须对「改动前」rev 跑。
    tgt = "worktree"
    if "--negctl" in sys.argv:
        _i = sys.argv.index("--negctl")
        tgt = sys.argv[_i + 1] if _i + 1 < len(sys.argv) else "HEAD"
        if tgt.startswith("--"):
            tgt = "HEAD"
    print("检查目标:", tgt)
    sys.exit(run(tgt))
