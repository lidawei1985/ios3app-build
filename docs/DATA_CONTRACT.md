# 数据契约（FilmCollector 生产 feed v1 · iOS 适配版）

## 基址链（FeedBases）

1. （可选）局域网加速 `http://192.168.8.109:8791`（调试）
2. jsDelivr CDN `https://fastly.jsdelivr.net/gh/lidawei1985/{repo}@main`（墙内可达）
3. raw `https://raw.githubusercontent.com/lidawei1985/{repo}/main`（墙外兜底）

| 产品 | repo | mode |
|---|---|---|
| 星幕 | filmcollector-pages-xingmu | normal |
| 心屋 | filmcollector-pages-xinwu | child |
| 夜航 | filmcollector-pages-yehang | adult |

## 端点

- `v1/feed/{mode}/manifest.json`：`{ok, mode, version, count, part_size, parts[]}` — count 为数量事实源
- `v1/feed/{mode}/home.json`：`{ok, mode, version, total, categories[{id,name,count}], posters[≤40], pool[≤500]}` — 首屏轻量包
- `v1/feed/{mode}/pN.json`：`{ok, mode, offset, total, version, items[]}` — 每片 500 条
- `v1/live/normal.m3u` / `v1/live/adult.m3u`：直播列表（心屋不消费）

## item 契约（FeedItem）

```
dedup_id*, title*, year, directors[], actors[], summary,
content_type(movie|tv|short), is_adult, playable,
categories{normal[], canonical[], tags[]},
aggregate_category_id, aggregate_category_name,
poster{url, thumb}, backdrop{url, thumb}, quality_score,
origin{source_id, source_name, category},
play{lines[{name,url,quality}], default_line, default_url}
```

## 血缘与保留铁律

- 原始分类（origin.category / categories.normal）永远保留，iOS 不判级不复分类
- 空海报 → 占位图（记账 emptyPosterCount），不删数据
- 无播放地址 → 保留（记账 noPlayURLCount），详情页禁用播放按钮
- 未知分类 → 保留（记账 unknownCategoryCount），聚合为「未知分类」
- 隔离安全网：normal/child 端丢弃 `is_adult==true` 并记台账；adult 端不复判不扩大

## 数量守恒台账（DataLedger）

`sourceCount → feedFetchedCount → catalogCount` 全链路 + 丢弃原因分布，
App 内「我的 → 数量台账明细」可视化；缩水预警阈值 <80%。

## 基线（2026-09-18T01:19:06+08:00）

星幕 69,603（140 片）/ 心屋 3,662（8 片）/ 夜航 2,019（5 片）。

## 解码策略（2026-09-19 审计修订）

feed 为蛇形键（`dedup_id`/`is_adult`/`default_url`…），Swift 模型为驼峰。全局统一使用
`FilmJSON.decoder()`（convertFromSnakeCase + iso8601）解码、`FilmJSON.encoder()` 持久化。
**禁止**在业务代码里直接 new JSONDecoder/JSONEncoder——裸解码器解不了蛇形键，且与本地缓存往返不对称。

属性命名铁律：蛇形转驼峰只大写下划线后首字母 → `dedup_id → dedupId`（不是 dedupID）、
`aggregate_category_id → aggregateCategoryId`。新增字段必须遵守，否则静默解码失败。
feed 中的额外字段（pinyin_abbr/area/rating/remarks 等）Codable 自动忽略，可后续按需增补为可选属性。
