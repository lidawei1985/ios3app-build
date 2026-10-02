# -*- coding: utf-8 -*-
"""Swift 字符串「闭区间切片」越界粗检 —— 抓 endIndex 上的 index(after:) 闪退。

为什么需要（2026-10-03 真机血案，白忙一整轮）：
  `LivePool.normalize` 去括号时写了
      s.removeSubrange(a.lowerBound...b.upperBound)      // ← 闭区间
  闭区间命中的是 `RangeReplaceableCollection.removeSubrange<R: RangeExpression>` 这条泛型重载，
  内部 `ClosedRange.relative(to: s)` 会执行 `s.index(after: b.upperBound)`。
  当右括号正好是**串尾**时 `b.upperBound == s.endIndex` ⇒ `index(after: endIndex)` 越界
  ⇒ `_StringGuts.validateCharacterIndex` 断言失败 ⇒ SIGTRAP 闪退。
  台名里 `CGTN(1080p)` / `BaichengTV[Geo-blocked]` / `河源综合(540p)` 全是这种 —— 一进直播页就崩。
  端上崩溃栈铁证：LiveView.boot → withRefilled → LiveRefill.urls → LivePool.normalize → String.index(after:)

判据（故意保守，只报"几乎肯定越界"的写法）：
  在**同一个表达式内**出现「闭区间 `...`」+「字符串索引变量（*Bound / *Index / startIndex / endIndex）」
  且该表达式属于下列三者之一 → FAIL：
    ① `removeSubrange(...)` / `replaceSubrange(...)`   —— 泛型重载会算 index(after: upper)
    ② `String(...[...])` / `Substring` 切片构造
    ③ 对 `someString[...]` 的读写下标
  例外（明确安全，不报）：
    · `x[i...]` / `x[...j]` 这种**单边** PartialRangeFrom / PartialRangeThrough —— 不走 index(after:)
    · `array[0...n]` 之类非字符串变量（变量名不以 s/str/text/name/url 等字符串线索出现时放过）
  真拿不准时不报 —— 宁可漏报也不制造噪音（噪音会让门禁被无视）。

用法：python scripts/check_swift_string_index.py [扫描目录，默认 Packages]
"""
import pathlib
import re
import sys

# 疑似字符串的变量名线索（保守白名单式）
STR_HINT = re.compile(r"\b(s|str|string|text|name|title|url|raw|line|body|key|tag|val|value|extinf|host|path)\b")
CLOSED_RANGE = re.compile(r"[\w\.\)\]]\s*\.\.\.\s*[\w\.\(\[a-zA-Z]")
IDX_VAR = re.compile(r"\b(\w+(?:Bound|Index|index|Boundary))\b")
CALL_EDIT = re.compile(r"\b(?:removeSubrange|replaceSubrange)\s*\(")


def is_partial_only(expr):
    """单边区间（`x[i...]` / `x[...j]`）不走 index(after:)，安全。
    判据：`...` 左边是 `[` 或右边是 `]`（即紧邻定界符）。"""
    for m in re.finditer(r"\.\.\.", expr):
        left = expr[: m.start()].rstrip()
        right = expr[m.end():].lstrip()
        if left.endswith("[") or right.startswith("]"):
            return True
    return False


def main(root):
    hits = []
    for p in pathlib.Path(root).rglob("*.swift"):
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            code = line.split("//")[0]
            if "..." not in code:
                continue
            if not CLOSED_RANGE.search(code):
                continue
            if is_partial_only(code):
                continue
            # 必须能看到「字符串索引变量」或「字符串线索变量」才报
            if not (IDX_VAR.search(code) or STR_HINT.search(code)):
                continue
            # 三类危险上下文
            danger = False
            why = ""
            if CALL_EDIT.search(code):
                danger = True; why = "removeSubrange/replaceSubrange 泛型重载会算 index(after: upper)"
            elif re.search(r"\bString\s*\([^)]*\.\.\.", code) or re.search(r"\bSubstring\s*\(", code):
                danger = True; why = "String(...) 切片构造"
            elif re.search(r"\[[^\[\]]*\.\.\.[^\[\]]*\]", code):
                danger = True; why = "字符串下标用闭区间"
            if danger:
                hits.append((str(p), i, line.strip(), why))

    for f, ln, raw, why in hits:
        print("  %s:%d  %s\n        ← %s" % (f, ln, raw[:120], why))
    print("\n结果：%s（可疑 %d 处）" % ("FAIL" if hits else "PASS", len(hits)))
    print("修法：改成半开区间 `a..<b`（Range 重载，不做 index(after:)，串尾/空段都安全）。")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "Packages"))
