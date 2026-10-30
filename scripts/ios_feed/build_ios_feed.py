# -*- coding: utf-8 -*-
"""iOS v1/feed 云端发布器（2026-10-30 立项：E 盘坏 → 本机发布链死 → 片库冻结 19 天）。

数据源 = lidawei1985/filmcollector-pages（云端 ci_auto 每日自动更新，schema 2.1，
  normal 38,210 条 / child，含 originalCategoryName —— 隔离字段齐）。
产出 = iOS 端契约（docs/DATA_CONTRACT.md）：
  v1/feed/{normal|child}/manifest.json + home.json + pN.json(500条/片)
  全部 FCVB1 加密（FCVB1 + 1B 保留 + 12B nonce + AES-256-GCM）。
目标仓 = filmcollector-pages-xingmu(normal) / filmcollector-pages-xinwu(child)。

用法（CI 内）: python scripts/ios_feed/build_ios_feed.py
环境变量: FC_VAULT_KEY(必填,32B 原始密钥的 base64) / GH_TOKEN(推仓用)
只写 v1/feed/<mode>/ 与 FEED_INFO.json —— 直播表/hero 等一律不碰（单写者纪律）。
"""
import base64
import json
import os
import sys
import time
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

SRC = "https://raw.githubusercontent.com/lidawei1985/filmcollector-pages/main/feed.{mode}.json"
TARGETS = {"normal": "filmcollector-pages-xingmu", "child": "filmcollector-pages-xinwu"}
PART_SIZE = 500
MAGIC = b"FCVB1"
# 星幕兜底成人词（老仓 scope=NORMAL 已过闸，这里是双保险；命中即弃）
ADULT_WORDS = ("伦理", "三级", "情色", "有码", "无码", "里番", "两性", "写真热舞")


def log(m):
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def fetch(url):
    for i in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "fc-ios-feed/1.0"})
            with urllib.request.urlopen(req, timeout=300) as r:
                return r.read()
        except Exception as e:
            log(f"fetch retry {i+1}: {e}")
            time.sleep(10)
    raise SystemExit(f"下载失败: {url}")


def enc(key, plain: bytes) -> bytes:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    nonce = os.urandom(12)
    return MAGIC + b"\x00" + nonce + AESGCM(key).encrypt(nonce, plain, None)


def convert(raw_item, mode):
    """老仓 schema2.1 条目 → iOS FeedItem 契约（docs/DATA_CONTRACT.md）。"""
    title = raw_item.get("name") or ""
    if mode == "normal" and any(w in (raw_item.get("originalCategoryName") or "") + title for w in ADULT_WORDS):
        return None
    poster = raw_item.get("poster") or raw_item.get("cover") or ""
    play_url = raw_item.get("playUrl") or ""
    cats = raw_item.get("canonicalCategories") or ([raw_item.get("canonicalCategory")] if raw_item.get("canonicalCategory") else [])
    return {
        "dedup_id": raw_item.get("dedupId") or raw_item.get("canonical_movie_id") or "",
        "title": title,
        "year": raw_item.get("year") or "",
        "directors": raw_item.get("directors") or [],
        "actors": raw_item.get("actors") or [],
        "summary": raw_item.get("summary") or "",
        "content_type": raw_item.get("contentType") or "movie",
        "is_adult": False,
        "playable": bool(raw_item.get("playable", bool(play_url))),
        "categories": {
            "normal": [raw_item.get("originalCategoryName")] if raw_item.get("originalCategoryName") else [],
            "canonical": [c for c in cats if c],
            "tags": raw_item.get("tags") or [],
        },
        "aggregate_category_id": raw_item.get("aggregateCategoryId") or "",
        "aggregate_category_name": raw_item.get("aggregateCategoryName") or "",
        "poster": {"url": poster, "thumb": raw_item.get("cover") or poster},
        "backdrop": {"url": poster, "thumb": poster},
        "quality_score": raw_item.get("quality_score") or 0,
        "origin": {
            "source_id": raw_item.get("sourceId") or "",
            "source_name": raw_item.get("sourceName") or "",
            "category": raw_item.get("originalCategoryName") or "",
        },
        "play": {
            "lines": ([{"name": raw_item.get("sourceName") or "主线", "url": play_url, "quality": "HD"}] if play_url else []),
            "default_line": 0,
            "default_url": play_url,
        },
    }


