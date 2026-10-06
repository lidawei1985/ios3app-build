#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_project.py — Windows 端静态验收（诚实声明：本机无 macOS/Xcode，不做假编译）。
校验：
  1. 工程结构完整性（共享包/测试/脚本/文档 + 各端入口；端数与入口**从 project.yml 反推**）
  2. project.yml 可解析，各 Target Bundle ID / Scheme 唯一并覆盖全部 Target
  3. Swift 源文件括号/引号平衡粗检 + 关键类存在
  4. 产品隔离静态检查：Xingmu/Xinwu 源码不得引用 adult feed 仓库；各 App 入口绑定同名 profile
  5. 测试夹具 JSON 有效
产出：build/check_report.json + 控制台 PASS/FAIL
注（2026-09-27）：原版判据硬编码了当时固定的端名与入口文件，端数一变即恒 FAIL。
  现改为以 project.yml 为唯一事实来源，端数增减自动适配，不再随仓库形态腐烂。
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
    "Apps/Xingmu/XingmuApp.swift", "Apps/Xinwu/XinwuApp.swift",
    "Packages/FilmCore/Tests/FilmCoreTests/FilmCoreTests.swift",
    "Packages/FilmCore/Tests/FilmCoreTests/Fixtures/part_sample.json",
    "scripts/build_all.sh", "scripts/gen_icons.py", "scripts/verify_feed.py",
    "README.md", "docs/ARCHITECTURE.md", "docs/DATA_CONTRACT.md",
]
for rel in required:
    check(f"exists:{rel}", os.path.isfile(os.path.join(ROOT, rel)))

# 非强制文档（2026-09-27）：docs/SIGNING_AND_RELEASE.md 只存在于主源码仓
# lidawei1985/ios-three-apps，本仓（lidawei1985/ios3app-build，二端构建仓）从未有过该文件 ——
# 原是照抄主仓清单导致的假 FAIL。按「若存在则校验格式」处理，缺了只报 INFO，不算工程缺陷。
_optional_docs = ["docs/SIGNING_AND_RELEASE.md"]
for rel in _optional_docs:
    p = os.path.join(ROOT, rel)
    print(f"  {'PASS' if os.path.isfile(p) else 'INFO'}: optional-doc:{rel}")

print("== 2) project.yml Target 独立（端数从 project.yml 反推，不硬编码）==")
# 2026-09-27 修复：原判据硬编码了当时固定的端名，端数一变即恒 FAIL
# —— 判据绑死了「当时的端数」，会随仓库形态腐烂。改为以 project.yml 为唯一事实来源自适配。
app_dirs = []
try:
    import yaml
    y = yaml.safe_load(read(os.path.join(ROOT, "project.yml")))
    targets = y.get("targets", {})
    schemes = y.get("schemes", {})
    check("targets>=2", len(targets) >= 2, str(sorted(targets)))
    for tname, t in targets.items():
        for s in (t.get("sources") or []):
            p = s.get("path") if isinstance(s, dict) else s
            if p and str(p).startswith("Apps/"):
                app_dirs.append((tname, str(p).rstrip("/")))
    check("apps:from-yml>=2", len(app_dirs) >= 2, str(app_dirs))
    bids = [targets[t]["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"] for t in targets]
    check("bundle_ids:unique", len(set(bids)) == len(bids), str(bids))
    check("schemes:cover-targets", set(schemes) >= set(targets), str(sorted(schemes)))
    # 每个 Target 的源码目录与入口文件必须真实存在（端数变化时自动跟着查）
    for tname, adir in app_dirs:
        app = os.path.basename(adir)
        check(f"entry:{adir}/{app}App.swift",
              os.path.isfile(os.path.join(ROOT, adir, f"{app}App.swift")))
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
# App 入口必须绑定与本 Target 同名的 profile（XingmuISO → Apps/Xingmu → .xingmu）。
# 同样不再硬编码三端：端数由 project.yml 决定，新增/下线端自动纳入检查。
for tname, adir in app_dirs:
    app = os.path.basename(adir)
    entry = os.path.join(ROOT, adir, f"{app}App.swift")
    if not os.path.isfile(entry):
        fail(f"entry:missing:{adir}/{app}App.swift")
        continue
    expect = "." + re.sub(r"ISO$", "", tname).lower()
    check(f"{app}:binds:{expect}", f"profile: {expect}" in read(entry))
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
