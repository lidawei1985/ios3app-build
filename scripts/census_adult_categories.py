# -*- coding: utf-8 -*-
"""成人源分类普查 v2 —— 补全拉取 + 按「分类族」算覆盖率，定大类。

用户判据（2026-09-22 原话，两条）：
  「你先把成人的分类和原始源找到，看看到底成人有多少大类，再给我们的 APP 给分类」
  「100 个里面都有里番或者情色三级之类的那就也是大类对不对！」
  「100 个原始源都有伦理那就伦理分类是个大类对不」

→ 大类 = **跨源覆盖率高的分类名（或同义分类族）**。
"""
import re, io, json, sys
from concurrent.futures import ThreadPoolExecutor, as_completed
import urllib.request as U
import ssl

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

ROOT = r"F:/2026-09-19-15-19-07/ios-three-apps/Packages/FilmCore/Sources/FilmCore/Config/DefaultSites.swift"
OLD = r"F:/IOS3APP/ios_ctrl/adult_sources_cats.json"
OUT = r"F:/IOS3APP/ios_ctrl/adult_cats_census.json"

src = io.open(ROOT, encoding="utf-8").read()
pat = re.compile(r'TVBoxSite\(key:\s*"([^"]+)",\s*name:\s*"([^"]+)",\s*api:\s*"([^"]+)"')
sites, section = [], ""
for line in src.splitlines():
    m = re.search(r'static let (builtin\w+)', line)
    if m:
        section = m.group(1)
    for mm in pat.finditer(line):
        sites.append({"key": mm.group(1), "name": mm.group(2), "api": mm.group(3), "section": section})
adult = [s for s in sites if s["section"] == "builtinAdultVodSources" or s["key"] == "builtin:suoni"]

UA = {"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
      "Accept": "*/*"}


def variants(api):
    base = api.rstrip("/")
    out = []
    if "?" in base:
        head, q = base.split("?", 1)
        out += [base + "&ac=list", base + "&ac=videolist", head + "?ac=list", head + "?ac=videolist"]
    else:
        out += [base + "/?ac=list", base + "/?ac=videolist", base + "?ac=list", base]
    if "xml" in base:
        out = [base] + out
    # http / https 互换兜底
    extra = []
    for u in out:
        extra.append(u)
        if u.startswith("https://"):
            extra.append("http://" + u[8:])
    return list(dict.fromkeys(extra))


def parse_names(txt):
    names = []
    try:
        j = json.loads(txt)
        for c in (j.get("class") or []):
            if isinstance(c, dict):
                n = c.get("type_name") or c.get("name")
                if n:
                    names.append(str(n).strip())
    except Exception:
        pass
    if not names:
        for mm in re.finditer(r'(?:type_name|name)="([^"]+)"', txt):
            names.append(mm.group(1).strip())
    return [n for n in dict.fromkeys(names) if n and len(n) < 20]


def fetch(site):
    for u in variants(site["api"]):
        try:
            with U.urlopen(U.Request(u, headers=UA), timeout=10, context=CTX) as r:
                txt = r.read().decode("utf-8", "replace")
            ns = parse_names(txt)
            if len(ns) >= 3:
                return {"key": site["key"], "name": site["name"], "api": site["api"],
                        "url": u, "total_cats": len(ns), "names": ns}
        except Exception:
            continue
    return {"key": site["key"], "name": site["name"], "api": site["api"],
            "url": None, "total_cats": 0, "names": []}


results = {}
with ThreadPoolExecutor(max_workers=12) as ex:
    for f in as_completed({ex.submit(fetch, s): s for s in adult}):
        r = f.result()
        results[r["name"]] = r

# 合并历史普查（9 源时代的产物；新拉到的优先）
if io.open(OLD, encoding="utf-8").readable() if hasattr(io.open(OLD, encoding="utf-8"), "readable") else False:
    pass