def build_mode(mode, key):
    log(f"== {mode} ==")
    data = json.loads(fetch(SRC.format(mode=mode)))
    items_raw = data.get("items", [])
    log(f"源条数 {len(items_raw)} (version {data.get('generated_at')})")
    items, dropped = [], 0
    for r in items_raw:
        c = convert(r, mode)
        if c is None:
            dropped += 1
        else:
            items.append(c)
    version = data.get("generated_at") or time.strftime("%Y-%m-%dT%H:%M:%S+00:00")
    total = len(items)
    log(f"转换后 {total} 条（隔离兜底剔除 {dropped}）")

    # manifest
    parts = [f"p{i}.json" for i in range(1, (total + PART_SIZE - 1) // PART_SIZE + 1)]
    manifest = {"ok": True, "mode": mode, "version": version, "count": total,
                "part_size": PART_SIZE, "parts": parts}
    out = {"v1/feed/%s/manifest.json" % mode: enc(key, json.dumps(manifest, ensure_ascii=False).encode())}

    # home.json（首屏轻量包）
    cat_count = {}
    for it in items:
        name = it["aggregate_category_name"] or "其他"
        cat_count[name] = cat_count.get(name, 0) + 1
    cats = sorted([{"id": "agg_" + n, "name": n, "count": c} for n, c in cat_count.items()],
                  key=lambda x: -x["count"])
    # 2026-10-30 主视觉修法：源条目无时间戳（文件按片名字母序），
    # 原先 posters=文件前 40 条 → 首页主视觉永远是同一批"爱X"片，天天不变。
    # 改为：质量分头部池 + 按日期播种轮换 —— 每天自动换一批不同的高分配片。
    with_poster = [it for it in items if it["poster"]["url"]]
    head = sorted(with_poster, key=lambda x: -(x.get("quality_score") or 0))[:1000]
    day_seed = time.strftime("%Y-%m-%d") + mode
    import random
    rotated = random.Random(day_seed).sample(head, 40) if len(head) >= 40 else head
    home = {"ok": True, "mode": mode, "version": version, "total": total,
            "categories": cats[:40],
            "posters": [it["poster"]["url"] for it in rotated],
            "pool": head[:500]}
    out["v1/feed/%s/home.json" % mode] = enc(key, json.dumps(home, ensure_ascii=False).encode())

    # 分片
    for idx, name in enumerate(parts):
        chunk = items[idx * PART_SIZE:(idx + 1) * PART_SIZE]
        part = {"ok": True, "mode": mode, "offset": idx * PART_SIZE, "total": total,
                "version": version, "items": chunk}
        out["v1/feed/%s/%s" % (mode, name)] = enc(key, json.dumps(part, ensure_ascii=False).encode())
    out["FEED_INFO.json"] = json.dumps(
        {"mode": mode, "version": version, "count": total,
         "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
         "builder": "ios3app-build/ios-feed.yml"}, ensure_ascii=False, indent=1).encode()
    log(f"{mode}: {len(parts)} 片, manifest/home + FEED_INFO")
    return out


def push(repo, files):
    """git clone --depth 1 → 覆盖 v1/feed/<mode>/ 与 FEED_INFO.json → commit push。"""
    import subprocess
    tok = os.environ["GH_TOKEN"]
    url = f"https://x-access-token:{tok}@github.com/lidawei1985/{repo}.git"
    tmp = f"/tmp/{repo}"
    subprocess.run(["rm", "-rf", tmp], check=True)
    subprocess.run(["git", "clone", "--depth", "1", url, tmp], cwd="/tmp", check=True)
    for cfg in [["git", "config", "user.email", "fc-ios-feed@ci"],
                ["git", "config", "user.name", "fc-ios-feed"]]:
        subprocess.run(cfg, cwd=tmp, check=True)
    changed = 0
    for rel, blob in files.items():
        p = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        old = open(p, "rb").read() if os.path.exists(p) else None
        if old != blob:
            open(p, "wb").write(blob)
            changed += 1
    if changed == 0:
        log(f"{repo}: 无变化，跳过")
        return False
    subprocess.run(["git", "add", "-A"], cwd=tmp, check=True)
    subprocess.run(["git", "commit", "-m", f"ios-feed: v1/feed 云端发布 {time.strftime('%Y-%m-%d %H:%M')}"],
                   cwd=tmp, check=True)
    for attempt in range(3):
        r = subprocess.run(["git", "push", "origin", "HEAD:main"], cwd=tmp, capture_output=True, text=True)
        if r.returncode == 0:
            log(f"{repo}: 推送 OK（{changed} 文件变更）")
            return True
        log(f"push retry {attempt+1}: {r.stderr[-200:]}")
        subprocess.run(["git", "pull", "--rebase", "origin", "main"], cwd=tmp)
    raise SystemExit(f"{repo}: push 3 连败")


def main():
    key_b64 = os.environ.get("FC_VAULT_KEY", "")
    assert key_b64 and not key_b64.startswith("__"), "FC_VAULT_KEY 未注入"
    key = base64.b64decode(key_b64)
    assert len(key) == 32, f"密钥长度 {len(key)} != 32"
    only = sys.argv[1:] or list(TARGETS)
    for mode in only:
        files = build_mode(mode, key)
        push(TARGETS[mode], files)


if __name__ == "__main__":
    main()
