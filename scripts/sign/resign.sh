#!/bin/bash
# 给裸包（unsigned IPA）盖上你的开发者签名，产出能 OTA 直装的 IPA。
#
# 为什么不在 xcodebuild 里直接签：现有 CI 已经能稳定产出裸包，重签比重新 archive 快得多，
# 而且同一份产物可以反复重签（证书快到期时跑一遍就行，不用重新编译）。
#
# 需要：macOS + Xcode 命令行工具 + 钥匙串里已装好「Apple Distribution」证书。
# 用法： ./resign.sh <输入ipa> <输出ipa> <bundle id> <mobileprovision>
set -euo pipefail

IN="$1"; OUT="$2"; BID="$3"; PROFILE="$4"
SIGN_ID="${SIGN_ID:-Apple Distribution}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo ">> 解包 $IN"
unzip -q "$IN" -d "$TMP"
APP=$(find "$TMP/Payload" -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] || { echo "没找到 .app"; exit 1; }

echo ">> 装入描述文件"
cp "$PROFILE" "$APP/embedded.mobileprovision"

#  entitlements 必须和 profile 对得上，否则装得上但一开就闪退
echo ">> 提取 entitlements"
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" /dev/stdin <<< \
  "$(security cms -D -i "$PROFILE")" > "$TMP/ent.plist" 2>/dev/null || \
  security cms -D -i "$PROFILE" > "$TMP/profile.plist"

echo ">> 重签（--generate-entitlement-der 是 iOS 15+ 必需）"
codesign -f --timestamp=none --generate-entitlement-der \
  -s "$SIGN_ID" --entitlements "$TMP/ent.plist" "$APP"

echo ">> 校验签名"
codesign -v "$APP" && echo "签名有效"

echo ">> 打包 $OUT"
rm -f "$OUT"
(cd "$TMP" && zip -qry "$OUT" Payload)

echo ">> 完成: $OUT ($(du -h "$OUT" | cut -f1))"