try:
    old = json.load(io.open(OLD, encoding="utf-8"))
    for nm, info in old.items():
        if nm not in results or results[nm]["total_cats"] == 0:
            if info.get("names"):
                results[nm] = {"key": nm, "name": nm, "api": "-", "url": "-",
                               "total_cats": len(info["names"]), "names": info["names"]}
                print("  [补] %-12s %3d 类（历史普查）" % (nm, len(info["names"])))
except Exception as e:
    print("历史数据合并跳过:", str(e)[:60])

ok = {k: v for k, v in results.items() if v["total_cats"] > 0}
print("\n可用源：%d 个，分类记录 %d 条" % (len(ok), sum(v["total_cats"] for v in ok.values())))

# ---- 分类族（同义归并）覆盖率 ----
FAMILIES = [
    ("中文字幕/精选推荐", ["中文字幕", "精品推荐", "字幕"]),
    ("伦理", ["伦理"]),
    ("三级/情色", ["三级", "三級", "情色", "色情", "限制级"]),
    ("无码/有码", ["无码", "無碼", "有码", "有碼"]),
    ("成人动漫/里番", ["里番", "裏番", "动漫", "卡通", "动画", "H动漫", "肉番"]),
    ("自拍/偷拍", ["自拍", "偷拍", "盗摄", "偷情"]),
    ("主播/素人", ["主播", "素人", "网红"]),
    ("写真/热舞", ["写真", "热舞", "唯美", "模特"]),
    ("传媒/工作室", ["传媒", "麻豆", "SWAG", "星空", "天美", "果冻", "蜜桃"]),
    ("探花/门事件", ["探花", "门事件", "黑料"]),
    ("人妻/熟女", ["人妻", "熟女", "少妇", "御姐", "痴女"]),
    ("制服/丝袜/美腿", ["制服", "丝袜", "美腿", "黑丝", "COS", "cosplay"]),
    ("SM/调教", ["SM", "调教", "捆绑"]),
    ("群交/多P", ["群交", "多人群交", "多P"]),
    ("乱伦/强奸", ["乱伦", "强奸", "迷奸"]),
    ("国产/大陆", ["国产", "大陆", "华语"]),
    ("日本", ["日本", "日韩", "日剧", "AV"]),
    ("欧美/西方", ["欧美", "西方"]),
    ("韩国", ["韩国", "韩剧"]),
    ("港台", ["港台", "香港", "台湾"]),
    ("性爱/做爱", ["性爱", "做爱", "激情"]),
    ("另类/重口", ["另类", "重口", "人兽", "猎奇"]),
    ("小说/图文", ["小说", "图文", "漫画"]),
    ("VR/4K/高清", ["VR", "4K", "高清"]),
    ("换脸/AI", ["换脸", "AI"]),
    ("两性课堂/教育", ["两性课堂", "两性", "教育"]),
    ("综艺/剧集(非成人)", ["综艺", "电视剧", "电影", "体育", "篮球", "足球", "爽剧", "动漫"]),
]

print("\n" + "=" * 68)
print("★ 分类族覆盖率（出现在多少个源里 / 共 %d 个可用源）" % len(ok))
print("=" * 68)
rows = []
for label, words in FAMILIES:
    hit = []
    for nm, v in ok.items():
        for c in v["names"]:
            if any(w.lower() in c.lower() for w in words):
                hit.append((nm, c))
                break
    rows.append((label, len(hit), hit))
rows.sort(key=lambda r: -r[1])
for label, n, hit in rows:
    pct = 100.0 * n / max(1, len(ok))
    bar = "█" * int(min(30, n))
    print("%-22s %2d 源 (%3.0f%%) %s" % (label, n, pct, bar))

print("\n" + "=" * 68)
print("★ 单分类名覆盖率 TOP 40")
print("=" * 68)
freq = {}
for v in ok.values():
    for n in v["names"]:
        freq.setdefault(n, set()).add(v["name"])
for i, (n, s) in enumerate(sorted(freq.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:40], 1):
    print("%2d. %-16s %2d 源" % (i, n, len(s)))

json.dump({"results": results,
           "freq": {k: sorted(v) for k, v in freq.items()},
           "families": {l: n for l, n, _ in rows}},
          io.open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("\n已存：%s" % OUT)
