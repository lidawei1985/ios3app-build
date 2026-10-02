# 星幕 / 心屋 / 夜航 — iPhone 版三款独立 App

现有三款 Android TV APK（星幕·普通 / 心屋·儿童 / 夜航·成人）的 iOS 迁移工程。
一套公共移动核心（FilmCore + FilmUI）+ 三个独立产品 Target，共享代码、独立身份、独立内容池。

## 产品矩阵

| 产品 | 定位 | 内容池（FilmCollector 生产 feed） | 直播 | Bundle ID |
|---|---|---|---|---|
| 星幕 | 普通影视 | filmcollector-pages-xingmu（normal） | ✅ normal.m3u | tv.filmcollector.app.xingmu |
| 心屋 | 儿童影视 | filmcollector-pages-xinwu（child） | ❌（生产现状无直播） | tv.filmcollector.app.xinwu |
| 夜航 | 成人影视 | filmcollector-pages-yehang（adult） | ✅ adult.m3u | tv.filmcollector.app.yehang |

**数量基线（2026-09-18 feed 版本，见 `build/feed-baseline/baseline_report.json`）**：
星幕 69,603 · 心屋 3,662 · 夜航 2,019。任何版本低于基线 80% 即触发缩水闸门。

## 目录

```
ios-three-apps/
├─ project.yml                # XcodeGen：三 Target / 三 Scheme / 独立 Bundle ID
├─ Packages/FilmCore/         # 公共核心（数据/网络/适配/缓存/直播/台账）
│  └─ Sources/FilmUI/         # 公共触控界面（SwiftUI：首页/分类/搜索/详情/播放/我的/直播）
├─ Apps/                      # 三个产品壳（入口 + 品牌主题 + 图标资产）
├─ scripts/
│  ├─ verify_feed.py          # 生产 feed 契约与数量守恒验收（Windows 可跑）
│  ├─ check_project.py        # Windows 静态验收（结构/隔离/夹具）
│  ├─ gen_icons.py            # 三品牌图标生成
│  └─ build_all.sh            # macOS 一键构建 + 测试 + Archive
├─ docs/                      # 架构 / 数据契约 / 签名发布
└─ build/feed-baseline/       # 数量基线报告
```

## 构建（macOS）

```bash
brew install xcodegen
cd ios-three-apps
./scripts/build_all.sh       # 生成工程 → 三 Target 编译 → 单元测试 → Archive
```

## 本机（Windows）已完成的验收

- 生产 feed 三端契约 + 数量守恒验收：**PASS**（抽样 2,784 条，0 丢弃 0 重复，隔离安全网有效）
- 工程静态验收：`python scripts/check_project.py`
- 真实编译/模拟器运行需 macOS + Xcode（本机为 Windows，工程已做到 Archive-ready，见 docs/SIGNING_AND_RELEASE.md）

## 红线（工程内已固化）

1. 三产品独立 Target/Bundle ID/内容池，禁止合并或换壳
2. FilmCollector 是唯一分类事实来源；iOS 只展示不判级
3. 数据不缩水：SOURCE→FEED→ADAPTER→CATALOG 全链路台账（App 内「我的 → 数量台账」可视化）
4. 图片失败=占位图不删内容；播放失败=重试/换线路不删内容
5. 隔离安全网：normal/child 端硬拒 is_adult=true（仅兜底，不复判）

## 本期约定（用户指令 2026-09-19）

- 家长锁 / 门禁 / 授权模块（PinManager/WatchGuard/SessionLimiter/GateActivity/LicenseGate 等）**暂不迁移**
