# -*- coding: utf-8 -*-
"""构建产物加密（在公开中转仓的 macOS runner 上跑）。

背景（2026-09-23）：公开仓的 artifact 任何人都能下载，而 IPA 里嵌有 FC_VAULT_KEY；
所以产物必须先加密再上传。口令只在 GitHub Secrets 与用户本机凭据册里，绝不进仓、绝不进产物。

算法：PBKDF2-HMAC-SHA256(120000) 派生 32 字节 key → AES-256-CBC。
salt/iv 随密文一起公开（它们不是秘密），少了口令一样解不开。
解密参数写在 artifact/art.key.json 里，与本脚本配套。
"""
import glob
import hashlib
import json
import os
import subprocess
import sys

ITERS = 120000


def main():
    pw = os.environ.get("ART_PASS", "")
    if len(pw) < 12:
        print("::error::ART_PASS 缺失或过短 —— 公开仓禁止明文上传 IPA")
        return 1

    os.makedirs("artifact", exist_ok=True)
    salt = os.urandom(16)
    iv = os.urandom(16)
    key = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), salt, ITERS, 32)

    meta = {
        "kdf": "pbkdf2-hmac-sha256",
        "iterations": ITERS,
        "salt_hex": salt.hex(),
        "cipher": "aes-256-cbc",
        "iv_hex": iv.hex(),
        "note": "salt/iv 公开无妨；口令在 Codemagic/GitHub Secret 与本机凭据册",
    }
    with open(os.path.join("artifact", "art.key.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)

    files = sorted(glob.glob(os.path.join("artifact", "*.ipa")))
    if not files:
        print("::error::artifact 下没有 .ipa，无法加密上传")
        return 1

    # 反证需要原文比对：先留一份副本（原文件加密后会被删除）
    import shutil, filecmp
    probe_orig = files[0] + ".probe-orig"
    shutil.copyfile(files[0], probe_orig)

    for f in files:
        out = f + ".enc"
        subprocess.run(
            ["openssl", "enc", "-aes-256-cbc", "-nosalt",
             "-K", key.hex(), "-iv", iv.hex(), "-in", f, "-out", out],
            check=True,
        )
        print("encrypted %s -> %s (%d bytes)" % (f, out, os.path.getsize(out)))
        os.remove(f)

    # 双端验证（本脚本自带反证）：故意用错口令解密。
    # 2026-09-26 根修：只看 openssl 退出码不充分——AES-CBC+PKCS#7 下错误 key 解密
    # 有 ~1/256 概率 padding 碰撞合法 → returncode=0 被误判「加密未生效」（CI 实挂过一次）。
    # 正解：错口令解出到临时文件，与原文逐字节比对——内容相同才算真「解开了」。
    probe = files[0] + ".enc"
    wrong_out = probe + ".wrong"
    bad = subprocess.run(
        ["openssl", "enc", "-d", "-aes-256-cbc", "-nosalt",
         "-K", hashlib.pbkdf2_hmac("sha256", b"wrong-pass", salt, ITERS, 32).hex(),
         "-iv", iv.hex(), "-in", probe, "-out", wrong_out],
        capture_output=True,
    )
    same = (bad.returncode == 0 and os.path.exists(wrong_out)
            and filecmp.cmp(probe_orig, wrong_out, shallow=False))
    for t in (probe_orig, wrong_out):
        if os.path.exists(t):
            os.remove(t)
    if same:
        print("::error::反证失败：错误口令竟然解开了，加密未生效")
        return 1
    print("negative check OK: 错误口令无法解密（说明加密确实生效）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
