#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一键发版：把 guest App 的更新推到用户手机。

用法：
  python publish.py --app xingmu --ipa F:/path/XingmuISO.ipa [--note "更新说明"]
  python publish.py --app music  --ipa F:/path/DWGMusic.ipa --name 大伟歌

做五件事：
  1. 上传 IPA 到 GitHub release latest（--clobber 覆盖同名资产）
  2. 更新 store.json 里该 app 的 iso 文件名/大小
  3. 同步 source.json（壳内「源」Tab 的更新清单：大小/日期/说明）
  4. git add/commit/push gh-pages（页面立即生效）
  5. 验证线上 store.json 已更新，并打印手机端更新深链
手机端更新：打开下载页点「一键更新」，或壳内「源」Tab 点对应 App 的安装。
"""
import argparse, json, os, subprocess, sys, time, urllib.request

GH_PAGES = r"F:/IOS3APP/_ghp_clone"
REPO = "lidawei1985/ios3app-build"
PAGES_URL = "https://lidawei1985.github.io/ios3app-build/store.json"


def run(cmd, **kw):
    print("+", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr, file=sys.stderr)
        sys.exit(f"命令失败: {cmd[0]}")
    return r.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, help="store.json 里的 app id")
    ap.add_argument("--ipa", required=True, help="新版本 ipa 路径")
    ap.add_argument("--asset", help="release 上的资产名（默认取 ipa 文件名）")
    ap.add_argument("--note", help="本次更新的说明，会显示在壳内「源」里")
    args = ap.parse_args()

    ipa = os.path.abspath(args.ipa)
    asset = args.asset or os.path.basename(ipa)
    if not os.path.isfile(ipa):
        sys.exit(f"找不到 {ipa}")

    store_path = os.path.join(GH_PAGES, "store.json")
    store = json.load(open(store_path, encoding="utf-8"))
    app = next((a for a in store["apps"] if a["id"] == args.app), None)
    if app is None:
        sys.exit(f"store.json 里没有 app id = {args.app}")

    # 1. 上传 release
    run(["gh", "release", "upload", "latest", ipa, "--clobber", "--repo", REPO])

    # 2. 更新 store.json
    ios_cfg = app.setdefault("ios", {})
    ios_cfg["iso"] = asset
    ios_cfg["sizeMB"] = max(1, round(os.path.getsize(ipa) / 1048576))
    json.dump(store, open(store_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    # 2.5 同步 source.json（壳内「源」Tab 用的 AltStore 格式清单）
    source_path = os.path.join(GH_PAGES, "source.json")
    src_asset = None
    if os.path.isfile(source_path):
        src = json.load(open(source_path, encoding="utf-8"))
        now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        for sa in src.get("apps", []):
            if os.path.basename(sa.get("downloadURL", "")) == asset:
                sa["size"] = os.path.getsize(ipa)
                sa["versionDate"] = now_iso
                sa["versionDescription"] = args.note or f"{time.strftime('%Y-%m-%d')} 最新构建"
                src_asset = sa
        json.dump(src, open(source_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        if src_asset is None:
            print(f"警告: source.json 里没有 downloadURL 指向 {asset}，源清单未更新该 App")
    else:
        print("警告: 找不到 source.json，跳过源清单同步")

    # 3. 提交推送
    run(["git", "add", "store.json", "source.json"], cwd=GH_PAGES)
    msg = f"发版 {args.app}: {asset} ({ios_cfg['sizeMB']}MB)"
    run(["git", "commit", "-m", msg], cwd=GH_PAGES)
    for attempt in range(3):
        r = subprocess.run(["git", "push", "origin", "gh-pages"], cwd=GH_PAGES,
                           capture_output=True, text=True)
        if r.returncode == 0:
            break
        print("push 失败，10 秒后重试...", r.stderr.strip()[:120])
        time.sleep(10)

    # 4. 验证线上生效（gh-pages CDN 有缓存，等 60s 探测）
    print("等待线上生效…")
    for _ in range(12):
        time.sleep(10)
        try:
            data = json.load(urllib.request.urlopen(PAGES_URL + f"?t={time.time()}", timeout=20))
            online = next((a for a in data["apps"] if a["id"] == args.app), {})
            if online.get("ios", {}).get("iso") == asset:
                print(f"线上已生效: {args.app} -> {asset} ({ios_cfg['sizeMB']}MB)")
                print(f"release 资产: https://github.com/{REPO}/releases/download/latest/{asset}")
                import urllib.parse
                direct = f"https://gh-proxy.com/https://github.com/{REPO}/releases/download/latest/{asset}"
                deep = "livecontainer://install?url=" + urllib.parse.quote(direct, safe="")
                src_deep = "livecontainer://source?url=" + urllib.parse.quote(
                    "https://lidawei1985.github.io/ios3app-build/source.json", safe="")
                print("手机更新深链（Safari 打开即装新包）:")
                print(f"  {deep}")
                print("加源深链（一次设置，之后壳内「源」Tab 直接更新）:")
                print(f"  {src_deep}")
                return
        except Exception as e:
            print("探测失败，重试:", e)
    print("警告：60 秒内线上未检测到更新（CDN 缓存可能更长），请稍后手动刷新确认。")


if __name__ == "__main__":
    main()
