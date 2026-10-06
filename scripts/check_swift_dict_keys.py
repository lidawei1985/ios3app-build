# -*- coding: utf-8 -*-
"""Swift 容器「元素类型」粗检：抓「声明是 [Int]/Int?，却拿 String 用」这类编译错。

为什么需要（2026-10-03，两次都是白等一整轮 CI）：
  ① 把 `health` 从 `[Int: Int]` 改成 `[String: Int]`（换表后下标会指向别的台，必须按台名做 key），
     改了函数却漏了视图里的 `health[st.index]` → 中转仓编译失败、构建全废。
  ② 下一轮补上那两处，却又漏了**同批兄弟变量**：`healthPending: [Int]`、`healthTesting: Int?`，
     于是 `healthPending.contains(key)`（`[Int]` 上 contains(String)）、`healthTesting != key`
     依旧编译不过 —— 因为本脚本当时**只查下标、不查 .contains/.append/==/!=**，也不认数组/可选声明 → 漏报。
  补强后本脚本覆盖：`X[...]` / `X.contains(...)` / `X.append(...)` / `X == ...` / `X != ...`。

本机是 Windows，**没有 Swift 工具链、跑不了真编译**，只能靠这类静态粗检兜底。
判据（故意保守，只报"几乎肯定是错的"）：
  · 容器声明为 Int 侧（[Int: _] / [Int] / Int?），却用**明确是 String 侧**的表达式 → FAIL
  · 容器声明为 String 侧，却用**明确是 Int 侧**的表达式 → FAIL
  · 「明确」= 只认无歧义的形状（见 kind()）：纯数字 / `.index` / `i` / `idx` / `.count` → Int；
    `.name` / `normalize(` / `hkey` / `key` / `.absoluteString` / 字符串字面量 → String。
    其余（普通标识符、函数调用）**一律不判** —— 宁可漏报也不制造噪音（噪音会让门禁被无视）。
  · 声明与使用**按文件配对**（避免跨文件同名误判）；`\"\"\" ... \"\"\"` 内嵌脚本（JS 等）整段跳过。

用法：python scripts/check_swift_dict_keys.py [扫描目录，默认 Packages]
"""
import pathlib
import re
import sys

DICT_DECL = re.compile(r"\b(?:var|let)\s+(\w+)\s*:\s*\[(String|Int)\s*:\s*(String|Int)\s*\]")
DICT_DECL_EQ = re.compile(r"\b(?:var|let)\s+(\w+)\s*=\s*\[(String|Int)\s*:\s*(String|Int)\s*\]\s*\(")
ARR_DECL = re.compile(r"\b(?:var|let)\s+(\w+)\s*:\s*\[(String|Int)\]\s*(?:=[^(]|$)")
ARR_DECL_EQ = re.compile(r"\b(?:var|let)\s+(\w+)\s*=\s*\[(String|Int)\]\s*\(")
OPT_DECL = re.compile(r"\b(?:var|let)\s+(\w+)\s*:\s*(String|Int)\?")

SUB_USE = re.compile(r"\b(\w+)\s*\[([^\[\]]{1,80})\]")
CALL_USE = re.compile(r"\b(\w+)\.(contains|append|insert)\(([^()]{1,80})\)")
CMP_R = re.compile(r"\b(\w+)\s*(==|!=)\s*([A-Za-z0-9_.\"'\\()]{1,60})")
CMP_L = re.compile(r"([A-Za-z0-9_.\"']{1,60})\s*(==|!=)\s*\b(\w+)\b")


def kind(expr):
    """把表达式粗分为 'Int' / 'String' / None（不确定）。只认无歧义的形状。"""
    e = expr.strip()
    if not e:
        return None
    if e.startswith('"'):                      # 字符串字面量
        return "String"
    if re.fullmatch(r"\d+", e):                # 纯数字
        return "Int"
    if re.search(r"(^|\.)(index|idx|count|i)$", e) or e in ("index", "idx", "i", "count"):
        return "Int"
    if re.search(r"\.name$|\.absoluteString$|^hkey$|^key$|^stName$", e) or "normalize(" in e:
        return "String"
    return None


def collect(text):
    """按文件收集声明与使用。返回 (decls, uses)；decls: name -> ('dict',K,V)/(arr,T)/(opt,T)"""
    decls, uses = {}, []
    in_multiline = False
    for i, line in enumerate(text.splitlines(), 1):
        if line.count('"""') % 2 == 1:         # 多行字符串字面量 toggle
            in_multiline = not in_multiline
            continue
        if in_multiline:
            continue                            # 内嵌脚本正文（JS 的 m[2] 等）不当 Swift 扫
        code = line.split("//")[0]
        for rx, t in ((DICT_DECL, "dict"), (DICT_DECL_EQ, "dict")):
            for m in rx.finditer(code):
                decls[m.group(1)] = (t, m.group(2), m.group(3))
        for rx in (ARR_DECL, ARR_DECL_EQ):
            for m in rx.finditer(code):
                decls.setdefault(m.group(1), ("arr", m.group(2), None))
        for m in OPT_DECL.finditer(code):
            decls.setdefault(m.group(1), ("opt", m.group(1) and m.group(2), None))
        for m in SUB_USE.finditer(code):
            uses.append((i, m.group(1), m.group(2), "sub", line.strip()))
        for m in CALL_USE.finditer(code):
            uses.append((i, m.group(1), m.group(3), m.group(2), line.strip()))
        for m in CMP_R.finditer(code):
            uses.append((i, m.group(1), m.group(3), "cmp", line.strip()))
        for m in CMP_L.finditer(code):
            uses.append((i, m.group(3), m.group(1), "cmp", line.strip()))
    return decls, uses


def judge(decls, uses):
    bad = []
    for ln, name, expr, ctx, raw in uses:
        d = decls.get(name)
        if not d:
            continue
        t = d[0]
        k = kind(expr)
        if k is None:
            continue
        if t == "dict" and ctx == "sub":
            want = d[1]
            if k != want:
                bad.append((ln, name, expr, ctx, raw, "字典键是 %s，这里给的是 %s" % (want, k)))
        elif t == "arr":
            # 注意：**不查 `arr[i]` 数组下标** —— 下标恒是 Int，而「同文件里重名的另一个
            # `[String]` 变量」会让它变成误报（`out` 就踩过）。数组只查元素进出：
            want = d[1]
            if ctx in ("contains", "append", "insert") and k != want:
                bad.append((ln, name, expr, ctx, raw, "数组元素是 %s，这里给的是 %s" % (want, k)))
        elif t == "opt":
            want = d[1]
            if ctx == "cmp" and k != want:
                bad.append((ln, name, expr, ctx, raw, "可选值是 %s，这里比的 %s 是 %s" % (want, name, k)))
    return bad


def main(root):
    total_files = 0
    allbad = []
    ndecl = 0
    for p in sorted(pathlib.Path(root).rglob("*.swift")):
        total_files += 1
        decls, uses = collect(p.read_text(encoding="utf-8", errors="replace"))
        ndecl += len(decls)
        for ln, name, expr, ctx, raw, why in judge(decls, uses):
            allbad.append((str(p), ln, name, expr, ctx, raw, why))

    for f, ln, name, expr, ctx, raw, why in allbad:
        print("  %s:%d  %s(%s)  ←  %s" % (f, ln, name, expr, why))
        print("        %s" % raw[:110])
    print("\n结果：%s（可疑 %d 处；扫了 %d 个 Swift 文件 / %d 个声明）"
          % ("FAIL" if allbad else "PASS", len(allbad), total_files, ndecl))
    return 1 if allbad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "Packages"))
