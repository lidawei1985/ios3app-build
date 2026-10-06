#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成 iOS OTA 直装用的 manifest.plist（itms-services:// 协议）。

为什么必须有它：iOS 不能像安卓那样直接点 .ipa 安装。它只认这一条通道——
    itms-services://?action=download-manifest&url=https://<HTTPS 域名>/xxx.plist
plist 里写着 IPA 的 HTTPS 直链、bundle id、版本、图标；iOS 读它才知道装什么。
两个硬性条件（缺一个就装不动）：
  1) plist 和 IPA 都必须是 HTTPS（GitHub Pages / Releases 天然满足）；
  2) IPA 必须是**已签名**的。我们 CI 出的 unsigned-ipas 是裸包，直接分发会"无法安装"。

用法：
    python make_manifest.py <ipa路径> <out.plist> --title 星幕 --url <IPA的HTTPS直链> [--icon <图标HTTPS直链>]
不传 --url 时用 GitHub Releases latest 的默认路径。
"""
import argparse, os, plistlib, sys, zipfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

DEFAULT_BASE = "https://github.com/lidawei1985/ios3app-build/releases/download/latest/"


def read_app_info(ipa: str) -> dict:
    """从 IPA 里读 Info.plist，拿到真实 bundle id / 版本 / 显示名。
    bundle id 必须和签名用的 profile 对得上，写错就是"安装失败"，所以不手填。"""
    with zipfile.ZipFile(ipa) as z:
        cands = [n for n in z.namelist()
                 if n.endswith(".app/Info.plist") and n.count("/") == 2]
        if not cands:
            raise SystemExit("IPA 里没找到 Payload/*.app/Info.plist")
        with z.open(cands[0]) as f:
            return plistlib.load(f)


def build(title, bid, ver, ipa_url, icon_url=None):
    icon = icon_url or ""
    assets = [{"kind": "software-package", "url": ipa_url}]
    if icon:
        assets += [{"kind": "display-image", "url": icon},
                   {"kind": "full-size-image", "url": icon}]
    return {
        "items": [{
            "assets": assets,
            "metadata": {
                "bundle-identifier": bid,
                "bundle-version": ver,
                "kind": "software",
                "title": title,
            },
        }]
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa")
    ap.add_argument("out")
    ap.add_argument("--title", default=None)
    ap.add_argument("--url", default=None, help="IPA 的 HTTPS 直链")
    ap.add_argument("--icon", default=None)
    a = ap.parse_args()

    info = read_app_info(a.ipa)
    bid = info.get("CFBundleIdentifier", "")
    ver = info.get("CFBundleShortVersionString", "1.0")
    title = a.title or info.get("CFBundleDisplayName") or info.get("CFBundleName") or bid
    ipa_url = a.url or DEFAULT_BASE + os.path.basename(a.ipa)

    plist = build(title, bid, ver, ipa_url, a.icon)
    with open(a.out, "wb") as f:
        plistlib.dump(plist, f)
    print("生成 %s" % a.out)
    print("  title =", title)
    print("  bundle =", bid)
    print("  version =", ver)
    print("  ipa 直链 =", ipa_url)
    if not ipa_url.startswith("https://"):
        print("  ⚠️ 直链不是 HTTPS，iOS 会拒绝安装")


if __name__ == "__main__":
    main()
