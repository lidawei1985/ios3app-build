#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_feed.py — FilmCollector 生产 feed 契约与数量守恒验收（Windows 可跑）

职责（对应迁移红线 §七）：
  SOURCE → PRODUCTION FEED → iOS DATA ADAPTER → APP CATALOG 各级数量台账
  1. 拉取三端 manifest.json：count / parts / version 契约校验
  2. 抽样分片（p0 + 随机 1 片 + 末片）解码校验：字段契约、ID 重复、海报、可播性
  3. 隔离校验：normal/child 端不得出现 is_adult=true（端侧安全网语义）
  4. home.json 契约校验
  5. 产出基线报告 build/feed-baseline/baseline_report.json（数量缩水预警依据）

出口策略：走 ~/.workbuddy/SECRETS/net_route 自动选路（需要梯子自动开，不需要直连），不写死代理。
"""
import json
import os
import random
import sys
import time
import urllib.request

BASELINE_DIR = os.path.join(os.path.dirname(__file__), "..", "build", "feed-baseline")
PRODUCTS = {
    "normal": {"repo": "filmcollector-pages-xingmu", "label": "星幕"},
    "child":  {"repo": "filmcollector-pages-xinwu",  "label": "心屋"},
    "adult":  {"repo": "filmcollector-pages-yehang", "label": "夜航"},
}
CDN = "https://fastly.jsdelivr.net/gh/lidawei1985/{repo}@main/v1/feed/{mode}"
RAW = "https://raw.githubusercontent.com/lidawei1985/{repo}/main/v1/feed/{mode}"
GAPI = "https://api.github.com/repos/lidawei1985/{repo}/contents/v1/feed/{mode}"  # 直连快通道

ITEM_REQUIRED_FIELDS = ["dedup_id", "title", "playable", "poster", "categories"]
ITEM_REQUIRED_NESTED = {"poster": ["url"], "categories": ["canonical"]}


def _route_session(host):
    """按 net_route 单一真源自动选路：代理需要且端口存活→走代理；否则直连。"""
    try:
        sys.path.insert(0, os.path.expanduser(r"~/.workbuddy/SECRETS"))
        from net_route import pick_proxy
        px = pick_proxy(host, force=True)
        if px:
            return urllib.request.build_opener(
                urllib.request.ProxyHandler({"http": px, "https": px}))
    except Exception:
        pass
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def fetch(opener, url, timeout=25, retries=1):
    last = None
    for i in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "ios-migration-verify/1.0"})
            with opener.open(req, timeout=timeout) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1 + i)
    raise RuntimeError(f"fetch failed: {url}: {last}")


def fetch_json(opener, url):
    return json.loads(fetch(opener, url).decode("utf-8"))


def fetch_part_json(cfg, mode, name):
    """大分片取数：api.github.com raw(直连快) → jsdelivr(代理自动路由) → raw.githubusercontent。"""
    err = []
    try:  # 1) GitHub API 原生 raw 媒体类型：api.github.com 直连基线 0.4s
        req = urllib.request.Request(
            GAPI.format(repo=cfg["repo"], mode=mode) + "/" + name,
            headers={"User-Agent": "ios-migration-verify/1.0",
                     "Accept": "application/vnd.github.raw"})
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=30) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:  # noqa: BLE001
        err.append(f"api:{e}")
    opener = _route_session("fastly.jsdelivr.net")
    for label, base in [("cdn", CDN), ("raw", RAW)]:  # 2/3) 常规链路兜底
        try:
            return fetch_json(opener, base.format(repo=cfg["repo"], mode=mode) + "/" + name)
        except Exception as e:  # noqa: BLE001
            err.append(f"{label}:{e}")
    raise RuntimeError(f"part {name} all routes failed: {err}")


def verify_item(item, mode, ledger):
    """单条数据校验，返回丢弃原因或 None。数据保留优先：未知分类只记账不丢弃。"""
    for f in ITEM_REQUIRED_FIELDS:
        if f not in item:
            return f"missing_field:{f}"
    for k, subs in ITEM_REQUIRED_NESTED.items():
        for s in subs:
            if s not in (item.get(k) or {}):
                return f"missing_nested:{k}.{s}"
    if not item.get("title"):
        return "empty_title"
    if mode in ("normal", "child") and item.get("is_adult") is True:
        return "isolation_violation:adult_in_" + mode   # 铁律：隔离安全网
    if not (item.get("poster") or {}).get("url"):
        ledger["empty_poster"] = ledger.get("empty_poster", 0) + 1   # 记账不丢弃
    if not item.get("playable"):
        ledger["not_playable"] = ledger.get("not_playable", 0) + 1   # 记账不丢弃
    return None


def verify_mode(mode, cfg, out):
    opener = _route_session("fastly.jsdelivr.net")
    res = {"label": cfg["label"], "checks": {}}
    manifest = fetch_json(opener, CDN.format(repo=cfg["repo"], mode=mode) + "/manifest.json")
    assert manifest.get("ok") is True, f"{mode}: manifest.ok != true"
    assert manifest.get("mode") == mode
    count = manifest["count"]
    parts = manifest["parts"]
    expect_parts = (count + manifest["part_size"] - 1) // manifest["part_size"]
    res["checks"]["manifest_count"] = count
    res["checks"]["manifest_parts"] = len(parts)
    res["checks"]["parts_match_count"] = len(parts) == expect_parts
    res["version"] = manifest.get("version")

    # 分片抽样：首片 + 随机 1 片 + 末片
    picks = sorted({0, random.randrange(len(parts)), len(parts) - 1})
    seen_ids, dup = set(), 0
    scanned, dropped, reasons = 0, 0, {}
    for idx in picks:
        data = fetch_part_json(cfg, mode, parts[idx])
        assert data.get("ok") is True and data.get("mode") == mode
        for it in data.get("items", []):
            scanned += 1
            did = it.get("dedup_id")
            if did in seen_ids:
                dup += 1
            seen_ids.add(did)
            why = verify_item(it, mode, res)
            if why:
                dropped += 1
                reasons[why] = reasons.get(why, 0) + 1
    res["checks"]["sampled_parts"] = picks
    res["checks"]["sampled_items"] = scanned
    res["checks"]["sample_dropped"] = dropped
    res["checks"]["sample_drop_reasons"] = reasons
    res["checks"]["sample_dup_ids"] = dup
    res["checks"]["isolation_ok"] = not any(r.startswith("isolation_violation") for r in reasons)
    res["checks"]["adapter_pass_ratio"] = round(1 - dropped / scanned, 4) if scanned else 0.0

    # home.json 契约
    home = fetch_json(opener, CDN.format(repo=cfg["repo"], mode=mode) + "/home.json")
    res["checks"]["home_keys"] = sorted(home.keys())
    return res


def main():
    os.makedirs(BASELINE_DIR, exist_ok=True)
    report = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "modes": {}}
    fail = False
    for mode, cfg in PRODUCTS.items():
        print(f"[{cfg['label']} mode={mode}] verifying ...")
        try:
            r = verify_mode(mode, cfg, report)
            ok = all([
                r["checks"]["parts_match_count"],
                r["checks"]["isolation_ok"],
                r["checks"]["sample_dropped"] == 0,
            ])
            r["PASS"] = ok
            fail = fail or not ok
            print(f"  count={r['checks']['manifest_count']} parts={r['checks']['manifest_parts']}"
                  f" sampled={r['checks']['sampled_items']} dropped={r['checks']['sample_dropped']}"
                  f" dup={r['checks']['sample_dup_ids']} PASS={ok}")
        except Exception as e:  # noqa: BLE001
            fail = True
            r = {"label": cfg["label"], "PASS": False, "error": str(e)}
            print(f"  FAIL: {e}")
        report["modes"][mode] = r
    out_path = os.path.join(BASELINE_DIR, "baseline_report.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    print("report ->", out_path)
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
