#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把官方 LiveContainer+SideStore 做成「一体化包」：
  装上它 = 装上我们的 App（图标/名字就是星幕或心屋），
  内置 SideStore 负责后台自动续签（7 天一轮，用户无感）。

做法：改名 + 换图标 + （可选）换 bundle id / URL scheme，其它原样保留。

已核实的事实（别再猜）：
  - 原包图标就是标准 PNG（非 iOS 私有 CgBI），所以直接用 PIL 生成的 PNG 替换是安全的
  - LiveContainer 二进制里【没有】BundledApps / DefaultApp 之类的内置机制，
    把客 App IPA 塞进包里它不会自动识别 → 已移除，改由页面 livecontainer://install?url= 一键导入
  - keychain group 是硬编码字符串 AAAAA11111.com.kdt.livecontainer.shared.*，
    不从 bundle id 派生 → 改 bundle id 不会破坏容器数据（第二个实例必须改，否则同 id 只能装一个）

注意：改过的包签名已失效，必须由用户用 SideStore / Feather 等签名器导入签名安装——
      这是 iOS 的规矩，任何人分发非商店 App 都躲不掉"最终由某个证书签一次"。
"""
import argparse, os, shutil, sys, zipfile, plistlib
from PIL import Image, ImageDraw, ImageFont

APP = "Payload/LiveContainer.app"


def make_icon(path, title, size, c1, c2):
    im = Image.new("RGB", (size, size), c1)
    d = ImageDraw.Draw(im)
    for y in range(size):
        r = c1[0] + (c2[0] - c1[0]) * y // size
        g = c1[1] + (c2[1] - c1[1]) * y // size
        b = c1[2] + (c2[2] - c1[2]) * y // size
        d.line([(0, y), (size, y)], fill=(r, g, b))
    f = None
    for fp in (r"C:/Windows/Fonts/msyhbd.ttc", r"C:/Windows/Fonts/msyh.ttc",
               r"C:/Windows/Fonts/simhei.ttf"):
        if os.path.exists(fp):
            f = ImageFont.truetype(fp, int(size * 0.36))
            break
    d.text((size / 2, size / 2), title, fill=(255, 255, 255), font=f, anchor="mm")
    im.save(path)


def grey_variant(src, dst):
    Image.open(src).convert("L").convert("RGB").save(dst)


def patch_plist(data, title, bid=None, scheme=None):
    """用 plistlib 正规改写，不做字符串替换（避免破坏二进制 plist 结构）"""
    pl = plistlib.loads(data)
    pl["CFBundleDisplayName"] = title
    pl["CFBundleName"] = title
    old_bid = pl.get("CFBundleIdentifier", "")
    if bid:
        pl["CFBundleIdentifier"] = bid
        # URL name / SideStore 备份 scheme 跟着换，避免两个实例互相抢
        for t in pl.get("CFBundleURLTypes", []):
            n = t.get("CFBundleURLName", "")
            if old_bid and old_bid in n:
                t["CFBundleURLName"] = n.replace(old_bid, bid)
            t["CFBundleURLSchemes"] = [
                (scheme if s == "livecontainer" else
                 s.replace(old_bid, bid) if old_bid and old_bid in s else s)
                for s in t.get("CFBundleURLSchemes", [])
            ]
    elif scheme:
        for t in pl.get("CFBundleURLTypes", []):
            t["CFBundleURLSchemes"] = [
                scheme if s == "livecontainer" else s
                for s in t.get("CFBundleURLSchemes", [])
            ]
    return plistlib.dumps(pl, fmt=plistlib.FMT_BINARY)


def build(base_ipa, out_ipa, title, c1, c2, bid=None, scheme=None,
          tmp="pages/_bundle"):
    if os.path.isdir(tmp):
        shutil.rmtree(tmp)
    os.makedirs(tmp, exist_ok=True)

    icons = {
        "AppIcon60x60@2x.png": 120,
        "AppIcon76x76@2x~ipad.png": 152,
        "AppIconGrey60x60@2x.png": 120,
        "AppIconGrey76x76@2x~ipad.png": 152,
    }
    for name, sz in icons.items():
        p = os.path.join(tmp, name)
        make_icon(p, title, sz, c1, c2)
        if name.startswith("AppIconGrey"):
            grey_variant(p, p)

    skip = set()
    for k in icons:
        skip.add(f"{APP}/{k}")
        skip.add(f"{APP}/Frameworks/SideStoreApp.framework/{k}")

    zin = zipfile.ZipFile(base_ipa)
    with zipfile.ZipFile(out_ipa, "w", zipfile.ZIP_DEFLATED) as zout:
        for k in icons:
            zout.write(os.path.join(tmp, k), f"{APP}/{k}")
            zout.write(os.path.join(tmp, k),
                       f"{APP}/Frameworks/SideStoreApp.framework/{k}")
        for info in zin.infolist():
            n = info.filename
            if n in skip or n.startswith(f"{APP}/BundledApps/"):
                continue
            data = zin.read(n)
            if n == f"{APP}/Info.plist":
                data = patch_plist(data, title, bid, scheme)
            zi = zipfile.ZipInfo(n, date_time=info.date_time)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (0o100755 << 16) if "/Frameworks/" in n or n.endswith(
                ("/LiveContainer", "/SideStoreApp")) else info.external_attr
            zout.writestr(zi, data)
    zin.close()
    shutil.rmtree(tmp, ignore_errors=True)
    return os.path.getsize(out_ipa)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--out", default="pages/bundle")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    # 第二个实例必须换 bundle id + scheme，否则 iOS 上两个包同 id 只能装一个，
    # 且点「装星幕」的链接可能打开心屋的容器、把片源装错地方。
    jobs = [
        ("xingmu", "星幕", (224, 53, 63), (120, 20, 35), None, None),
        ("xinwu", "心屋", (76, 141, 255), (24, 60, 140),
         "com.kdt.livecontainer.xw", "livecontainer2"),
    ]
    for key, title, c1, c2, bid, scheme in jobs:
        out = os.path.join(a.out, f"{key}.ipa")
        size = build(a.base, out, title, c1, c2, bid, scheme)
        print(f"OK  {out}  {size/1024/1024:.1f} MB  bid={bid or '(原)'} scheme={scheme or '(原)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
