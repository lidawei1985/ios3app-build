#!/usr/bin/env bash
# build_all.sh — macOS 端一键构建三款 iOS App + 测试（在 Mac / Xcode 环境执行）
# 依赖：Xcode 15+、xcodegen（brew install xcodegen）
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== 1) 生成 Xcode 工程 =="
xcodegen generate

echo "== 2) 三 Target 编译（iOS Simulator） =="
for scheme in XingmuISO XinwuISO YehangISO; do
  echo "-- build $scheme"
  xcodebuild -project FilmThree.xcodeproj -scheme "$scheme" \
    -destination 'generic/platform=iOS Simulator' build
done

echo "== 3) 单元测试（FilmCoreTests：契约/隔离/台账/去重） =="
xcodebuild -project FilmThree.xcodeproj -scheme XingmuISO \
  -destination 'platform=iOS Simulator,name=iPhone 15' test

echo "== 4) Archive（签名就绪后执行；Team 见 project.yml DEVELOPMENT_TEAM） =="
for scheme in XingmuISO XinwuISO YehangISO; do
  xcodebuild -project FilmThree.xcodeproj -scheme "$scheme" \
    -destination 'generic/platform=iOS' -configuration Release archive \
    -archivePath "build/$scheme.xcarchive"
done

echo "== BUILD ALL DONE：产物在 build/*.xcarchive =="
