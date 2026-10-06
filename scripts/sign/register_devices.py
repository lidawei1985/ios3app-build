#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 UDID 登记到你的 Apple 开发者账号（App Store Connect API）。

个人号（¥688）的硬规则：一台设备没登记就装不上我们签的包，一年最多 100 台。
所以用户第一次来，必须先登记 —— 这一步由 Cloudflare Worker 收 UDID、本脚本登记。

为什么用 API 密钥而不是账号密码：密钥不用双因素验证码，CI 里能无人值守跑，
而且可以随时吊销，不用把 Apple ID 密码交给任何脚本。

依赖：pip install pyjwt cryptography requests
环境变量：
  ASC_KEY_ID    密钥 ID
  ASC_ISSUER_ID Issuer ID
  ASC_P8        .p8 文件内容（CI 里放 secret；本地可用 --p8 指向文件）

用法：
  python register_devices.py <UDID> [UDID...]        # 登记
  python register_devices.py --list                  # 看还剩多少名额
"""
import argparse, json, os, sys, time

import jwt
import requests

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
API = "https://api.appstoreconnect.apple.com/v1"


def token(key_id, issuer_id, p8):
    """JWT 签名，有效期最多 20 分钟，够跑完一次 CI。"""
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer_id, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"},
        p8, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"},
    )


class ASC:
    def __init__(self):
        self.h = {"Authorization": "Bearer " + token(
            os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], self._p8()),
            "Content-Type": "application/json"}

    @staticmethod
    def _p8():
        if os.environ.get("ASC_P8"):
            return os.environ["ASC_P8"]
        with open(os.environ.get("ASC_P8_FILE", "AuthKey.p8")) as f:
            return f.read()

    def get(self, path, **params):
        return requests.get(API + path, headers=self.h, params=params, timeout=30)

    def post(self, path, payload):
        return requests.post(API + path, headers=self.h,
                             data=json.dumps(payload), timeout=30)

    def devices(self):
        out, url = [], "/devices?limit=200"
        while url:
            r = self.get(url if url.startswith("/") else url.replace(API, ""))
            r.raise_for_status()
            j = r.json()
            out += [d["attributes"]["udid"] for d in j["data"]]
            url = j.get("links", {}).get("next", "")
        return out

    def register(self, udid):
        r = self.post("/devices", {"data": {
            "type": "devices",
            "attributes": {"name": "iOS3APP-" + udid[-6:], "udid": udid,
                           "platform": "IOS"},
        }})
        # 已存在会报 409，不算错 —— 重复登记不该让流水线红
        if r.status_code == 409:
            return "已存在"
        r.raise_for_status()
        return "已登记"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("udids", nargs="*")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    asc = ASC()
    if a.list:
        ds = asc.devices()
        print("已登记 %d 台，剩余名额 %d" % (len(ds), 100 - len(ds)))
        return
    for u in a.udids:
        try:
            print(u, "→", asc.register(u))
        except Exception as e:
            print(u, "→ 失败:", getattr(e, "response", None) and
                  e.response.text[:200] or e)
            sys.exit(1)


if __name__ == "__main__":
    main()
