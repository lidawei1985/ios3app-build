# -*- coding: utf-8 -*-
"""Swift 字典 key 类型粗检：抓「声明为 [String: T] 却用 Int 下标读」这类编译错。

为什么需要（2026-10-03 实际踩到，白等一轮 CI 构建）：
  把 `health` 从 `[Int: Int]` 改成 `[String: Int]`（换表后下标会指向别的台，必须按台名做 key），
  改了 3 个函数却漏了视图里 `health[st.index]` 两处 → 中转仓编译失败、构建全废。
  本机是 Windows，**没有 Swift 工具链、跑不了真编译**，只能靠这类静态粗检兜底。

判据（故意保守，只报"几乎肯定是错的"）：
  · 字典键声明为 String，却用 `xxx.index` / 裸 `index` / 纯数字 下标 → FAIL
  · 字典键声明为 Int，却用 `normalize(...)` / `xxx.name` 下标 → FAIL

用法：python scripts/check_swift_dict_keys.py [扫描目录，默认 Packages]
"""
import pathlib
import re
import sys

DICT_DECL = re.compile(r"\b(?:var|let)\s+(\w+)\s*:\s*\[(String|Int)\s*:")
IDX_USE = re.compile(r"\b(\w+)\s*\[([^\[\]]{1,60})\]")


def main(root):
    decls = {}
    usages = []
    for p in pathlib.Path(root).rglob("*.swift"):
        in_multiline = False          # 是否在 `"""` 多行字符串里（内嵌 JS 等，不是 Swift 代码）
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            # 多行字符串字面量 toggle：`"""` 出现奇数次即切换状态
            if line.count('"""') % 2 == 1:
                in_multiline = not in_multiline
                continue
            if in_multiline:
                continue              # 内嵌脚本正文，跳过（否则 `m[2]` 这类 JS 下标会误报）
            for m in DICT_DECL.finditer(line):
                decls.setdefault(m.group(1), set()).add(m.group(2))
            for m in IDX_USE.finditer(line):
                usages.append((str(p), i, m.group(1), m.group(2).strip(), line.strip()))

    bad = []
    for f, ln, name, expr, raw in usages:
        keys = decls.get(name)
        if not keys:
            continue
        if keys == {"String"} and re.search(r"\.index\b|^index$|^\d+$", expr):
            bad.append((f, ln, name, expr, raw))
        elif keys == {"Int"} and re.search(r"normalize\(|\.name\b", expr):
            bad.append((f, ln, name, expr, raw))

    for f, ln, name, expr, raw in bad:
        print("  %s:%d  %s[%s]   ←  %s" % (f, ln, name, expr, raw[:100]))
    print("\n结果：%s（可疑 %d 处；扫了 %d 个字典声明）" % ("FAIL" if bad else "PASS", len(bad), len(decls)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "Packages"))
