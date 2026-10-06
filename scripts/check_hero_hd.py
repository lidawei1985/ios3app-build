# -*- coding: utf-8 -*-
"""check_hero_hd.py —— 主视觉（hero）包内素材机检【发布前必过】

为什么需要（2026-10-01 用户钦定判据）
------------------------------------
「你采集 100000 也没有用啊，看不了等于 0。」
主视觉同理：**采了多少张不算数，上屏是不是高清才算数。** 这条判据必须机器可查、
且必须有**鉴别力**（旧版 270px 必须判 FAIL），否则就是哑判据。

判据（每条都可反证）
-------------------
  INV-1 manifest 存在且条目数 >= MIN_ENTRIES
  INV-2 manifest 的 value（文件名）互不重复，且每个文件真实存在
  INV-3 目录里除 .json 外的文件 == manifest 引用的文件集合（无孤儿、无缺失）
  INV-4 **每一张的宽度 >= MIN_WIDTH**（默认 640；旧版 270px 必 FAIL）
  INV-5 每张魔数合法（JPEG/PNG/WEBP/GIF），且扩展名与实际一致
  INV-6 每张字节数 >= MIN_BYTES（默认 20000；旧版部分小图会 FAIL）

用法
----
  python scripts/check_hero_hd.py                          # 检 Apps/{Xingmu,Xinwu}/HeroBundled
  python scripts/check_hero_hd.py --root <仓库根>
  python scripts/check_hero_hd.py --dir <某个 HeroBundled 目录>   # 负向对照用
"""
import argparse
import json
import os
import struct
import sys

ROOT_DEFAULT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPS = ["Xingmu", "Xinwu"]

MIN_ENTRIES = 15       # 2026-10-03 主人钦定「主视觉保持 15 张轮换」——8 → 15，低于 15 直接 FAIL
MIN_WIDTH = 640
MIN_BYTES = 20000

# ── INV-7/8：**运行时选片口径**的源码闸门 ──────────────────────────────────────
# 为什么必须有：包内 15 张高清只是「素材合格」，主视觉上屏的是**运行时选出来的 15 部**
# （HomeView.computeShelves 的 out.hero）。素材合格 ≠ 上屏合格 —— 选片口径被改回
# 「不限可播、不看图质」时，包内素材再高清也没用（feed 里 270px 图床照样进主视觉）。
# 主人钦定四条：保持高清 / 最新 / **能播放** / 不使用低质量 / 保持 15 张轮换。
#
# ⚠️ 判据必须**行级锚定**，不能只查「区间里出现过某字符串」——已实测：把 isPlayable
#    从高清层那一行删掉，它在区间别处（次级层）仍出现，粗判据照样 PASS（哑判据）。
#    所以下面把「高清首层那一行」和「收尾那一行」整行钉死。
HERO_SRC = os.path.join("Packages", "FilmCore", "Sources", "FilmUI", "Screens", "HomeView.swift")
HERO_ANCHORS = [
    ("let heroHD = heroBase.filter { $0.isPlayable && PosterLoader.isHighRes($0.bestPosterURL) }",
     "高清首层必须同时「能播放 + 高清」（包内高清素材 或 已知高清网络图源；"
     "少了 isPlayable 就有播不了的进门面，少了 isHighRes 就有 270px 图床进门面）"),
    ("out.hero = take(heroRank(heroHD), 15)",
     "★铁律（主人钦定 2026-10-04）「不是高清禁止上主视觉」：门面只收 heroHD 一层，"
     "层内真热门优先；不足 15 张宁少不凑，严禁「有图/保底」等非高清层兜底"),
]


def check_hero_source(root):
    """INV-7/8：主视觉选片口径必须**整行**仍在源码里（防无声回退）。"""
    p = os.path.join(root, HERO_SRC)
    if not os.path.exists(p):
        return ["INV-7 找不到主视觉选片源码：%s" % p]
    src = open(p, encoding="utf-8", errors="replace").read()
    i = src.find("let heroBase = allItems.filter")
    j0 = src.find("out.hero = take(")
    if i < 0 or j0 < 0:
        return ["INV-7 主视觉选片区间定位失败（heroBase=%s out.hero=%s）" % (i >= 0, j0 >= 0)]
    j = src.find("\n", j0)
    seg = src[i:j if j > 0 else len(src)]
    # 去缩进后逐行比对
    lines = [ln.strip() for ln in seg.splitlines()]
    bad = []
    for anchor, why in HERO_ANCHORS:
        if anchor not in lines:
            bad.append("INV-8 主视觉选片缺少整行「%s」——%s" % (anchor, why))
    return bad


# 已知缺口（**不许拿它掩盖代码缺陷**，每条必须写明「为什么是素材不是代码」）。
# 口径：TMDB 该片最大竖版海报就只有这么宽（已比源站 270px 提升 ≥1.8×），无法更高清。
# 只有「宽度 ≥ FLOOR_WIDTH 且理由非空」才降级为 WARN，其余一律 FAIL。
FLOOR_WIDTH = 500
KNOWN_SMALL = {
    ("Xingmu", "hbn_07.jpg"): "TMDB《第三者》最大竖版仅 500px（源站 270px，已提升 1.85×），无更高清素材；已同时取过 backdrop 兜底仍以此为准。",
    ("Xinwu",  "hbn_07.jpg"): "TMDB《女骑手》最大竖版仅 579px（源站 270px，已提升 2.14×），无更高清素材。",
    # 2026-10-01：为满足发布门禁「hero ≥15 张」把心屋候选 25 → 45（前 N 名不变，只补后段），
    # 补进来的三张已是 TMDB 对该片能给的最高清竖版（均 >源站 270px），无更好素材。
    ("Xinwu",  "hbn_13.jpg"): "TMDB《立冬的夏天》最大竖版仅 540px，无更高清素材（源站更低）。",
    ("Xinwu",  "hbn_14.jpg"): "TMDB《心灵家园》最大竖版仅 500px，无更高清素材（源站更低）。",
    ("Xinwu",  "hbn_18.jpg"): "TMDB《阿兹特克蝙蝠侠：帝国冲突》最大竖版仅 500px，无更高清素材（源站更低）。",
}


