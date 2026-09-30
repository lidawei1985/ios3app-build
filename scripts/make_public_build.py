# -*- coding: utf-8 -*-
"""生成/更新「公开构建中转仓」，借公共仓库免费的 macOS runner 出 IPA。

为什么存在（2026-09-23）：
  私有仓 lidawei1985/ios-three-apps 的 GitHub Actions 因账号计费停摆
  （check-run 注解：recent account payments have failed or your spending limit needs to be increased），
  Job 在启动前就被拒（steps=0）。公共仓库的 standard runner 免费且不消耗额度 → 用中转仓出包。

铁律（本脚本用「安全门」强制，扫到即中止，绝不推）：
  夜航（成人）的一切资源都不得进入公开仓库：
    - Packages/.../Resources/yehang_feed_snapshot.json   （成人片单）
    - Packages/.../Resources/adult_live.m3u              （成人直播源表）
    - Packages/.../Resources/builtin_adult_curated.json  （成人采集站列表 → 清空为 {"sites":[]}）
    - Apps/Yehang/                                       （含 15 张成人主视觉图）
  星幕/心屋快照里出现的 "adult" 若只是英文影评正文单词（young adult novel 等）→ 允许。

用法：
  python scripts/make_public_build.py            # 干跑：只检查 + 报告要推什么
  python scripts/make_public_build.py --go       # 真推（出口自动判定：代理活着走代理，否则直连）
  python scripts/make_public_build.py --go --repo lidawei1985/ios3app-build
  FC_GIT_PROXY="" python scripts/make_public_build.py --go     # 强制直连
"""
import io
import os
import re
import shutil
import socket
import subprocess
import sys
import tarfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO = "lidawei1985/ios3app-build"
WORK = os.path.join(os.environ.get("TEMP", "/tmp"), "build-pub")

# ── 出口自动判定（2026-09-24 修「写死代理 → 代理一关就永远推不动」）──
# 原实现写死 `-c http.proxy=http://127.0.0.1:7897`：2026-09-24 实测本机
# ProxyEnable=0 且 7897 无监听，push 直接静默 FAIL（脚本还把 git 的报错吞了）。
# 铁律：出口每次实推前真实探测——端口活着才用代理，否则直连。
#   FC_GIT_PROXY 未设置 → 自动探测；="" → 强制直连；=某地址 → 用该地址。
_PROXY_ENV = os.environ.get("FC_GIT_PROXY")
DEFAULT_PROXY = "http://127.0.0.1:7897"


def _port_alive(host, port, timeout=0.6):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def pick_proxy():
    """返回 (proxy_url_or_None, 判定理由)。"""
    if _PROXY_ENV is not None and not _PROXY_ENV.strip():
        return None, "FC_GIT_PROXY 显式置空 → 强制直连"
    if _PROXY_ENV:
        return _PROXY_ENV.strip(), "FC_GIT_PROXY 指定"
    host_port = DEFAULT_PROXY.split("//", 1)[-1]
    host = host_port.split(":")[0]
    port = int(host_port.split(":")[1])
    if _port_alive(host, port):
        return DEFAULT_PROXY, "本机 %s 在监听 → 走代理" % host_port
    return None, "本机 %s 未监听 → 直连（GitHub 直连本机实测可用）" % host_port

# ── 必须剔除的（相对 ROOT）──
DROP_FILES = [
    "Packages/FilmCore/Sources/FilmCore/Resources/yehang_feed_snapshot.json",
    "Packages/FilmCore/Sources/FilmCore/Resources/adult_live.m3u",
    # 成人采集站列表：整份删掉（比"清空"更干净——文件名本身就含 adult，
    # 留在公开仓里语义歧义；星幕/心屋不引用它，代码侧有兜底）。
    "Packages/FilmCore/Sources/FilmCore/Resources/builtin_adult_curated.json",
    "build",        # 构建缓存目录
]
DROP_DIRS = ["Apps/Yehang"]
EMPTY_JSON: list = []      # 保留占位：以后需要"清空而非删除"的文件放这里
# 内部管理/交接文档：公开无意义且暴露内部信息 → 一并剔除
DROP_INTERNAL = [
    "ARC_REPORT.md", "arc_report.json", "PROJECT.md", "HANDOVER.md",
    "project.identity.json", "docs/SIGNING_AND_RELEASE.md",
    "CURRENT.md", "INSTRUCTION_LEDGER.md",
]


def sh(cmd, cwd=None, check=True, capture=True, env=None):
    r = subprocess.run(cmd, cwd=cwd or ROOT, shell=isinstance(cmd, str),
                       capture_output=capture, text=True, encoding="utf-8", errors="replace",
                       env=env)
    if check and r.returncode != 0:
        print("[cmd FAIL]", cmd)
        print((r.stdout or "")[-2000:], (r.stderr or "")[-2000:])
        raise SystemExit(1)
    return r


