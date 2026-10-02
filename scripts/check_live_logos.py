# -*- coding: utf-8 -*-
"""直播台标端到端机检（2026-10-01）。

背景：iOS 端一直没有台标，根因是 `M3UParser` 只取 `#EXTINF` 的频道名与 group-title，
把 `tvg-logo` 直接丢了；而云端直播表（与 TV 端星幕共用同一张）619/619 条**每条都带** tvg-logo。
本检把「表 -> 解析 -> 包内台标」整条链钉死，谁断一环就 FAIL。

判据（全部必须 PASS）：
  INV-1 包内快照存在、可解析、条目数 > 300
  INV-2 快照内每条 #EXTINF 都带 tvg-logo（覆盖率 100%）
  INV-3 每条 tvg-logo 指向 filmcollector-logos@main/NNNN.png（命名约定）
  INV-4 每个 NNNN 在 Apps/Xingmu/LiveLogo/NNNN.png 存在（包内命中 100%）
  INV-5 包内台标 PNG 魔数合法（\\x89PNG）
  INV-6 无孤儿：包内台标文件都被快照引用（允许白名单 + 理由）
  INV-7 Swift 侧解析链存在（LiveLoader.swift 含 extractAttr + tvg-logo + LiveChannel.logo）
  INV-8 Python 镜像解析（复刻 M3UParser 语义）得到 logo/group，与正则统计一致

负向对照（证明本检不是空转）：
  NEG-1 抹掉快照里第一条的 tvg-logo → INV-2/INV-4 必须 FAIL
  NEG-2 删掉一张包内台标 → INV-4/INV-6 必须 FAIL
用法：python scripts/check_live_logos.py            # 正常检（应全 PASS）
      python scripts/check_live_logos.py --negctl   # 负向对照（应检出 FAIL）
"""
import argparse
import os
import re
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SNAPSHOT = os.path.join(ROOT, "Packages/FilmCore/Sources/FilmCore/Resources/normal_live.m3u")
LOGODIR = os.path.join(ROOT, "Apps/Xingmu/LiveLogo")
LOADER = os.path.join(ROOT, "Packages/FilmCore/Sources/FilmCore/Live/LiveLoader.swift")

RE_EXTINF = re.compile(r"^#EXTINF")
RE_LOGO = re.compile(r'tvg-logo="([^"]*)"')
RE_LOGO_NUM = re.compile(r"filmcollector-logos@main/(\d{4})\.png")
RE_GROUP = re.compile(r'group-title="([^"]*)"')
RE_CHNO = re.compile(r'tvg-chno="(\d+)"')
RE_NAME = re.compile(r",([^,]*)$")

# 孤儿白名单：包内保留名册全量 332 张台标；有 3 台本轮无可用源（云端构建缺源 3 台）→ 表内暂无引用。
# 保留其台标是为「下轮补到源后立刻有台标」，属故意保留而非遗漏（故须写理由，非 0 也放行）。
ORPHAN_OK = {
    "0174": "名册台「安多电视」本轮无可用源（TV 云端构建缺源 3 台之一）",
    "0226": "名册台「楚雄新闻综合」本轮无可用源",
    "0702": "名册台「ABN中华」本轮无可用源",
}
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


