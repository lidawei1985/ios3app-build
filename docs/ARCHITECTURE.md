# 架构说明

## 分层

```
┌─────────────┬─────────────┬─────────────┐
│  星幕 iOS    │  心屋 iOS    │  夜航 iOS    │   三个独立 Target / Scheme / Bundle ID
│ (Profile .xingmu) │ (.xinwu) │ (.yehang) │   各自注入 ProductProfile + 品牌主题
└──────┬──────────────┬──────────────┬────┘
       │  MainTabView（首页/分类/搜索/直播*/我的）
       │  DetailView → PlayerScreen(AVPlayer)
┌──────┴──────────────┴──────────────┴────┐
│ FilmUI（SwiftUI 公共触控层）              │  触控交互 / Safe Area / 深色海报底
├─────────────────────────────────────────┤
│ FilmCore（平台无关公共核心）              │
│  FeedClient   基址链(CDN→raw→LAN) + 分片并发 + 重试 │
│  FeedAdapter  解码/去重/隔离安全网/台账      │
│  CatalogStore 快照秒开 + home 轻量包 + 全量同步 + 缩水闸门 │
│  CatalogCache/UserLibrary  快照与收藏/历史持久化       │
│  LiveLoader   M3U 解析（心屋不启用）        │
├─────────────────────────────────────────┤
│ FilmCollector 生产 feed（唯一数据事实）    │
│ v1/feed/{mode}/manifest|home|pN.json     │
└─────────────────────────────────────────┘
```

## 数据流（与 Android 端同构）

1. **启动**：快照命中 → 秒开渲染；未命中 → home.json（分类统计+posters≤40+pool≤500）先渲染首屏。
2. **后台全量**：manifest.json（count=数量事实）→ 并发拉 p0..pN → 解码 → 去重（dedup_id）→ 隔离安全网 → Catalog。
3. **缩水闸门**：新目录 < 现目录 80% 时拒绝覆盖（保留旧数据继续可用）；台账写盘。
4. **版本键**：`feedVersion@mode@adapterVersion`，任一变化强制重建缓存。

## 与 Android 版的功能映射（22 项）

首页/分类/海报墙/横向货架/搜索/详情/播放/收藏/历史/最近观看/图片/加载态/空态/错误态/重试/返回/导航/刷新/版本信息 → FilmUI 各页；
直播 → LiveView（M3U + AVPlayer，心屋无）；
家长锁/门禁/授权（PinManager/WatchGuard/SessionLimiter/Gate/License）→ **本期不迁移**（用户指令 2026-09-19）。

## iOS 端不再保留的 Android 概念（及理由）

- HlsProxy 进程内代理：AVPlayer 原生吃 HLS，分片容错由 AVFoundation 处理，无需本地代理。
- TV 遥控器焦点系统：iPhone 触摸交互（NavigationStack + TabView）。
- BootSelfCheck/TlsCompat：URLSession + ATS 配置覆盖。

## 播放

- AVPlayer + AVPlayerViewController：HLS/MP4 全支持；线路切换 = playCandidates 顺序轮换；
- 失败态：状态监听 → 重试/换线路浮层，不闪退；
- 后台：`UIBackgroundModes: audio` + 前后台自动暂停/恢复；
- 屏幕常亮：播放中开启、退出关闭（自动开合）；
- 续播：历史进度 seek。

## 性能

- 图片：NSCache(600) + 磁盘缓存 + URLCache(256MB) + 去重并发 + 失败重试；
- 列表：LazyVGrid/LazyHStack 懒加载 + 60/批分页追加；
- 网络：单飞闸门防重复全量同步；基址短超时快速失败；分片并发 6。
