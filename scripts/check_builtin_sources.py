# -*- coding: utf-8 -*-
"""
内置源可见性 / 墓碑分离 静态不变量检查（2026-09-22 新增）

为什么要有这个脚本：
  用户报「我发现内置源消失」，代码级取证出三处缺陷（墓碑集合串台 / 删除键嵌套 / 心屋整段隐藏）。
  这些缺陷**都不会被 xcodebuild 拦住**（能编译、能构建、能上架），只能靠"读源码 + 断言不变量"发现。
  CI 只跑 xcodebuild 不跑 swift test，故这里用纯 Python 解析 Swift 源码做真回归检查。

判据纪律（用户钦定）：**必须做负向对照**。拿修复前的旧文件跑一遍（设 CHK_* 环境变量），
  期望 FAIL —— 若旧代码也 PASS，说明这条判据是"哑的"（恒真），等于没检。
  负向对照命令：python scripts/check_builtin_sources_negctl.py

用法：python scripts/check_builtin_sources.py     （退出码 0=PASS，1=FAIL）
"""
import io
import os
import re
import sys


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# CHK_* 环境变量仅用于负向对照，默认空 → 永远检查工作区真实文件。
SWIFT = os.environ.get("CHK_SWIFT") or os.path.join(
    ROOT, "Packages/FilmCore/Sources/FilmCore/Config/DefaultSites.swift")
CONFIG = os.environ.get("CHK_CONFIG") or os.path.join(
    ROOT, "Packages/FilmCore/Sources/FilmCore/Config/TVBoxConfig.swift")
SETTINGS = os.environ.get("CHK_SETTINGS") or os.path.join(
    ROOT, "Packages/FilmCore/Sources/FilmUI/Screens/SettingsView.swift")

fails = []


def read(p):
    with io.open(p, "r", encoding="utf-8") as f:
        return f.read()


def check(cond, msg):
    print(("  [PASS] " if cond else "  [FAIL] ") + msg)
    if not cond:
        fails.append(msg)


def block_keys(src, decl):
    """取出 `static let <decl>... = [...]` 里所有 TVBoxSite(key: "...") 的 key。"""
    m = re.search(re.escape(decl) + r"[^\[]*\[(.*?)\n    \]", src, re.S)
    if not m:
        return None
    return re.findall(r'TVBoxSite\(key:\s*"([^"]+)"', m.group(1))


def block_repo_urls(src, decl):
    """取出 builtinRepos / builtinAdultRepos 里的 url 列表。"""
    m = re.search(re.escape(decl) + r"[^\[]*\[(.*?)\n    \]", src, re.S)
    if not m:
        return None
    return re.findall(r'TVBoxSubscription\(name:\s*"[^"]*",\s*url:\s*"([^"]+)"', m.group(1))


def func_body(src, header_re):
    m = re.search(header_re + r".*?\n    \}", src, re.S)
    return m.group(0) if m else ""


def label_block_end(body, anchor):
    """返回 anchor 之后第一个 `label: { ... }` 块**闭合花括号**的下标（用于判断谁能进这个块）。"""
    i = body.find(anchor)
    if i < 0:
        return -1
    j = body.find("label:", i)
    if j < 0:
        return -1
    k = body.find("{", j)
    if k < 0:
        return -1
    depth = 0
    for p in range(k, len(body)):
        if body[p] == "{":
            depth += 1
        elif body[p] == "}":
            depth -= 1
            if depth == 0:
                return p
    return -1