class Checker:
    def __init__(self, snapshot=SNAPSHOT, logodir=LOGODIR):
        self.snapshot = snapshot
        self.logodir = logodir
        self.fails, self.warns = [], []

    def fail(self, inv, msg):
        self.fails.append((inv, msg))

    def warn(self, inv, msg):
        self.warns.append((inv, msg))

    # ---- INV-1 / INV-2 / INV-3 ----
    def check_snapshot(self):
        if not os.path.exists(self.snapshot):
            self.fail("INV-1", "包内快照不存在: %s" % self.snapshot)
            return [], 0
        text = open(self.snapshot, encoding="utf-8", errors="replace").read()
        ext = [l for l in text.splitlines() if RE_EXTINF.match(l)]
        if len(ext) <= 300:
            self.fail("INV-1", "条目数 %d <= 300" % len(ext))
        missing = [l for l in ext if not RE_LOGO.search(l)]
        if missing:
            self.fail("INV-2", "%d/%d 条 #EXTINF 缺 tvg-logo（例：%s）"
                      % (len(missing), len(ext), missing[0][:80]))
        bad = []
        for l in ext:
            m = RE_LOGO.search(l)
            if m and not RE_LOGO_NUM.search(m.group(1)):
                bad.append(m.group(1))
        if bad:
            self.fail("INV-3", "%d 条 tvg-logo 不符合 filmcollector-logos@main/NNNN.png（例：%s）"
                      % (len(bad), bad[0]))
        return ext, len(ext)

    # ---- INV-4 / INV-5 / INV-6 ----
    def check_logos(self, ext):
        refs = set()
        for l in ext:
            m = RE_LOGO.search(l)
            if m:
                mm = RE_LOGO_NUM.search(m.group(1))
                if mm:
                    refs.add(mm.group(1))
        if not os.path.isdir(self.logodir):
            self.fail("INV-4", "台标目录不存在: %s" % self.logodir)
            return refs
        files = set(f[:4] for f in os.listdir(self.logodir) if re.match(r"^\d{4}\.png$", f))
        miss = sorted(refs - files)
        if miss:
            self.fail("INV-4", "表引用但包内缺台标 %d 张：%s" % (len(miss), miss[:12]))
        # 魔数
        badmagic = []
        for n in sorted(files):
            p = os.path.join(self.logodir, n + ".png")
            with open(p, "rb") as f:
                if f.read(8) != PNG_MAGIC:
                    badmagic.append(n)
        if badmagic:
            self.fail("INV-5", "%d 张台标 PNG 魔数不合法：%s" % (len(badmagic), badmagic[:12]))
        # 孤儿
        orphan = sorted(files - refs - set(ORPHAN_OK))
        if orphan:
            self.fail("INV-6", "包内孤儿台标 %d 张（未被表引用且不在白名单）：%s"
                      % (len(orphan), orphan[:12]))
        return refs

    # ---- INV-7 ----
    def check_swift(self):
        if not os.path.exists(LOADER):
            self.fail("INV-7", "LiveLoader.swift 不存在")
            return
        src = open(LOADER, encoding="utf-8", errors="replace").read()
        for needle, why in [("public let logo: URL?", "LiveChannel.logo 字段"),
                            ("extractAttr", "通用属性抽取函数"),
                            ('"tvg-logo"', "tvg-logo 解析调用")]:
            if needle not in src:
                self.fail("INV-7", "LiveLoader.swift 缺 %s（%s）" % (why, needle))
        ui = os.path.join(ROOT, "Packages/FilmCore/Sources/FilmUI/Components/LiveLogo.swift")
        if not os.path.exists(ui):
            self.fail("INV-7", "LiveLogo.swift 组件不存在")
        else:
            u = open(ui, encoding="utf-8", errors="replace").read()
            if "LiveLogos.key" not in u:
                self.fail("INV-7", "LiveLogo.swift 未用 LiveLogos.key 解析包内键")

    # ---- INV-8：Python 镜像 M3UParser 语义 ----
    @staticmethod
    def mirror_parse(text):
        """复刻 LiveLoader.swift 的 M3UParser.parse 语义（忽略 txt 分支，表为纯 M3U）。

        去重键 = 名 + URL（与 Swift 侧一致）：同一路流被两个台名引用时两条都保留，
        仅完全相同的 (名,URL) 才去重。
        """
        out, pending = [], None
        seen = set()
        for line in text.splitlines():
            s = line.strip()
            if not s:
                continue
            if s.startswith("#EXTINF"):
                name = s.split(",", 1)[-1].strip() if "," in s else "未命名频道"
                g = RE_GROUP.search(s)
                lg = RE_LOGO.search(s)
                cn = RE_CHNO.search(s)
                pending = {"name": name, "group": g.group(1) if g else "",
                           "logo": lg.group(1) if lg else None,
                           "chno": int(cn.group(1)) if cn else None}
            elif not s.startswith("#"):
                if pending is not None:
                    key = pending["name"] + "\x01" + s
                    if key not in seen:
                        seen.add(key)
                        out.append(dict(pending, url=s))
                pending = None
        return out

    def check_mirror(self, ext):
        text = open(self.snapshot, encoding="utf-8", errors="replace").read()
        chans = self.mirror_parse(text)
        if len(chans) != len(ext):
            self.fail("INV-8", "镜像解析条数 %d != 表内 #EXTINF 条数 %d（解析在吞行）" % (len(chans), len(ext)))
        nologo = [c for c in chans if not c["logo"]]
        if nologo:
            self.fail("INV-8", "镜像解析后有 %d 条无 logo" % len(nologo))
        nogroup = [c for c in chans if not c["group"]]
        if nogroup:
            self.warn("INV-8", "%d 条无 group-title" % len(nogroup))
        bases = set(re.sub(r"·备\d+$", "", c["name"]) for c in chans)
        chnos = set(c["chno"] for c in chans if c["chno"])
        # 表内台数（按 chno 去重） = 解析后去重台名数，否则有整台被吞
        table_chnos = set(int(x) for x in RE_CHNO.findall(text))
        if len(table_chnos) != len(bases):
            lost = sorted(table_chnos)
            self.warn("INV-8", "表内 chno %d 个 vs 解析后去重台名 %d 个（差 %d，同名归并或吞台）"
                      % (len(table_chnos), len(bases), len(table_chnos) - len(bases)))
        print("  镜像解析：条目 %d ｜ 去重台 %d ｜ 带 logo %d ｜ chno %d ｜ 分组数 %d"
              % (len(chans), len(bases), len(chans) - len(nologo), len(chnos),
                 len(set(c["group"] for c in chans if c["group"]))))
        return chans

    def run(self):
        print("[检] 快照=%s" % os.path.relpath(self.snapshot, ROOT))
        print("[检] 台标=%s" % os.path.relpath(self.logodir, ROOT))
        ext, n = self.check_snapshot()
        print("  条目 %d" % n)
        self.check_logos(ext)
        self.check_swift()
        self.check_mirror(ext)

    def report(self, title="机检"):
        print("-" * 60)
        for inv, m in self.warns:
            print("  WARN [%s] %s" % (inv, m))
        for inv, m in self.fails:
            print("  FAIL [%s] %s" % (inv, m))
        if self.fails:
            print("%s：FAIL（%d 项）" % (title, len(self.fails)))
            return 1
        print("%s：PASS（0 FAIL，%d WARN）" % (title, len(self.warns)))
        return 0


