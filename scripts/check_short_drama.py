# -*- coding: utf-8 -*-
"""短剧通道机检（2026-09-23 新增）

背景（用户原话）：
  「再全网找找能内置的源成人的或者点播的直播的和短剧的 我记着有很多专门短剧的源」

取证结论：**不用外找** —— 我们自己的 7 个内置点播源全都带短剧分类，
  之前被 NavPolicy 的 `normalExcludedWords` 整条挡掉，所以用户在 App 里看不到短剧。
本脚本锁死这次修复的口径，防止以后再被"顺手排除"。

检什么（静态解析 Swift 源码 + 实测分类名夹具，不联网）：
  [1] 星幕有 `normal_short`（标题「短剧」）组，且**排在 `normal_anime` 之前**
      （「AI漫剧/漫剧」同时含动漫组词，顺序错就会被动漫抢走）；
  [2] `normalExcludedWords` 里不再有 短剧/爽剧/爽文/女频/反转/穿越/仙侠/脑洞；
  [3] 内置源实测的短剧分类名 → 星幕全部归「短剧」（Python 复刻 navTitle 口径）；
  [4] 星幕仍不要 综艺/体育/纪录片/预告（别把排除表一起清空了）；
  [5] 红线：**「擦边短剧」必须仍被 `isAdultCategory` 拦下 → 只有夜航**；
  [6] 夜航排除表仍含「短剧」（夜航只做成人，不显示短剧分类）；
  [7] 心屋导航表不含短剧（短剧不进心屋）；
  [8] 首页有「短剧精选」货架（contentType == short_drama），且不混进电视剧池。

判据纪律：**必须做负向对照**（用修复前的旧文件跑，期望 FAIL）——
  否则这条判据是"哑的"（恒真）。命令：python scripts/check_short_drama.py --negctl

用法：python scripts/check_short_drama.py     （退出码 0=PASS，1=FAIL）
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_DEF_NAV = os.path.join(ROOT, "Packages/FilmCore/Sources/FilmCore/Config/NavPolicy.swift")
_DEF_HOME = os.path.join(ROOT, "Packages/FilmCore/Sources/FilmUI/HomePolicy.swift")
_DEF_SITES = os.path.join(ROOT, "Packages/FilmCore/Sources/FilmCore/Config/DefaultSites.swift")


def paths():
    """每次调用都重读环境变量 —— 负向对照要在同一进程内切换源码路径。"""
    return (os.environ.get("CHK_NAV") or _DEF_NAV,
            os.environ.get("CHK_HOME") or _DEF_HOME,
            os.environ.get("CHK_SITES") or _DEF_SITES)

fails = []


def read(p):
    with io.open(p, "r", encoding="utf-8") as f:
        return f.read()


def check(cond, msg):
    print(("  [PASS] " if cond else "  [FAIL] ") + msg)
    if not cond:
        fails.append(msg)


def str_list(src, decl):
    """取出 `static let <decl>: [String] = [ ... ]` 里的字符串。"""
    m = re.search(re.escape(decl) + r"\s*:\s*\[String\]\s*=\s*\[(.*?)\n    \]", src, re.S)
    if not m:
        return None
    return re.findall(r'"([^"]*)"', m.group(1))


def group_block(src, gid):
    """取 `NavGroup(id: "<gid>", title: "...", match: [...])` 的 (title, match, 下标)。"""
    i = src.find('NavGroup(id: "%s"' % gid)
    if i < 0:
        return None, None, -1
    j = src.find("match:", i)
    k = src.find("[", j)
    depth, end = 0, -1
    for p in range(k, len(src)):
        if src[p] == "[":
            depth += 1
        elif src[p] == "]":
            depth -= 1
            if depth == 0:
                end = p
                break
    title = re.search(r'title:\s*"([^"]+)"', src[i:j])
    return (title.group(1) if title else None), re.findall(r'"([^"]*)"', src[k:end]), i


# 内置源实测短剧分类名（2026-09-23 probe_round2.py 对线上 8 个内置点播源 ac=list 实测所得）
MEASURED_SHORT = [
    "短剧", "短剧大全", "AI漫剧", "漫剧", "爽文短剧", "反转爽剧",
    "女频恋爱", "重生民国", "穿越年代", "现代言情", "反转爽文",
    "女恋总裁", "闪婚离婚", "都市脑洞", "言情总裁", "脑洞悬疑",
]
# 星幕仍不要的（别被顺手放开）
STILL_EXCLUDED = ["大陆综艺", "港台综艺", "体育赛事", "足球", "篮球", "斯诺克",
                  "纪录片", "记录片", "预告片", "影视解说"]
# 红线：成人向短剧
ADULT_SHORT = ["擦边短剧"]


def py_nav_title(name, normal_short_match, normal_excluded, adult_words):
    """Python 复刻 NavPolicy.navTitle(forSourceCategory:mode:"normal") 的判定顺序。"""
    n = name.strip()
    if not n:
        return None
    if any(w and w in n for w in adult_words):        # ① 成人类 → 星幕不放行
        return None
    if any(w and w in n for w in normal_excluded):    # ② 星幕排除表
        return None
    for w in normal_short_match:                      # ③ 短剧组（先于动漫组）
        if w and w in n:
            return "短剧"
    return "OTHER"


def main():
    NAV, HOME, SITES = paths()
    nav = read(NAV)
    home = read(HOME)
    sites = read(SITES)

    print("[1] 星幕「短剧」组存在且顺序正确")
    short_title, short_match, short_pos = group_block(nav, "normal_short")
    anime_title, anime_match, anime_pos = group_block(nav, "normal_anime")
    check(short_pos >= 0, "normalGroups 里有 normal_short 组")
    check(short_title == "短剧", "normal_short 标题=短剧（实际=%r）" % short_title)
    check(bool(short_match), "normal_short 词表非空（%d 词）" % len(short_match or []))
    check(0 <= short_pos < anime_pos, "normal_short 排在 normal_anime 之前（%d < %d）" % (short_pos, anime_pos))

    print("[2] 星幕排除表已放开短剧相关词")
    excluded = str_list(nav, "normalExcludedWords") or []
    freed = ["短剧", "爽剧", "爽文", "女频", "反转", "穿越", "仙侠", "脑洞"]
    bad = [w for w in freed if w in excluded]
    check(not bad, "normalExcludedWords 不含短剧词（仍含=%s）" % (bad or "无"))
    keep = [w for w in ["综艺", "体育", "纪录片", "预告"] if w in excluded]
    check(len(keep) == 4, "综艺/体育/纪录片/预告 仍在排除表（命中=%s）" % keep)

    print("[3] 实测短剧分类名 → 星幕归「短剧」（Python 复刻口径）")
    adult_words = str_list(nav, "adultCategoryWords") or []
    check(bool(adult_words), "adultCategoryWords 可解析（%d 词）" % len(adult_words))
    wrong = []
    for n in MEASURED_SHORT:
        got = py_nav_title(n, short_match or [], excluded, adult_words)
        if got != "短剧":
            wrong.append("%s→%s" % (n, got))
    check(not wrong, "16 个实测短剧分类名全部归短剧（异常=%s）" % (wrong or "无"))

    print("[4] 星幕仍不要 综艺/体育/纪录片/预告")
    leaked = [n for n in STILL_EXCLUDED if py_nav_title(n, short_match or [], excluded, adult_words) != None]
    check(not leaked, "非目标分类仍被挡（漏=%s）" % (leaked or "无"))

    print("[5] ★ 红线：擦边短剧只给夜航")
    adult_ex = str_list(nav, "adultExcludedCategoryWords") or []
    kid_blocked_ok = all(any(w in n for w in adult_words) for n in ADULT_SHORT)
    check(kid_blocked_ok, "擦边短剧命中 adultCategoryWords（三端红线靠它）")
    for n in ADULT_SHORT:
        check(py_nav_title(n, short_match or [], excluded, adult_words) is None,
              "星幕不得出现「%s」" % n)

    print("[6] 夜航不显示短剧分类（夜航只做成人）")
    check("短剧" in adult_ex, "adultExcludedCategoryWords 仍含「短剧」")

    print("[7] 心屋导航表不含短剧")
    ci = nav.find("childGroups")
    child_seg = ""
    if ci >= 0:
        k = nav.find("[", ci)
        depth, end = 0, -1
        for p in range(k, len(nav)):
            if nav[p] == "[":
                depth += 1
            elif nav[p] == "]":
                depth -= 1
                if depth == 0:
                    end = p
                    break
        child_seg = nav[k:end] if end > 0 else ""
    check(bool(child_seg), "childGroups 数组可解析（%d 字符）" % len(child_seg))
    check("短剧" not in child_seg, "childGroups 段内无「短剧」")
    check("normal_short" not in child_seg, "childGroups 段内无 normal_short")

    print("[8] 首页「短剧精选」货架")
    check('title: "短剧精选"' in home, "HomePolicy 有「短剧精选」货架")
    m = re.search(r'ShelfSpec\(title:\s*"短剧精选",\s*rule:\s*\.content\("([^"]+)"\)\)', home)
    check(bool(m) and m.group(1) == "short_drama",
          "短剧精选 按 contentType == short_drama 精确取（实际=%s）" % (m.group(1) if m else "无"))
    tv_rule = re.search(r'ShelfSpec\(title:\s*"电视剧精选",\s*rule:\s*\.content\("([^"]+)"\)\)', home)
    check(bool(tv_rule) and tv_rule.group(1) == "tv",
          "电视剧精选仍是 content == tv（不混短剧）")

    print("[9] 内置直播源扩容已落地")
    lv = re.search(r"builtinLiveSources:\s*\[TVBoxLiveGroup\]\s*=\s*\[(.*?)\n    \]", sites, re.S)
    check(bool(lv), "builtinLiveSources 可解析")
    if lv:
        groups = re.findall(r'TVBoxLiveGroup\(name:', lv.group(1))
        urls = re.findall(r'm3uURLs:\s*\["([^"]+)"', lv.group(1))
        check(len(groups) >= 8, "内置直播源 ≥8 组（实际=%d）" % len(groups))
        for u in ["https://live.zbds.org/tv/iptv4.m3u",
                  "https://cdn.jsdelivr.net/gh/BigBigGrandG/IPTV-URL@release/Gather.m3u",
                  "https://cdn.jsdelivr.net/gh/YueChan/Live@main/IPTV.m3u"]:
            check(u in urls, "新增直播源在列：%s" % u.rsplit("/", 1)[-1])

    print("")
    if fails:
        print("RESULT: FAIL —— %d 项不通过" % len(fails))
        for f in fails:
            print("   - " + f)
        return 1
    print("RESULT: PASS —— 短剧通道 + 直播扩容 全部不变量通过")
    return 0


def negctl():
    """负向对照：把三份源码就地"退回修复前"形态（无短剧组 / 排除表含短剧 / 无短剧货架）。

    修复前若也 PASS，说明本脚本的判据是哑的（恒真），等于没检。
    """
    import tempfile
    d = tempfile.mkdtemp(prefix="chk_short_negctl_")
    NAV, HOME, _ = paths()
    nav = read(NAV)
    i = nav.find('NavGroup(id: "normal_short"')
    j = nav.find('NavGroup(id: "normal_anime"', i)
    if i >= 0 and j > i:
        nav = nav[:i] + nav[j:]
    nav = nav.replace(
        '        "纪录片", "记录片", "预告片", "预告", "解说", "演唱", "MV",\n    ]',
        '        "短剧", "爽剧", "爽文", "女频", "反转", "穿越", "仙侠", "脑洞",\n'
        '        "纪录片", "记录片", "预告片", "预告", "解说", "演唱", "MV",\n    ]', 1)

    home = read(HOME).replace(
        '                ShelfSpec(title: "短剧精选", rule: .content("short_drama")),\n', '')

    p_nav = os.path.join(d, "NavPolicy.swift")
    p_home = os.path.join(d, "HomePolicy.swift")
    with io.open(p_nav, "w", encoding="utf-8") as f:
        f.write(nav)
    with io.open(p_home, "w", encoding="utf-8") as f:
        f.write(home)

    os.environ["CHK_NAV"] = p_nav
    os.environ["CHK_HOME"] = p_home
    print("== 负向对照（修复前形态，期望 FAIL）==")
    rc = main()
    print("")
    print("负向对照结论：%s" % ("PASS（判据有效：旧形态确实 FAIL）" if rc == 1
                          else "❌ 判据哑了（旧形态也 PASS）—— 本脚本没有鉴别力"))
    return 0 if rc == 1 else 1


if __name__ == "__main__":
    if "--negctl" in sys.argv:
        sys.exit(negctl())
    sys.exit(main())
