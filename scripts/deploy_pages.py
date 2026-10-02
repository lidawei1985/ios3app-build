#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把本地文件推到 gh-pages（不跑完整 CI，用来秒更新安装页）。

用法：python deploy_pages.py <本地文件> [在仓库里的路径，默认 scripts/pages 下的同名文件]
       python deploy_pages.py --signed 0|1 --until 2027-01-01   # 改 update.json 的签名状态

为什么单独有这个脚本：CI 每次跑要十几分钟还得出包，改一行安装页不值得跑一遍。
坑（2026-10-01）：gh api 的 contents 接口必须带 sha 才能覆盖已有文件，否则 422。
"""
import base64, json, subprocess, sys

REPO = "lidawei1985/ios3app-build"
BRANCH = "gh-pages"
PAGES_DIR = "scripts/pages"

sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def gh(args, **kw):
    return subprocess.run(["gh", "api"] + args, capture_output=True, text=True,
                          errors="ignore", **kw)


def remote_sha(path):
    r = gh([f"repos/{REPO}/contents/{path}?ref={BRANCH}", "--jq", ".sha"])
    return r.stdout.strip() or None


def put(path, data: bytes, msg):
    sha = remote_sha(path)
    args = ["-X", "PUT", f"repos/{REPO}/contents/{path}",
            "-f", f"message={msg}", "-f", f"branch={BRANCH}",
            "-f", "content=" + base64.b64encode(data).decode()]
    if sha:
        args += ["-f", f"sha={sha}"]
    r = gh(args, timeout=180)
    if r.returncode != 0:
        print("FAIL", path, r.stderr[:300])
        return False
    print("OK  ", path, "(%d 字节)" % len(data))
    return True


def set_signed(flag: bool, until: str):
    r = gh([f"repos/{REPO}/contents/update.json?ref={BRANCH}", "--jq", ".content"])
    j = json.loads(base64.b64decode(r.stdout.strip()).decode())
    j["signed"] = flag
    j["signedUntil"] = until
    return put("update.json", json.dumps(j, ensure_ascii=False, indent=1).encode(),
               f"pages: signed={flag}")


def main():
    if "--signed" in sys.argv:
        i = sys.argv.index("--signed")
        flag = sys.argv[i + 1] == "1"
        until = sys.argv[sys.argv.index("--until") + 1] if "--until" in sys.argv else ""
        sys.exit(0 if set_signed(flag, until) else 1)

    files = []
    for a in sys.argv[1:]:
        if "/" in a or "\\" in a:
            local, _, remote = a.partition(":")
            files.append((local, remote or local.split("/")[-1]))
        else:
            files.append((f"{PAGES_DIR}/{a}", a))
    ok = True
    for local, remote in files:
        with open(local, "rb") as f:
            ok &= put(remote, f.read(), "pages: 更新 " + remote)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
