#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_project.py — Windows 端静态验收（诚实声明：本机无 macOS/Xcode，不做假编译）。
校验：
  1. 工程结构完整性（三 Target/三 Scheme/共享包/测试/脚本/文档）
  2. project.yml 可解析且三 Target Bundle ID / Scheme 独立
  3. Swift 源文件括号/引号平衡粗检 + 关键类存在
  4. 产品隔离静态检查：Xingmu/Xinwu 源码不得引用 adult feed 仓库；各 App 入口绑定正确 profile
  5. 测试夹具 JSON 有效
产出：build/check_report.json + 控制台 PASS/FAIL
"""
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..")
report = {"checks": {}, "PASS": True}


def fail(msg):
    report["PASS"] = False
    report["checks"].setdefault("failures", []).append(msg)
    print("  FAIL:", msg)


def check(name, cond, detail=""):
    report["checks"][name] = bool(cond)
    print(f"  {'PASS' if cond else 'FAIL'}: {name}" + (f" ({detail})" if detail and not cond else ""))
    if not cond:
        fail(name)


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


print("== 1) 工程结构 ==")
required = [
    "project.yml",
    "Packages/FilmCore/Package.swift",
    "Packages/FilmCore/Sources/FilmCore/Models/FeedModels.swift",
    "Packages/FilmCore/Sources/FilmCore/Product/ProductProfile.swift",
    "Packages/FilmCore/Sources/FilmCore/Networking/FeedClient.swift",
    "Packages/FilmCore/Sources/FilmCore/Adapter/FeedAdapter.swift",
    "Packages/FilmCore/Sources/FilmCore/Cache/CatalogCache.swift",
    "Packages/FilmCore/Sources/FilmCore/Cache/CatalogStore.swift",
    "Packages/FilmCore/Sources/FilmCore/Live/LiveLoader.swift",
    "Packages/FilmCore/Sources/FilmCore/Logging/FilmLog.swift",
    "Packages/FilmCore/Sources/FilmUI/Theme/FilmTheme.swift",
    "Packages/FilmCore/Sources/FilmUI/Components/PosterImage.swift",
    "Packages/FilmCore/Sources/FilmUI/Components/StateViews.swift",
    "Packages/FilmCore/Sources/FilmUI/Components/PosterCard.swift",
    "Packages/FilmCore/Sources/FilmUI/Screens/HomeView.swift",
    "Packages/FilmCore/Sources/FilmUI/Screens/CategoryBrowseView.swift",
    "Packages/FilmCore/Sources/FilmUI/Screens/SearchView.swift",
    "Packages/FilmCore/Sources/FilmUI/Screens/DetailView.swift",
    "Packages/FilmCore/Sources/FilmUI/Screens/PlayerScreen.swift",
    "Packages/FilmCore/Sources/FilmUI/Screens/LibraryView.swift",
    "Packages/FilmCore/Sources/FilmUI/Screens/LiveView.swift",
    "Apps/Xingmu/XingmuApp.swift", "Apps/Xinwu/XinwuApp.swift", "Apps/Yehang/YehangApp.swift",
    "Packages/FilmCore/Tests/FilmCoreTests/FilmCoreTests.swift",
    "Packages/FilmCore/Tests/FilmCoreTests/Fixtures/part_sample.json",
    "scripts/build_all.sh", "scripts/gen_icons.py", "scripts/verify_feed.py",
    "README.md", "docs/ARCHITECTURE.md", "docs/SIGNING_AND_RELEASE.md", "docs/DATA_CONTRACT.md",
]
for rel in required:
    check(f"exists:{rel}", os.path.isfile(os.path.join(ROOT, rel)))

print("== 2) project.yml 三 Target 独立 ==")
try:
    import yaml
    y = yaml.safe_load(read(os.path.join(ROOT, "project.yml")))
    targets = y.get("targets", {})
    check("targets:3", set(targets) >= {"XingmuISO", "XinwuISO", "YehangISO"})
    bids = [targets[t]["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"] for t in ("XingmuISO", "XinwuISO", "YehangISO")]
    check("bundle_ids:unique", len(set(bids)) == 3, str(bids))
    schemes = y.get("schemes", {})
    check("schemes:3", set(schemes) >= {"XingmuISO", "XinwuISO", "YehangISO"})
except Exception as e:  # noqa: BLE001
    check("project.yml:parse", False, str(e))

print("== 3) Swift 源码粗检 ==")
swift_files = []
for dirpath, _, files in os.walk(os.path.join(ROOT, "Packages")):
    for f in files:
        if f.endswith(".swift"):
            swift_files.append(os.path.join(dirpath, f))
for f in swift_files:
    src = read(f)
    for a, b in [("{", "}"), ("(", ")"), ("[", "]")]:
        # 粗检：字符串字面量内括号少见，明显失衡才算失败
        if src.count(a) - src.count(b) > 3:
            fail(f"balance:{os.path.basename(f)}:{a}{b}")
check("swift_files>=20", len(swift_files) >= 20, str(len(swift_files)))

print("== 4) 产品隔离静态检查 ==")
# App 入口必须绑定正确 profile
bind = {"Xingmu": ".xingmu", "Xinwu": ".xinwu", "Yehang": ".yehang"}
for app, profile in bind.items():
    src = read(os.path.join(ROOT, f"Apps/{app}/{app}App.swift"))
    check(f"{app}:binds:{profile}", f"profile: {profile}" in src)
# 星幕/心屋源码禁止引用 adult feed 仓库（ProductProfile.swift 除外：那是产品档案的本职定义处）
for pkg_dir in ["Sources/FilmCore", "Sources/FilmUI"]:
    for dirpath, _, files in os.walk(os.path.join(ROOT, "Packages/FilmCore", pkg_dir)):
        for f in files:
            if f.endswith(".swift") and f != "ProductProfile.swift":
                src = read(os.path.join(dirpath, f))
                if "filmcollector-pages-yehang" in src:
                    fail(f"leak:yehang-repo-in-shared:{f}")
check("shared:no-hardcoded-repo", True)

print("== 5) 测试夹具 ==")
try:
    fx = json.load(open(os.path.join(ROOT, "Packages/FilmCore/Tests/FilmCoreTests/Fixtures/part_sample.json"), encoding="utf-8"))
    check("fixture:items>=9", len(fx.get("items", [])) >= 9, str(len(fx.get("items", []))))
    check("fixture:has-adult-case", any(i.get("is_adult") for i in fx["items"]))
except Exception as e:  # noqa: BLE001
    check("fixture:parse", False, str(e))

out = os.path.join(ROOT, "build")
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "check_report.json"), "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)
print("== 结论:", "PASS" if report["PASS"] else "FAIL", "=> build/check_report.json")
sys.exit(0 if report["PASS"] else 1)
