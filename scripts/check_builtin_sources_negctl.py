# -*- coding: utf-8 -*-
"""
负向对照：拿**修复前**的源码跑不变量检查，必须 FAIL。

为什么必须做：判据若在旧代码上也能 PASS，就是"哑的"（恒真）—— 等于没检。
用户纪律「标哑判据」明确要求：判据必须随代码真实变化而变化。

做法：从 git 取 HEAD 之前那次提交（即修复前）的三个文件到临时目录 →
      用 CHK_* 环境变量指给检查脚本 → 期望退出码 1。

用法：python scripts/check_builtin_sources_negctl.py [git_ref]
      默认 git_ref = HEAD~1（修复前的那次提交）
"""
import io
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = sys.argv[1] if len(sys.argv) > 1 else "HEAD~1"
TMP = os.path.join(ROOT, "build", "_negctl")

TARGETS = {
    "CHK_SWIFT": "Packages/FilmCore/Sources/FilmCore/Config/DefaultSites.swift",
    "CHK_CONFIG": "Packages/FilmCore/Sources/FilmCore/Config/TVBoxConfig.swift",
    "CHK_SETTINGS": "Packages/FilmCore/Sources/FilmUI/Screens/SettingsView.swift",
}

# 修复前必然缺失 / 必然违规的项（用来确认"旧代码确实被检出"）
# 注意：这些不是断言本身，只是给输出做可读性说明。
EXPECT_FAIL_KEYS = [
    "deletedBuiltinSiteKeys", "deletedBuiltinRepoURLs", "restoreBuiltinRepos",
]


def main():
    if os.path.isdir(TMP):
        shutil.rmtree(TMP)
    os.makedirs(TMP, exist_ok=True)

    env = dict(os.environ)
    for var, rel in TARGETS.items():
        r = subprocess.run(["git", "show", "%s:%s" % (REF, rel)], cwd=ROOT, capture_output=True)
        if r.returncode != 0:
            print("取旧版失败 %s: %s" % (rel, r.stderr.decode("utf-8", "replace")[:200]))
            return 2
        p = os.path.join(TMP, os.path.basename(rel))
        with io.open(p, "wb") as f:
            f.write(r.stdout)
        env[var] = p

    r = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "check_builtin_sources.py")],
                       cwd=ROOT, capture_output=True, text=True, errors="replace", env=env)
    out = (r.stdout or "") + (r.stderr or "")
    print(out)
    hits = [k for k in EXPECT_FAIL_KEYS if k in out]
    print("---- 负向对照（%s）退出码 = %d ，期望 1 ----" % (REF, r.returncode))
    print("修复前特征项命中: %s" % (", ".join(hits) if hits else "无（可疑！）"))
    ok = (r.returncode == 1)
    print("结论: " + ("PASS —— 判据有鉴别力（旧代码被检出 FAIL）" if ok
                      else "FAIL —— 判据是哑的（旧代码也 PASS），必须重写"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