def export():
    """把 HEAD 导出到干净目录（不含 .git / 未提交改动）。

    坑（2026-09-23 实测）：不要用 shell `tar -x -C "F:\\...\\build-pub"`——
    Windows 盘符里的冒号会被 tar 当成「远程主机」语法，报
    `tar: F:\\...: Cannot open: No such file or directory`。改用 Python tarfile。
    """
    if os.path.isdir(WORK):
        shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    r = subprocess.run(["git", "archive", "HEAD"], cwd=ROOT, capture_output=True)
    if r.returncode != 0:
        raise SystemExit("git archive 失败：%s" % r.stderr.decode("utf-8", "replace"))
    with tarfile.open(fileobj=io.BytesIO(r.stdout)) as tf:
        tf.extractall(WORK, filter="data")
    return WORK


def sanitize(work):
    """剔除成人资源 + 收窄构建范围到星幕/心屋。"""
    for f in DROP_FILES:
        p = os.path.join(work, f)
        if os.path.isdir(p):
            shutil.rmtree(p, ignore_errors=True)
            print("  [del-dir ]", f)
        elif os.path.exists(p):
            os.remove(p)
            print("  [del-file]", f)
    for d in DROP_DIRS:
        p = os.path.join(work, d)
        if os.path.isdir(p):
            shutil.rmtree(p, ignore_errors=True)
            print("  [del-dir ]", d)
    for f in EMPTY_JSON:
        p = os.path.join(work, f)
        if os.path.exists(p):
            io.open(p, "w", encoding="utf-8").write('{\n  "sites": []\n}\n')
            print("  [emptied ]", f)
    for f in DROP_INTERNAL:
        p = os.path.join(work, f)
        if os.path.exists(p):
            os.remove(p)
            print("  [del-doc ]", f)

    # project.yml：删 YehangISO target + scheme
    p = os.path.join(work, "project.yml")
    s = io.open(p, encoding="utf-8").read()
    if "  YehangISO:\n" in s and "schemes:\n" in s:
        s = s[:s.index("  YehangISO:\n")] + s[s.index("schemes:\n"):]
    s = s.replace("""  YehangISO:
    build:
      targets: { YehangISO: all }
    run:
      config: Debug
""", "")
    io.open(p, "w", encoding="utf-8").write(s)
    print("  [edit    ] project.yml → 仅 XingmuISO/XinwuISO")

    # workflow：整份换成「中转仓专用」版本
    #   旧做法（就地字符串替换私仓 workflow）在 2026-09-23 暴露问题：改动靠正则描述，
    #   一旦私仓 workflow 改名/改版就静默失配，且产物仍是明文上传（公开仓泄密钥）。
    tpl = os.path.join(ROOT, "scripts", "ci", "relay_build_ipa.yml")
    dst = os.path.join(work, ".github/workflows/build-ipa.yml")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(tpl, dst)
    print("  [replace ] workflow ← scripts/ci/relay_build_ipa.yml（两端 + 产物加密）")


def workflow_guard(work):
    """产物级安全门：中转仓 workflow 必须满足 4 条硬性特征，否则绝不推。

    （判据可执行、可反证：把模板改回明文上传/加回夜航，本函数立刻 FAIL。）
    """
    p = os.path.join(work, ".github/workflows/build-ipa.yml")
    if not os.path.exists(p):
        print("[安全门] ❌ 中转仓 workflow 缺失")
        return False
    s = io.open(p, encoding="utf-8").read()
    checks = [
        ("含加密步骤 art_encrypt.py", "art_encrypt.py" in s),
        ("上传的是加密产物", "artifact/*.ipa.enc" in s),
        ("不含夜航目标 YehangISO", "YehangISO" not in s),
        ("仅星幕/心屋两端", "for scheme in XingmuISO XinwuISO; do" in s),
    ]
    bad = [n for n, ok in checks if not ok]
    if bad:
        print("[安全门] ❌ workflow 校验未通过：", bad)
        return False
    print("[安全门] ✅ workflow 校验通过（两端构建/无夜航/产物加密上传）")
    return True


# 真·成人「数据」特征。注意：**不把「夜航」这个词本身当敏感词**——
# 代码注释/文档里写「夜航=adult 模式」属业务说明，公开不构成内容泄露；
# 红线是成人片单、成人图、成人直播源表、成人站列表这类**数据**。
HARD_PAT = re.compile(
    r"(yehang_feed_snapshot|adult_live\.m3u|builtin_adult_curated"
    r"|老司机|大奶子|成人视频|成人片|18禁|hentai|av女优|無修正|无修正)", re.I)
DATA_EXT = {".json", ".m3u", ".csv", ".tsv", ".srt", ".vtt"}
BIN_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".ico", ".zip", ".ipa", ".pdf"}