def negctl():
    """负向对照：证明本检能检出问题（否则是空转）。"""
    rc = 0
    # NEG-1：抹掉第一条 tvg-logo
    with tempfile.TemporaryDirectory() as td:
        snap = os.path.join(td, "normal_live.m3u")
        text = open(SNAPSHOT, encoding="utf-8", errors="replace").read()
        lines = text.splitlines()
        for i, l in enumerate(lines):
            if RE_EXTINF.match(l):
                lines[i] = RE_LOGO.sub('tvg-logo=""', l, count=1).replace('tvg-logo=""', "")
                break
        open(snap, "w", encoding="utf-8").write("\n".join(lines) + "\n")
        c = Checker(snapshot=snap)
        c.run()
        got = [f for f in c.fails if f[0] in ("INV-2", "INV-4")]
        print("[NEG-1] 抹掉首条 tvg-logo -> 检出 %s" % (got[0] if got else "无（不合格！）",))
        rc |= 0 if got else 1
    # NEG-2：删掉一张包内台标
    with tempfile.TemporaryDirectory() as td:
        ld = os.path.join(td, "LiveLogo")
        shutil.copytree(LOGODIR, ld)
        victim = sorted(os.listdir(ld))[0]
        os.remove(os.path.join(ld, victim))
        c = Checker(logodir=ld)
        c.run()
        got = [f for f in c.fails if f[0] == "INV-4"]
        print("[NEG-2] 删掉包内 %s -> 检出 %s" % (victim, got[0] if got else "无（不合格！）"))
        rc |= 0 if got else 1
    print("-" * 60)
    print("负向对照：%s" % ("PASS（两项都被检出）" if rc == 0 else "FAIL"))
    return rc


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--negctl", action="store_true")
    a = ap.parse_args()
    if a.negctl:
        sys.exit(negctl())
    c = Checker()
    c.run()
    sys.exit(c.report())