def image_size(b):
    """只靠文件头拿宽高，不依赖 PIL（判据要能在裸环境跑）。"""
    if b[:2] == b"\xff\xd8":
        i = 2
        while i < len(b) - 9:
            if b[i] != 0xFF:
                i += 1
                continue
            m = b[i + 1]
            if m in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h, w = struct.unpack(">HH", b[i + 5:i + 9])
                return w, h, "jpg"
            if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7:
                i += 2
                continue
            seg = struct.unpack(">H", b[i + 2:i + 4])[0]
            i += 2 + seg
        return 0, 0, "jpg"
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", b[16:24])
        return w, h, "png"
    if b[:4] == b"RIFF" and b[8:12] == b"WEBP":
        if b[12:16] == b"VP8X":
            w = int.from_bytes(b[24:27], "little") + 1
            h = int.from_bytes(b[27:30], "little") + 1
            return w, h, "webp"
        return 0, 0, "webp"
    if b[:6] in (b"GIF87a", b"GIF89a"):
        w, h = struct.unpack("<HH", b[6:10])
        return w, h, "gif"
    return 0, 0, None


def check_dir(d, label, min_width=None):
    min_width = MIN_WIDTH if min_width is None else min_width
    problems = []
    warns = []
    mp = os.path.join(d, "hbn_manifest.json")
    if not os.path.exists(mp):
        return ["INV-1 manifest 不存在：%s" % mp]
    man = json.load(open(mp, encoding="utf-8"))
    if len(man) < MIN_ENTRIES:
        problems.append("INV-1 manifest 仅 %d 条 < %d" % (len(man), MIN_ENTRIES))
    vals = list(man.values())
    if len(set(vals)) != len(vals):
        problems.append("INV-2 manifest 文件名有重复")

    files = sorted(f for f in os.listdir(d) if not f.endswith(".json"))
    refs = set(vals)
    miss = sorted(refs - set(files))
    orphan = sorted(set(files) - refs)
    if miss:
        problems.append("INV-2 manifest 引用了不存在的文件：%s" % miss)
    if orphan:
        problems.append("INV-3 目录里有未被引用的孤儿文件：%s" % orphan)

    narrow = []
    small = []
    badmagic = []
    widths = []
    for f in files:
        p = os.path.join(d, f)
        sz = os.path.getsize(p)
        b = open(p, "rb").read(65536)
        w, h, k = image_size(b)
        widths.append(w)
        if not k:
            badmagic.append(f)
            continue
        ext = f.rsplit(".", 1)[-1].lower()
        if ext != k and not (ext == "jpeg" and k == "jpg"):
            problems.append("INV-5 扩展名 %s ≠ 实际 %s（%s）" % (ext, k, f))
        if w < min_width:
            why = KNOWN_SMALL.get((label, f))
            if why and w >= FLOOR_WIDTH:
                warns.append("INV-4(白名单) %s=%dpx —— %s" % (f, w, why))
            else:
                narrow.append("%s=%dpx" % (f, w))
        if sz < MIN_BYTES:
            small.append("%s=%dB" % (f, sz))
    if badmagic:
        problems.append("INV-5 魔数非法：%s" % badmagic)
    if narrow:
        problems.append("INV-4 宽度 < %d：%s" % (min_width, narrow))
    if small:
        problems.append("INV-6 字节 < %d：%s" % (MIN_BYTES, small))

    print("  [%s] 文件 %d 个 | 宽度 min=%s max=%s 中位=%s"
          % (label, len(files),
             min(widths) if widths else "-", max(widths) if widths else "-",
             sorted(widths)[len(widths) // 2] if widths else "-"))
    for w in warns:
        print("    WARN " + w)
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=ROOT_DEFAULT)
    ap.add_argument("--dir", default=None, help="只检单个目录（负向对照）")
    ap.add_argument("--min-width", type=int, default=MIN_WIDTH)
    a = ap.parse_args()
    mw = a.min_width

    fails = []
    if a.dir:
        fails += check_dir(a.dir, os.path.basename(a.dir.rstrip("/\\")), mw)
    else:
        for app in APPS:
            d = os.path.join(a.root, "Apps", app, "HeroBundled")
            if not os.path.isdir(d):
                print("  [%s] 无 HeroBundled" % app)
                continue
            fails += ["[%s] %s" % (app, x) for x in check_dir(d, app, mw)]
        # INV-7/8 只跟源码有关，与 --dir 负向对照无关
        srcbad = check_hero_source(a.root)
        if srcbad:
            fails += srcbad
            for x in srcbad:
                print("  [选片口径] FAIL " + x)
        else:
            print("  [选片口径] PASS（能播放 + 高清 + 15 张，三项判据均在 HomeView 选片区间内）")

    print()
    if fails:
        print("VERDICT: FAIL（%d 项）" % len(fails))
        for f in fails:
            print("  - " + f)
        return 1
    print("VERDICT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
