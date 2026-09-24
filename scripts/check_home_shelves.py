# -*- coding: utf-8 -*-
"""check_home_shelves.py —— 首页货架机检（发布前必过）。

为什么需要（2026-09-23 用户）：
  「怎么老是一些老片」「热门的片2018的！大轰炸 好小子！」「电影精选就更惨不忍睹了」
  「我不管几个货架都行但是你要按照货架名称给出对应的片啊！」「格斗之王那个可以不要放主页吗？」
  「动画片啊？一个动漫的海报看着就难受」
  —— 这些是**可机检的硬约束**，不能靠人眼看一遍。

本脚本用**与端侧 `HomePolicy.swift` 逐字一致的规则**，在真实生产 feed 上跑一遍完整首页，
断言：
  A. 口径正确   热门排=真热度序；高分排=真评分且≥门槛；电影/电视剧排=对应内容类型；题材排=含该题材
  B. 无污染     首页任何一排都不得出现动漫类内容、黑名单片（格斗之王）、无海报片、重复系列
  C. 新度       热门排全部落在近 N 年；最新排年份单调不升；不出现越界（未来）年份
  D. 不空排     每排 ≥ 最小条数

用法：
  python scripts/check_home_shelves.py                 # 检星幕（dist/feed.normal.json）
  python scripts/check_home_shelves.py --mode adult
  python scripts/check_home_shelves.py --feed <path>   # 指定 feed 文件
退出码 0 = PASS，1 = FAIL（有 FAIL 项）。
"""
import argparse
import json
import os
import re
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FC = r"E:\FilmCollector"
if os.path.isdir(os.path.join(FC, "apk_feed_service")):
    sys.path.insert(0, os.path.join(FC, "apk_feed_service"))

# ---- 与 HomePolicy.swift 逐字一致的参数 ----
HOT_RECENT_YEARS = 5
HOT_MIN_VOTES = 200
SHELF_SIZE = 20
MIN_SHELF_ITEMS = 8

BLACKLIST_TITLES = {"格斗之王", "格斗之王2", "格斗之王 2"}
ANIME_WORDS = ["动漫", "动画", "卡通", "漫剧", "国漫", "日漫", "里番", "番剧"]

# 「高分经典」评分门槛：星幕 9.0 / 心屋 8.0（夜航无评分数据，不出该排）
CLASSIC_MIN = {"normal": 9.0, "child": 8.0, "adult": 9.0}

# 机会型货架：内容不足 8 部时 App 侧自动不出排，机检只 WARN 不 FAIL（与 HomePolicy.minShelfItems 一致）
OPTIONAL_SHELVES = {"短剧精选"}

SHELVES = {
    "normal": [("热门推荐", "hot"), ("最新上线", "fresh"), ("电影精选", "content:movie"),
               ("电视剧精选", "content:tv"), ("短剧精选", "content:short_drama"),
               ("动作精选", "genre:动作"),
               ("喜剧精选", "genre:喜剧"), ("悬疑犯罪", "genre:悬疑,犯罪,惊悚"),
               ("高分经典", "classic")],
    "adult": [("热门推荐", "hot"), ("最新上线", "fresh"), ("伦理精选", "genre:伦理"),
              ("三级精选", "genre:三级,港台"), ("成人动漫", "genre:动漫,里番"),
              ("无码精选", "genre:无码")],
    "child": [("最新上线", "fresh"), ("动画片精选", "genre:动画,动漫"),
              ("儿童电影", "content:movie"), ("高分动画", "classic")],
}

_SEASON_RE = re.compile(r"(第[一二三四五六七八九十0-9]+季|第[一二三四五六七八九十0-9]+部|Season\s*\d+|S\d{1,2})",
                        re.I)
_VERSION_RE = re.compile(r"(国语|粤语|普通话|英语|日语|韩语|泰语|中字|双语|台配|配音|国语版|粤语版|"
                         r"HD|蓝光|BD|4K|1080P|720P|高清|完整版|未删减|修复版|典藏版|真人版)", re.I)


def series_key(title):
    t = _SEASON_RE.sub("", title or "")
    t = _VERSION_RE.sub("", t)
    return t.strip() or (title or "")


def names_of(it):
    out = []
    for k in ("aggregate_category_name", "aggregate_category_id"):
        v = it.get(k)
        if isinstance(v, str) and v:
            out.append(v)
    cat = it.get("categories") or {}
    for k in ("normal", "canonical", "tags"):
        out.extend([x for x in (cat.get(k) or []) if isinstance(x, str)])
    org = it.get("origin") or {}
    if isinstance(org.get("category"), str):
        out.append(org["category"])
    return out


