# -*- coding: utf-8 -*-
"""生成包内热度索引 heat_index_{normal,xinwu}.json（HeatIndex.swift 的数据源）。

来源：Packages/FilmCore/Sources/FilmCore/Resources/{xingmu,xinwu}_feed_snapshot.json
  里构建期已带出的豆瓣票数/评分（中台 feed 当前全量无此二字段，2026-10-04 实测）。

键 = 归一化标题 + "|" + 4位年份
  归一化规则必须与 HeatIndex.normalizeTitle **逐字一致**（删空白与常见标点 + lowercased）。
值 = [votes, rating]（rating 0 = 无）

何时重跑：快照更新后重跑本脚本再出包。
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, '..', 'Packages', 'FilmCore', 'Sources', 'FilmCore', 'Resources')

# 与 HeatIndex.normalizeTitle 逐字一致（改一处必须同步另一处）
DROP = set(" \t\r\n·:：-—–~!！?？,，.。;；、'\"“”‘’()（）[]【】<>《》")


def norm(t):
    return ''.join(ch for ch in t if ch not in DROP).lower()


JOBS = [
    ('xingmu_feed_snapshot.json', 'heat_index_normal.json'),
    ('xinwu_feed_snapshot.json', 'heat_index_xinwu.json'),
]

for src, dst in JOBS:
    p = os.path.join(RES, src)
    items = json.load(open(p, encoding='utf-8'))['items']
    table = {}
    for it in items:
        votes = it.get('votes') or 0
        rating = it.get('rating') or 0
        if votes <= 0 and rating <= 0:
            continue
        year = (it.get('year') or '')[:4]
        if not year.isdigit():
            continue
        table[norm(it['title']) + '|' + year] = [votes, rating]
    out = os.path.join(RES, dst)
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(table, f, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    print('%s: %d 条, %.0f KB' % (dst, len(table), os.path.getsize(out) / 1024))
