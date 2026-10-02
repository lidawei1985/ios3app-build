#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把片源抓成静态 JSON，供网页版同源读取。

为什么这么做：
  片源接口（cj.ffzyapi.com 等）**不返回 Access-Control-Allow-Origin**，
  浏览器直连会被 CORS 拦死。常见解法是架一个反代服务（要账号、要运维），
  这里换条路：由 GitHub Actions 定时抓取 → 生成静态 JSON 推到 Pages，
  网页从同源读 JSON，**不需要任何服务器，也不需要签名**。

用法：
  python build_feed.py --out pages/feed --pages 3 --workers 8
"""
import argparse, json, os, re, ssl, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

SOURCES = [
    {"key": "feifan",  "name": "非凡资源", "api": "https://cj.ffzyapi.com/api.php/provide/vod"},
    {"key": "liangzi", "name": "量子资源", "api": "https://cj.lziapi.com/api.php/provide/vod"},
    {"key": "tianya",  "name": "天涯资源", "api": "https://tyyszy.com/api.php/provide/vod"},
    {"key": "wujin",   "name": "无尽资源", "api": "https://api.wujinapi.me/api.php/provide/vod"},
]

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")


def get_json(url, timeout=20, retry=2):
    for i in range(retry + 1):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": UA, "Referer": url.split("/api.php")[0] + "/"})
            with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as r:
                return json.loads(r.read().decode("utf-8", "ignore"))
        except Exception:
            if i == retry:
                return None
            time.sleep(0.6 * (i + 1))


def clean(s, n=110):
    s = re.sub(r"<[^>]+>", "", (s or "")).replace("\u3000", " ").strip()
    return s[:n]


def parse_eps(play_url):
    """苹果CMS: 多组 $$$ 分隔 / 组内 # 分隔 / 每集 名称$地址"""
    if not play_url:
        return []
    group = play_url.split("$$$")[0]
    out = []
    for seg in group.split("#"):
        if "$" not in seg:
            continue
        i = seg.index("$")
        n, u = seg[:i].strip(), seg[i + 1:].strip()
        if u.startswith("http"):
            out.append({"n": n or "播放", "u": u})
    return out


def fetch_detail(api, vid):
    d = get_json(f"{api}?ac=detail&ids={vid}")
    row = (d or {}).get("list") or []
    return parse_eps(row[0].get("vod_play_url", "") if row else "")


def build_source(src, pages, workers):
    api = src["api"]
    items, seen = [], set()
    for p in range(1, pages + 1):
        j = get_json(f"{api}?ac=list&pg={p}")
        for v in (j or {}).get("list") or []:
            vid = str(v.get("vod_id") or "")
            if not vid or vid in seen:
                continue
            seen.add(vid)
            items.append({
                "id": vid,
                "name": v.get("vod_name") or "",
                "pic": v.get("vod_pic") or "",
                "remarks": v.get("vod_remarks") or "",
                "type": v.get("type_name") or "",
                "year": v.get("vod_year") or "",
                "area": v.get("vod_area") or "",
                "desc": clean(v.get("vod_content")),
                "eps": [],
            })
        if not (j or {}).get("list"):
            break

    with ThreadPoolExecutor(max_workers=workers) as ex:
        eps_list = list(ex.map(lambda it: fetch_detail(api, it["id"]), items))
    for it, eps in zip(items, eps_list):
        it["eps"] = eps
    items = [it for it in items if it["eps"]]

    return {
        "updated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "source": src["key"], "name": src["name"],
        "count": len(items), "items": items,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="pages/feed")
    ap.add_argument("--pages", type=int, default=3)
    ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    index, total = [], 0
    for src in SOURCES:
        t0 = time.time()
        data = build_source(src, a.pages, a.workers)
        path = os.path.join(a.out, src["key"] + ".json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        size = os.path.getsize(path)
        total += data["count"]
        index.append({"key": src["key"], "name": src["name"],
                      "count": data["count"], "updated": data["updated"], "size": size})
        print(f"OK   {src['name']:6s} {data['count']:4d} 部  {size//1024:4d} KB  {time.time()-t0:.0f}s")

    with open(os.path.join(a.out, "index.json"), "w", encoding="utf-8") as f:
        json.dump({"updated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
                   "total": total, "sources": index}, f, ensure_ascii=False)
    print(f"DONE 合计 {total} 部 -> {a.out}")
    return 0 if total else 1


if __name__ == "__main__":
    sys.exit(main())