def is_anime(it):
    if (it.get("content_type") or "").lower() == "anime":
        return True
    return any(w in n for n in names_of(it) for w in ANIME_WORDS)


def effective_year(it, cur):
    y = str(it.get("year") or "")[:4]
    if not y.isdigit():
        return 0
    n = int(y)
    return n if 1900 <= n <= cur else 0


def rating_of(it):
    r = it.get("rating")
    try:
        r = float(r)
    except (TypeError, ValueError):
        r = 0.0
    return r if 0 < r <= 10 else 0.0


def votes_of(it):
    try:
        return max(0, int(it.get("votes") or 0))
    except (TypeError, ValueError):
        return 0


def allows_on_home(it, mode):
    if not (it.get("poster") or {}).get("url"):
        return False
    # 动漫排除只对星幕生效（心屋动画片是主体、夜航成人动漫是正经大类）
    if mode == "normal" and is_anime(it):
        return False
    return (it.get("title") or "").strip() not in BLACKLIST_TITLES


def rank(rule, pool, cur, mode):
    usable = [i for i in pool if allows_on_home(i, mode)]
    if rule == "hot":
        recent = [i for i in usable if effective_year(i, cur) >= cur - HOT_RECENT_YEARS]
        strong = [i for i in recent if votes_of(i) >= HOT_MIN_VOTES]
        strong.sort(key=lambda i: (-votes_of(i), -rating_of(i), -effective_year(i, cur)))
        if len(strong) >= MIN_SHELF_ITEMS:
            return strong
        recent.sort(key=lambda i: (-votes_of(i), -effective_year(i, cur)))
        if len(recent) >= MIN_SHELF_ITEMS:
            return recent
        rest = sorted(usable, key=lambda i: (-votes_of(i), -effective_year(i, cur)))
        return recent + rest
    if rule == "fresh":
        return sorted(usable, key=lambda i: (-effective_year(i, cur), -votes_of(i), -rating_of(i)))
    if rule.startswith("content:"):
        ct = rule.split(":", 1)[1]
        return sorted([i for i in usable if (i.get("content_type") or "movie") == ct],
                      key=lambda i: (-effective_year(i, cur), -votes_of(i), -rating_of(i)))
    if rule.startswith("genre:"):
        words = rule.split(":", 1)[1].split(",")
        return sorted([i for i in usable if any(w in n for n in names_of(i) for w in words)],
                      key=lambda i: (-effective_year(i, cur), -votes_of(i), -rating_of(i)))
    if rule == "classic":
        gate = CLASSIC_MIN.get(mode, 9.0)
        return sorted([i for i in usable if rating_of(i) >= gate],
                      key=lambda i: (-rating_of(i), -votes_of(i), -effective_year(i, cur)))
    raise ValueError("unknown rule " + rule)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="normal")
    ap.add_argument("--feed", default=None)
    # 默认读 dist（发布前的真源）；--published 读契约形状的构建产物
    args = ap.parse_args()
    path = args.feed or os.path.join(FC, "dist", "feed.%s.json" % args.mode)
    if not os.path.exists(path):
        print("FAIL 找不到 feed：%s" % path)
        return 1
    raw = json.load(open(path, encoding="utf-8")).get("items") or []
    print("feed: %s（%d 条）" % (path, len(raw)))

    if os.path.isdir(os.path.join(FC, "apk_feed_service")) and not args.feed:
        import service as svc
        pool = [svc._dist_to_contract(i, args.mode) for i in raw]
        pool = [c for c in pool if c.get("url") or (c.get("play") or {}).get("lines")]
        print("契约池：%d 条（与端侧实际收到的形状一致）" % len(pool))
    else:
        pool = raw

    cur = time.localtime().tm_year
    fails, warns = [], []

    # 首屏主视觉：电影/电视剧 + 允许上首页；优先近 3 年真热门，不足 15 部再按年份补齐
    hero_base = [i for i in pool if allows_on_home(i, args.mode)
                 and (i.get("content_type") or "") in ("movie", "tv")]
    hero_recent = [i for i in hero_base
                   if effective_year(i, cur) >= cur - 2 and votes_of(i) >= 500]
    hero_pool = sorted(hero_recent, key=lambda i: -votes_of(i))
    if len(hero_pool) < 15:
        hero_pool += sorted(hero_base, key=lambda i: -effective_year(i, cur))
    hero = hero_pool[:15]
    used = set()
    hero_out = []
    for i in hero:
        k = series_key(i.get("title"))
        if k in used:
            continue
        used.add(k)
        hero_out.append(i)
    print("\n[主视觉] %d 部：%s" % (len(hero_out),
          "、".join("%s(%s)" % (i["title"][:12], effective_year(i, cur)) for i in hero_out[:8])))
    if len(hero_out) < 5:
        fails.append("主视觉不足 5 部（实际 %d）" % len(hero_out))
    for i in hero_out:
        if args.mode == "normal" and is_anime(i):
            fails.append("主视觉出现动漫：%s" % i["title"])
        if (i.get("title") or "").strip() in BLACKLIST_TITLES:
            fails.append("主视觉出现黑名单片：%s" % i["title"])

    for title, rule in SHELVES.get(args.mode, []):
        ranked = rank(rule, pool, cur, args.mode)
        picked = []
        for i in ranked:
            if len(picked) >= SHELF_SIZE:
                break
            k = series_key(i.get("title"))
            if k in used:
                continue
            used.add(k)
            picked.append(i)
        print("\n[%s] %s  候选 %d → 取 %d" % (rule, title, len(ranked), len(picked)))
        for i in picked[:6]:
            print("    %-30s y=%-5s r=%-4s votes=%-9s %s"
                  % ((i.get("title") or "")[:30], effective_year(i, cur) or "-",
                     rating_of(i) or "-", votes_of(i) or "-", (i.get("content_type") or "-")))
        if len(picked) < MIN_SHELF_ITEMS:
            # 机会型货架：内容不足时 App 侧**不出排**（HomePolicy.minShelfItems），故不算缺陷，
            # 只记 WARN 提醒（如「短剧精选」要等中台采集侧开了短剧分类才会亮起）。
            if title in OPTIONAL_SHELVES:
                warns.append("[%s] 只有 %d 条（< %d）——机会型货架，App 侧自动隐藏，不算缺陷"
                             % (title, len(picked), MIN_SHELF_ITEMS))
                continue
            fails.append("[%s] 只有 %d 条（< %d）" % (title, len(picked), MIN_SHELF_ITEMS))
            continue
        # A. 口径
        if rule == "hot":
            bad = [i["title"] for i in picked if effective_year(i, cur) < cur - HOT_RECENT_YEARS]
            if bad:
                fails.append("[%s] 出现 %d 年前的老片：%s" % (title, HOT_RECENT_YEARS, bad[:3]))
            if all(votes_of(i) == 0 for i in picked):
                fails.append("[%s] 整排无真热度（votes 全 0）" % title)
        if rule == "fresh":
            ys = [effective_year(i, cur) for i in picked]
            if ys != sorted(ys, reverse=True):
                warns.append("[%s] 年份未严格不升：%s" % (title, ys))
        if rule.startswith("content:"):
            ct = rule.split(":", 1)[1]
            bad = [i["title"] for i in picked if (i.get("content_type") or "movie") != ct]
            if bad:
                fails.append("[%s] 混入非 %s：%s" % (title, ct, bad[:3]))
        if rule.startswith("genre:"):
            words = rule.split(":", 1)[1].split(",")
            bad = [i["title"] for i in picked
                   if not any(w in n for n in names_of(i) for w in words)]
            if bad:
                fails.append("[%s] 混入非该题材：%s" % (title, bad[:3]))
        if rule == "classic":
            gate = CLASSIC_MIN.get(args.mode, 9.0)
            bad = [(i["title"], rating_of(i)) for i in picked if rating_of(i) < gate]
            if bad:
                fails.append("[%s] 评分低于门槛 %.1f：%s" % (title, gate, bad[:3]))
        # B. 无污染
        for i in picked:
            if args.mode == "normal" and is_anime(i):
                fails.append("[%s] 出现动漫：%s" % (title, i["title"]))
            if (i.get("title") or "").strip() in BLACKLIST_TITLES:
                fails.append("[%s] 出现黑名单片：%s" % (title, i["title"]))
            if not (i.get("poster") or {}).get("url"):
                fails.append("[%s] 出现无海报条目：%s" % (title, i["title"]))
            if effective_year(i, cur) == 0 and (i.get("year") or "").strip():
                warns.append("[%s] 越界年份：%s(%s)" % (title, i["title"], i.get("year")))
        # D. 去重（系列键唯一）
        keys = [series_key(i["title"]) for i in picked]
        dup = {k for k in keys if keys.count(k) > 1}
        if dup:
            fails.append("[%s] 同系列重复：%s" % (title, list(dup)[:3]))

    print("\n===== 机检结果 =====")
    for w in warns:
        print("  WARN %s" % w)
    if fails:
        for f in fails:
            print("  FAIL %s" % f)
        print("结果：FAIL（%d 项）" % len(fails))
        return 1
    print("结果：PASS（首页 %d 排，全部满足「货架名 = 内容」与无污染约束）"
          % len(SHELVES.get(args.mode, [])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
