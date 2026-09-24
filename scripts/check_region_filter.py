# -*- coding: utf-8 -*-
"""地区筛选口径一致性机检（2026-09-23 用户指令「分类里没有国家地区筛选找片太难找了」）。

为什么要有这个检查：
  地区筛选能不能用，取决于**两个仓、两套语言里的词表必须是同一套口径**——
    中台 `E:/FilmCollector/tools/backfill_area.py` 的 `AREA_RULES`（写进 feed 的 area 值）
    iOS  `Packages/.../NavPolicy.swift` 的 `regionOrder` / `regionWords`（分类页 chip 与派生）
  任一边改了标签名而另一边没跟 → 端上 chip 点了查不到任何内容（静默失效，最难查）。
  故把「两边标签集合相同 + 代表输入归一结果正确」做成一条命令的机检。

用法：
  python scripts/check_region_filter.py
退出码：0 = 一致；1 = 漂移（打印差异）。
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(ROOT, "Packages", "FilmCore", "Sources", "FilmCore", "Config", "NavPolicy.swift")
PY_BACKFILL = r"E:/FilmCollector/tools/backfill_area.py"

fails = []


def read(p):
    with io.open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def swift_region_order(src):
    m = re.search(r"regionOrder:\s*\[String\]\s*=\s*\[(.*?)\]", src, re.S)
    if not m:
        return None
    return re.findall(r'"([^"]+)"', m.group(1))


def swift_region_words(src):
    m = re.search(r"regionWords:\s*\[\(String, \[String\]\)\]\s*=\s*\[(.*?)\n    \]", src, re.S)
    if not m:
        return None
    out = {}
    for label, body in re.findall(r'\("([^"]+)",\s*\[(.*?)\]\)', m.group(1), re.S):
        out[label] = re.findall(r'"([^"]+)"', body)
    return out


def py_area_rules(src):
    m = re.search(r"AREA_RULES\s*=\s*\[(.*?)\n\]", src, re.S)
    if not m:
        return None
    out = {}
    for label, body in re.findall(r'\("([^"]+)",\s*\[(.*?)\]\)', m.group(1), re.S):
        out[label] = re.findall(r'"([^"]+)"', body)
    return out


def main():
    if not os.path.exists(SWIFT):
        print("!! 找不到 NavPolicy.swift:", SWIFT)
        return 1
    sw = read(SWIFT)
    s_order = swift_region_order(sw)
    s_words = swift_region_words(sw)
    if not s_order:
        fails.append("NavPolicy.regionOrder 解析失败")
    if not s_words:
        fails.append("NavPolicy.regionWords 解析失败")

    py_words = None
    if os.path.exists(PY_BACKFILL):
        py_words = py_area_rules(read(PY_BACKFILL))
        if not py_words:
            fails.append("backfill_area.py AREA_RULES 解析失败")
    else:
        print("… 跳过中台对比（%s 不在本机）" % PY_BACKFILL)

    # 1) chip 顺序表 = 词表标签集合（「其他」是兜底标签，不出现在词表 → 豁免）
    if s_order and s_words:
        missing = [x for x in s_order if x not in s_words and x != "其他"]
        extra = [x for x in s_words if x not in s_order]
        if missing:
            fails.append("regionOrder 有词表没有的标签：%s" % missing)
        if extra:
            fails.append("regionWords 有 regionOrder 没列的标签：%s" % extra)

    # 2) 与中台口径逐标签对比（词表可多词，但标签必须一一对应）
    if s_words and py_words:
        only_swift = sorted(set(s_words) - set(py_words))
        only_py = sorted(set(py_words) - set(s_words))
        if only_swift:
            fails.append("iOS 有、中台没有的地区标签：%s（端上会筛不到）" % only_swift)
        if only_py:
            fails.append("中台有、iOS 没有的地区标签：%s（feed 里有值但端上看不到）" % only_py)

    # 3) 代表输入归一结果（口径回归）
    cases = [
        ("中国大陆", "国产"), ("大陆", "国产"), ("中国香港", "中国香港"), ("香港", "中国香港"),
        ("中国台湾", "中国台湾"), ("台湾", "中国台湾"), ("日本", "日本"), ("韩国", "韩国"),
        ("美国", "美国"), ("英国", "欧洲"), ("法国", "欧洲"), ("泰国", "泰国"), ("印度", "印度"),
        ("美国 / 英国", "美国"), ("中国香港 / 中国大陆", "中国香港"), ("其它", "其他"),
        # 2026-09-23 机检抓到的误判回归项（词表顺序必须保证不被更宽松的标签吃掉）
        ("中国香港", "中国香港"), ("中国台湾", "中国台湾"),
        ("印度尼西亚", "其他"), ("印度", "印度"), ("加拿大", "其他"),
    ]
    if py_words:
        sys.path.insert(0, os.path.dirname(PY_BACKFILL))
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location("bfa", PY_BACKFILL)
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            for raw, want in cases:
                got = m.norm_area(raw)
                if got != want:
                    fails.append("norm_area(%r) = %r，期望 %r" % (raw, got, want))
        except Exception as e:
            fails.append("加载 backfill_area 失败：%r" % (e,))

    print("地区口径检查：iOS 标签 %d 个 / 中台标签 %d 个 / 用例 %d 条"
          % (len(s_order or []), len(py_words or {}), len(cases)))
    if fails:
        print("FAIL（%d 项）:" % len(fails))
        for f in fails:
            print("  -", f)
        return 1
    print("PASS：端与中台地区口径一致，代表用例全部正确")
    return 0


if __name__ == "__main__":
    sys.exit(main())