def security_gate(work):
    """安全门：只扫「数据类文件」的成人残留，命中即中止（返回 False）。

    为什么只扫数据类：2026-09-23 首版把 .swift/.md 也扫内容，结果 14 处全部是
    「注释里写到夜航/adult」这类业务说明的误报，把真数据信号淹了、还挡住了正常推送。
    """
    hits = []
    for dirpath, dirnames, filenames in os.walk(work):
        if ".git" in dirpath.split(os.sep):
            continue
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, work)
            ext = os.path.splitext(fn)[1].lower()
            if HARD_PAT.search(fn):                      # 文件名级（含图片名）
                hits.append("文件名: " + rel)
                continue
            if ext in BIN_EXT:
                continue
            if ext not in DATA_EXT:
                continue                                 # 代码/文档不扫内容
            try:
                with io.open(p, encoding="utf-8", errors="ignore") as f:
                    txt = f.read(4 * 1024 * 1024)        # 大文件抽前 4MB，足够命中特征
            except OSError:
                continue
            m = HARD_PAT.search(txt)
            if m:
                seg = txt[max(0, m.start() - 40):m.end() + 40].replace("\n", " ")
                hits.append("%s :: %s" % (rel, seg[:100]))
    if hits:
        print("\n[安全门] ❌ 扫到成人「数据」残留，已中止（绝不推公开仓）：")
        for h in hits[:20]:
            print("   -", h)
        return False
    print("\n[安全门] ✅ 数据层无成人残留（代码注释提及夜航=业务说明，允许）")
    return True


def stage(work):
    """建仓 + 暂存，返回 (总文件数, 本次变更数, 总体积 MB)。

    坑（2026-09-24）：原先在 push() 里才 `git add -A`，报告用
    `git ls-files -o`（只看未跟踪文件）→ 二次运行时全被跟踪，恒显示「0 个文件」，
    看着像「没东西可推」，实际有大改动。
    """
    sh("git init -q -b main", cwd=work, check=False)
    sh("git config user.email lidawei1985@users.noreply.github.com", cwd=work)
    sh("git config user.name ios3app-build", cwd=work)
    io.open(os.path.join(work, ".gitignore"), "w", encoding="utf-8").write(
        "build/\nDerivedData/\n*.xcuserdatad\n.DS_Store\n")
    sh("git add -A", cwd=work)
    total = len([x for x in sh("git ls-files", cwd=work).stdout.splitlines() if x.strip()])
    changed = len([x for x in sh("git diff --cached --name-only", cwd=work).stdout.splitlines() if x.strip()])
    size = sum(os.path.getsize(os.path.join(dp, f))
               for dp, _, fs in os.walk(work) for f in fs if ".git" not in dp.split(os.sep)) / 1048576
    return total, changed, size


def push(work, repo):
    env = dict(os.environ)
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
              "ALL_PROXY", "all_proxy", "GIT_PROXY_COMMAND"):
        env.pop(k, None)                      # 沙箱注入的死代理必须清掉，否则覆盖 -c 设置
    r = sh('git commit -q -m "iOS 星幕/心屋 免签构建源（公开中转，不含夜航数据）"',
           cwd=work, check=False, env=env)
    if r.returncode != 0:
        print("[git] 无新改动，跳过提交")
    sh("git remote remove origin", cwd=work, check=False, env=env)
    sh("git remote add origin https://github.com/%s.git" % repo, cwd=work, env=env)

    proxy, why = pick_proxy()
    print("[出口] %s" % why)
    px = proxy or ""
    r = sh("git -c http.proxy=%s -c https.proxy=%s -c http.version=HTTP/1.1 -c http.postBuffer=524288000 "
           "push -u origin main --force" % (px, px), cwd=work, check=False, env=env)
    if r.returncode != 0:
        print("\n[push FAIL] git 返回码 %d" % r.returncode)
        print((r.stdout or "")[-1500:])
        print((r.stderr or "")[-1500:])
        if not proxy:
            print("（当前为直连；若网络需代理，确认代理软件已启动后重跑，"
                  "或 FC_GIT_PROXY=http://127.0.0.1:端口 指定）")
        return False
    print("\n[push OK] → https://github.com/%s/actions" % repo)
    return True


def main():
    go = "--go" in sys.argv
    repo = REPO
    if "--repo" in sys.argv:
        repo = sys.argv[sys.argv.index("--repo") + 1]
    print("=" * 62)
    print("公开构建中转仓  %s  (go=%s)" % (repo, go))
    print("=" * 62)
    work = export()
    print("[1/3] 导出 HEAD → %s" % work)
    sanitize(work)
    print("[2/3] 安全门")
    if not security_gate(work):
        raise SystemExit(2)
    if not workflow_guard(work):
        raise SystemExit(2)
    total, changed, size = stage(work)
    print("[3/3] 待推：%d 个文件 / %.1f MB（本次变更 %d 个）" % (total, size, changed))
    if not go:
        print("\n（干跑结束。加 --go 才真推）")
        return
    if not push(work, repo):
        raise SystemExit(3)


if __name__ == "__main__":
    main()
