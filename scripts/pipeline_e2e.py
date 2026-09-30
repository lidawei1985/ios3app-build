#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pipeline_e2e.py — 全量管线端到端对账（与 iOS FeedAdapter 同构）。
跑法：python scripts/pipeline_e2e.py [mode ...]   （默认 child adult；normal 约140MB建议抽样用 verify_feed）
输出：build/feed-baseline/e2e_full_pipeline.json
"""
import json
import os
import sys
import urllib.request

OUT = os.path.join(os.path.dirname(__file__), "..", "build", "feed-baseline", "e2e_full_pipeline.json")
REPOS = {"normal": "xingmu", "child": "xinwu", "adult": "yehang"}


def gj(u):
    req = urllib.request.Request(u, headers={"User-Agent": "v", "Accept": "application/vnd.github.raw"})
    return json.loads(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=60).read().decode("utf-8"))


def main():
    modes = sys.argv[1:] or ["child", "adult"]
    report = {}
    fail = False
    for mode in modes:
        repo = REPOS[mode]
        man = gj(f"https://api.github.com/repos/lidawei1985/filmcollector-pages-{repo}/contents/v1/feed/{mode}/manifest.json")
        items, failed = [], 0
        for p in man["parts"]:
            try:
                items += gj(f"https://api.github.com/repos/lidawei1985/filmcollector-pages-{repo}/contents/v1/feed/{mode}/{p}")["items"]
            except Exception:  # noqa: BLE001
                failed += 1
        # 与 iOS FeedAdapter 同构：dedup 去重 + isolation 拦截 + 台账
        seen, dup, iso, catalog = set(), 0, 0, []
        for it in items:
            if it["dedup_id"] in seen:
                dup += 1
                continue
            seen.add(it["dedup_id"])
            if mode in ("normal", "child") and it.get("is_adult") is True:
                iso += 1
                continue
            catalog.append(it)
        src, out = man["count"], len(catalog)
        ok = out >= src * 8 // 10 and failed == 0
        fail = fail or not ok
        report[mode] = dict(source=src, fetched=len(items), failed_parts=failed,
                            dup=dup, isolation=iso, catalog=out, shrink=not ok)
        print(mode, f"source={src} fetched={len(items)} dup={dup} iso={iso} "
                    f"catalog={out} FAILED_PARTS={failed} SHRINK={not ok}")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(report, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("SAVED", OUT)
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