def main():
    sw = read(SWIFT)
    cfg = read(CONFIG)
    st = read(SETTINGS)

    print("[1] 内置点播源（DefaultSites.swift）")
    common_keys = block_keys(sw, "builtinVodSources:")
    mixed_keys = block_keys(sw, "builtinMixedVodSources:")
    adult_keys = block_keys(sw, "builtinAdultVodSources:")
    check(bool(common_keys), "builtinVodSources 可解析且非空")
    check(bool(mixed_keys), "builtinMixedVodSources 可解析且非空")
    check(bool(adult_keys), "builtinAdultVodSources 可解析且非空")
    if not (common_keys and mixed_keys and adult_keys):
        return finish()

    normal = list(common_keys) + list(mixed_keys)
    adult = normal + list(adult_keys)

    print("[2] 三端可见性（用户眼里「内置源不能整体消失」）")
    check(len(normal) > 0, "星幕(normal) 内置点播源非空（%d 个）" % len(normal))
    check(len(normal) > 0, "心屋(child) 内置点播源非空（%d 个）" % len(normal))
    check(len(adult) > 0, "夜航(adult) 内置点播源非空（%d 个）" % len(adult))

    print("[3] 索倪源三端共有（用户分类诉求全靠它）")
    check("builtin:suoni" in mixed_keys, "索倪在 builtinMixedVodSources（三端共有）里")
    check("builtin:suoni" not in adult_keys, "索倪没有在成人专用表里重复出现")
    for mode, lst in [("星幕", normal), ("心屋", normal), ("夜航", adult)]:
        check("builtin:suoni" in lst, "%s 能看到索倪" % mode)

    print("[4] 内容隔离红线（成人专用源不得出现在星幕/心屋）")
    overlap = set(normal) & set(adult_keys)
    check(not overlap, "共有源与成人专用源 key 无重叠（重叠=%s）" % (sorted(overlap) or "无"))

    print("[5] 内置线路（DefaultSites.swift）")
    repos_normal = block_repo_urls(sw, "builtinRepos:")
    repos_adult = block_repo_urls(sw, "builtinAdultRepos:")
    check(bool(repos_normal), "影视线路组可解析且非空")
    check(bool(repos_adult), "成人线路组可解析且非空")
    check(bool(repos_normal) and repos_normal[0].startswith("bundle:"),
          "影视线路首条为随包直连 bundle:（零网络依赖兜底）")

    print("[6] ★ 墓碑集合分离（本次「内置源消失」的核心根因）")
    check('"tvbox.deletedBuiltinSiteKeys"' in cfg, "存在点播源墓碑键 tvbox.deletedBuiltinSiteKeys")
    check('"tvbox.deletedBuiltinRepoURLs"' in cfg, "存在线路墓碑键 tvbox.deletedBuiltinRepoURLs")
    check("legacyDeletedBuiltinKey" in cfg and '"tvbox.deletedBuiltinKeys"' in cfg,
          "旧统一键保留为 legacy（用于一次性迁移读取）")

    b = func_body(cfg, r"func removeBuiltinRepo\(")
    check("deletedBuiltinRepoURLs.insert" in b, "removeBuiltinRepo 只写线路墓碑")
    check("deletedBuiltinKeys.insert" not in b, "removeBuiltinRepo 不再写点播源墓碑（原串台点）")

    b = func_body(cfg, r"func removeSite\(")
    check("deletedBuiltinKeys.insert" in b, "removeSite 写点播源墓碑")

    b = func_body(cfg, r"var builtinRepoOptions")
    check("deletedBuiltinRepoURLs.contains" in b, "builtinRepoOptions 按线路墓碑过滤")

    b = func_body(cfg, r"var displayResult")
    check("deletedBuiltinKeys.contains" in b, "displayResult 按点播源墓碑过滤")

    print("[7] 恢复入口互不串台")
    b = func_body(cfg, r"func restoreBuiltins\(\)")
    check(bool(b), "restoreBuiltins 可解析")
    check("deletedBuiltinRepoURLs" not in b, "restoreBuiltins 不碰线路墓碑")
    b2 = func_body(cfg, r"func restoreBuiltinRepos\(\)")
    check("deletedBuiltinRepoURLs.removeAll()" in b2, "restoreBuiltinRepos 只清线路墓碑")

    print("[8] 设置页（心屋空线路不得整段隐藏 + 删除键不得嵌套在激活按钮里）")
    body = func_body(st, r"private var builtinReposSection")
    check(bool(body), "builtinReposSection 可解析")
    # 关键：不能再是 `if !tvbox.builtinRepoOptions.isEmpty {`（整段隐藏）。注意那写法本身含
    # `builtinRepoOptions.isEmpty` 子串 —— 光查子串会恒真，故必须查"带感叹号的否定形式"。
    check(not re.search(r"if\s+!\s*tvbox\.builtinRepoOptions\.isEmpty", body),
          "内置线路区不再用 if !isEmpty 整段隐藏")
    check("builtinRepoOptions.isEmpty" in body, "内置线路区显式处理了空集分支（出说明文案）")
    check("deletedBuiltinRepoURLs.count" in body, "恢复入口按线路墓碑计数（不再混用点播源计数）")
    anchor = body.find("activateBuiltinRepo")
    end = label_block_end(body, "activateBuiltinRepo")
    rm = body.find("removeBuiltinRepo")
    check(anchor >= 0 and rm >= 0 and end >= 0 and rm > end,
          "删除按钮不在激活按钮的 label 块内（activate@%d / labelEnd@%d / remove@%d）" % (anchor, end, rm))

    return finish()


def finish():
    print("")
    if fails:
        print("RESULT: FAIL —— %d 项不通过" % len(fails))
        for f in fails:
            print("   - " + f)
        return 1
    print("RESULT: PASS —— 内置源可见性 / 墓碑分离 全部不变量通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
