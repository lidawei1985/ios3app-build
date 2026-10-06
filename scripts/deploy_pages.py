#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把本地文件推到 gh-pages（不跑完整 CI，用来秒更新安装页）。

用法：python deploy_pages.py <本地文件> [在仓库里的路径，默认 scripts/pages 下的同名文件]
       python deploy_pages.py --signed 0|1 --until 2027-01-01   # 改 update.json 的签名状态

为什么单独有这个脚本：CI 每次跑要十几分钟还得出包，改一行安装页不值得跑一遍。
坑（2026-10-01）：gh api 的 contents 接口必须带 sha 才能覆盖已有文件，否则 422。
"""
import base64, json, os, subprocess, sys, tempfile

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
    # 坑（2026-10-01）：不能把 base64 直接拼进命令行 —— Windows 命令行上限 ~32KB，
    # Linux 单参数上限 128KB，大文件（feed JSON 几百 KB）必炸 WinError 206。
    # 解法：先写临时文件，用 gh 的 `-f content=@文件` 让它自己读。
    # 再一个坑：-f/--field 走表单编码，base64 里的 "+" 会被当成空格 → GitHub 报
    # "content is not valid Base64"。所以整个请求体用 JSON 文件 + --input 发。
    payload = {"message": msg, "branch": BRANCH,
               "content": base64.b64encode(data).decode()}
    if sha:
        payload["sha"] = sha
    fd, tmp = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    try:
        r = gh(["-X", "PUT", f"repos/{REPO}/contents/{path}", "--input", tmp],
               timeout=180)
    finally:
        os.unlink(tmp)
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
