# -*- coding: utf-8 -*-
"""github.com:443 直连被墙时的兜底推送：用 api.github.com 的 Git Data API
把本地 HEAD 的整棵树对齐到远端 main（与仓库既有做法 b847fda 一致）。

用法：python push_via_api.py            # 预览（dry-run）
      python push_via_api.py --go       # 真推
"""
import base64, json, subprocess, sys, urllib.request

OWNER_REPO = "lidawei1985/ios-three-apps"
BRANCH = "main"
GO = "--go" in sys.argv


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


def api(path, method="GET", payload=None, token=""):
    url = "https://api.github.com" + path
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "wb-push")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        # 坑（2026-09-23 踩过）：不显式抛错时 422 会被当成"空结果"，表现为"什么都没推"却报成功
        print("HTTP %s %s" % (e.code, e.read().decode()[:500]))
        raise


def local_base(parent_sha):
    """git diff 需要一个**本地存在**的 commit。远端新 sha（API 推送出来的）本地没有，
    直接 git diff <远端sha> HEAD 会静默返回空 → 必须回退到本地已知的对应提交。"""
    ok = subprocess.run(f"git rev-parse --verify -q {parent_sha}^{{commit}}",
                        shell=True, capture_output=True, text=True).stdout.strip()
    if ok:
        return parent_sha
    for cand in sh("git log --format=%H").split():
        if subprocess.run(f"git merge-base --is-ancestor {cand} HEAD",
                          shell=True, capture_output=True).returncode == 0:
            return cand
    return "HEAD~1"


token = sh("gh auth token")
if len(token) < 20:
    print("拿不到 gh token，退出"); sys.exit(1)

ref = api(f"/repos/{OWNER_REPO}/git/ref/heads/{BRANCH}", token=token)
parent = ref["object"]["sha"]
base_tree = api(f"/repos/{OWNER_REPO}/git/commits/{parent}", token=token)["tree"]["sha"]
print("远端 main 当前 =", parent[:9], " base_tree =", base_tree[:9])

# 本地 HEAD 相对远端 main 的文件级差异（含增删改）
out = sh(f'git diff --name-status {parent} HEAD')
changes = [l.split("\t") for l in out.splitlines() if l.strip()]
print("待同步文件数 =", len(changes))
for c in changes[:15]:
    print("  ", c[0], c[1])
if len(changes) > 15:
    print("   ...")

if not GO:
    print("\n[干跑] 加 --go 才真推")
    sys.exit(0)

entries, n_blob = [], 0
for c in changes:
    st, path = c[0], c[-1]
    if st.startswith("D"):
        entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
        continue
    raw = subprocess.run(f'git show HEAD:"{path}"', shell=True, capture_output=True).stdout
    mode = "100755" if sh(f'git ls-tree HEAD -- "{path}"').startswith("100755") else "100644"
    blob = api(f"/repos/{OWNER_REPO}/git/blobs",
               method="POST", token=token,
               payload={"content": base64.b64encode(raw).decode(), "encoding": "base64"})
    entries.append({"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]})
    n_blob += 1
    local_sha = sh(f'git rev-parse HEAD:"{path}"')
    flag = "OK " if local_sha == blob["sha"] else "≠  "
    if flag != "OK ":
        print("  !! blob sha 不一致:", path, local_sha[:9], blob["sha"][:9])
print("上传 blob =", n_blob)

tree = api(f"/repos/{OWNER_REPO}/git/trees", method="POST", token=token,
           payload={"base_tree": base_tree, "tree": entries})
print("新 tree =", tree["sha"][:9], " 与本地 HEAD tree 一致:",
      tree["sha"] == sh("git rev-parse HEAD^{tree}"))

commit = api(f"/repos/{OWNER_REPO}/git/commits", method="POST", token=token, payload={
    "message": "sync: align remote tree with local HEAD（整页取色+雾化二次收窄+方案A分类页+详情页影院式+命名ISO/apk）",
    "tree": tree["sha"], "parents": [parent]})
print("新 commit =", commit["sha"][:9])

api(f"/repos/{OWNER_REPO}/git/refs/heads/{BRANCH}", method="PATCH", token=token,
    payload={"sha": commit["sha"], "force": False})
print("✅ 远端 main 已更新 →", commit["sha"])
print("   新 sha 写入本地:", sh(f"git fetch origin && git log --oneline -1 origin/main"))
