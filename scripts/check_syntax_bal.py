# -*- coding: utf-8 -*-
"""Swift 源文件粗检：去注释/字符串后做括号配平 + 关键符号存在性（Windows 上无法编译 Swift，用这个兜底）。"""
import re
import sys

FILES = [
    "Packages/FilmCore/Sources/FilmUI/Screens/CategoryBrowseView.swift",
    "Packages/FilmCore/Sources/FilmUI/Screens/HomeView.swift",
    "Packages/FilmCore/Sources/FilmUI/Screens/TVSeriesView.swift",
]
SYMBOLS = {
    "CategoryBrowseView.swift": ["poolBar", "chipLabel", "static func sortedList", "static func sortKey",
                                 "SortKey", "keyCache", "scrollTo", "Self.topAnchor", "sortScrollTick"],
    "HomeView.swift": ["榜单", "deduped", "channelChip"],
}

bad = 0
for f in FILES:
    s = open(f, encoding="utf-8").read()
    t = re.sub(r"//[^\n]*", "", s)
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    t = re.sub(r'"(?:[^"\\]|\\.)*"', '""', t)
    bal = {c: t.count(a) - t.count(b) for c, (a, b) in
           {"()": ("(", ")"), "{}": ("{", "}"), "[]": ("[", "]")}.items()}
    name = f.split("/")[-1]
    ok = all(v == 0 for v in bal.values())
    miss = [k for k in SYMBOLS.get(name, []) if k not in s]
    flag = "PASS" if ok and not miss else "FAIL"
    if flag == "FAIL":
        bad += 1
    print("%-4s %-26s 行=%-5d 括号差=%s 缺失符号=%s" % (flag, name, len(s.splitlines()), bal, miss or "-"))
# ── 高风险类型误用（2026-09-23 真实事故：只有 CI 编译才暴露）────────────────
# `Capsule().fill(...)` 是 **View**，不是 ShapeStyle。塞进 `AnyShapeStyle(...)` 或
# `.background(X, in: Shape)` 的 X 位置，Swift 会报：
#   error: initializer 'init(_:)' requires that 'some View' conform to 'ShapeStyle'
# Windows 上编不了 Swift → 这类错只能靠静态规则拦（别等 CI 跑到 1 分钟才发现）。
def _call_args(s, open_idx):
    """从 '(' 下标取到配对 ')' 之间的实参文本。"""
    depth = 0
    for i in range(open_idx, len(s)):
        if s[i] == "(":
            depth += 1
        elif s[i] == ")":
            depth -= 1
            if depth == 0:
                return s[open_idx + 1:i]
    return ""


import glob as _glob

RISK = []
_swift = sorted(_glob.glob("Packages/FilmCore/Sources/FilmUI/**/*.swift", recursive=True)) + \
         sorted(_glob.glob("Apps/**/*.swift", recursive=True))
for f in _swift:
    s = open(f, encoding="utf-8").read()
    # 先用「去注释」文本扫描：否则注释里的反例说明（如本仓 CategoryBrowseView 里
    # 记录事故成因的那两行注释）会被误报成违规。
    s = re.sub(r"//[^\n]*", "", s)
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    for m in re.finditer(r"AnyShapeStyle\s*\(", s):
        arg = _call_args(s, m.end() - 1)
        if re.match(r"\s*[A-Z]\w*\s*\(\s*\)\s*\.", arg):
            RISK.append("%s:%d AnyShapeStyle(View) —— 形状.fill() 是 View 不是 ShapeStyle → 改 .background { } 闭包"
                        % (f, s[:m.start()].count("\n") + 1))
    for m in re.finditer(r"\.background\s*\(", s):
        arg = _call_args(s, m.end() - 1)
        if ", in:" in arg:
            first = arg.split(", in:", 1)[0]
            if re.match(r"\s*[A-Z]\w*\s*\(\s*\)\s*\.", first):
                RISK.append("%s:%d .background(View, in:) —— in: 形式首参必须 ShapeStyle → 改闭包形式"
                            % (f, s[:m.start()].count("\n") + 1))

if RISK:
    bad += len(RISK)
    print("\n[类型误用] FAIL（View 当 ShapeStyle）：")
    for r in RISK:
        print("   -", r)
else:
    print("\n[类型误用] PASS（扫了 %d 个 Swift 文件，无 View 当 ShapeStyle）" % len(_swift))

print("\n结果：%s" % ("全部 PASS" if not bad else "%d 个文件 FAIL" % bad))
sys.exit(1 if bad else 0)
