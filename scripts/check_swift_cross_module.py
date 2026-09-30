# -*- coding: utf-8 -*-
"""跨模块符号静态预检（2026-09-30 · 根治「只有 CI 才暴露的编译错」）。

背景 / 为什么必须有它：
  本机是 Windows，**不能编译 Swift**；Swift 只有到了 CI（macOS runner）才会报编译错。
  v21 连续两轮 CI 挂，全是这一类"本机查不出、CI 一跑就红"的错：
    ① WindowBackButton.swift 缺 `import FilmCore` → cannot find 'ProductProfile' in scope
    ② displayMark 写了 `ProductProfile.buildStamp`，而 buildStamp 其实声明在 `FeedSecret`
       → type 'ProductProfile' has no member 'buildStamp'
  代价 = 每轮 ~1.5 分钟 CI + 一次推送 + 一次人工定位。判据在本机把这类错提前一网打尽。

判据（PASS 条件，全部满足）：
  1) FilmUI 内所有 `X.member` 引用，若 X 是 FilmCore 声明的类型，则 member 必须能在
     FilmCore 的**对应类型**里找到声明（含 static let/var/func 与实例成员）；
  2) FilmUI 里**引用 FilmCore 公开类型的文件**必须 `import FilmCore`（避免 "in scope" 错）。

--negctl：对指定的 git revision 跑同一判据（默认取 HEAD~1，即补丁前），必须 FAIL。
"""
import re
import subprocess
import sys
from pathlib import Path

BUILD = Path(r"F:\IOS3APP\_v13_build")
CORE = BUILD / "Packages/FilmCore/Sources/FilmCore"
UI = BUILD / "Packages/FilmCore/Sources/FilmUI"

TYPE_DECL = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?"
    r"(?:final\s+)?(?:enum|struct|class|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
EXT_DECL = re.compile(r"^\s*extension\s+([A-Za-z_][A-Za-z0-9_]*)")
# 成员声明：先剥掉前导属性与访问/修饰关键字（含 private(set) 这种带括号的），再取 let/var/func Name
_ATTR = re.compile(r"^(?:@[A-Za-z_][A-Za-z0-9_.]*(?:\([^)]*\))?\s*)+")
_MODS = re.compile(
    r"^(?:(?:public|internal|private|fileprivate|open|final|static|class|weak|unowned|"
    r"lazy|nonisolated|mutating|override|required|convenience|indirect|dynamic)"
    r"(?:\s*\(\s*set\s*\))?\s+)+"
)
_MEMBER = re.compile(r"(?:let|var|func)\s+([A-Za-z_][A-Za-z0-9_]*)")
_CASE = re.compile(r"^case\s+([A-Za-z_][A-Za-z0-9_]*)")


def _member_name(line: str) -> str | None:
    code = line.split("//")[0].strip()
    if not code:
        return None
    while True:
        n = _ATTR.sub("", code)
        n = _MODS.sub("", n)
        if n == code:
            break
        code = n
    m = _MEMBER.match(code)
    if m:
        return m.group(1)
    c = _CASE.match(code)
    if c:
        return c.group(1)
    return None


def read_or_git(path: Path, rev: str | None) -> str | None:
    if rev is None:
        if not path.exists():
            return None
        return path.read_text(encoding="utf-8", errors="replace")
    rel = path.relative_to(BUILD).as_posix()
    r = subprocess.run(["git", "-C", str(BUILD), "show", f"{rev}:{rel}"],
                       capture_output=True)
    if r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", errors="replace")


def swift_files(root: Path, rev: str | None) -> list:
    """返回 [(relpath, text)]。rev 为 None 用工作区；否则用 git revision。"""
    out = []
    if rev is None:
        for p in root.rglob("*.swift"):
            out.append((p.relative_to(BUILD).as_posix(), p.read_text(encoding="utf-8", errors="replace")))
    else:
        # 用 git ls-tree 列出该 revision 下的 .swift
        relroot = root.relative_to(BUILD).as_posix()
        r = subprocess.run(["git", "-C", str(BUILD), "ls-tree", "-r", "--name-only", rev, relroot],
                           capture_output=True)
        for rel in r.stdout.decode("utf-8", errors="replace").splitlines():
            if rel.endswith(".swift"):
                t = read_or_git(BUILD / rel, rev)
                if t is not None:
                    out.append((rel, t))
    return out


def collect_type_members(files: list) -> dict:
    """返回 {TypeName: set(memberNames)}，按大括号层级把成员归属到最内层类型。"""
    members: dict = {}
    for _rel, text in files:
        stack = []          # [(typename, depth)]
        depth = 0
        for line in text.splitlines():
            code = line.split("//")[0]
            m = TYPE_DECL.match(line)
            if m:
                members.setdefault(m.group(1), set())
                stack.append((m.group(1), depth))
            else:
                e = EXT_DECL.match(line)
                if e:
                    members.setdefault(e.group(1), set())
                    stack.append((e.group(1), depth))
            mn = _member_name(line)
            if mn and stack:
                members[stack[-1][0]].add(mn)
            depth += code.count("{") - code.count("}")
            while stack and depth <= stack[-1][1]:
                stack.pop()
    return members


def collect_type_names(files: list) -> set:
    names = set()
    for _rel, text in files:
        for line in text.splitlines():
            m = TYPE_DECL.match(line)
            if m:
                names.add(m.group(1))
    return names


REF = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\.([a-z_][A-Za-z0-9_]*)")


def run(rev: str | None) -> int:
    core_files = swift_files(CORE, rev)
    ui_files = swift_files(UI, rev)
    members = collect_type_members(core_files)
    core_types = set(members) | collect_type_names(core_files)

    problems = []
    checked = 0
    for rel, text in ui_files:
        # 判据 2：引用 FilmCore 类型的文件必须 import FilmCore
        refs = [m for m in REF.finditer(text) if m.group(1) in core_types]
        if refs and "import FilmCore" not in text:
            problems.append(f"{rel}: 引用了 FilmCore 类型但缺 `import FilmCore`"
                            f"（首个引用 {refs[0].group(0)}）")
        # 判据 1：成员存在性
        for m in refs:
            t, mem = m.group(1), m.group(2)
            if mem in ("init", "self", "Type", "some"):
                continue
            checked += 1
            # 严格：成员必须声明在**该类型**（含其 extension）里。
            # 不做跨类型放宽——v21 的真错正是 `ProductProfile.buildStamp`（buildStamp 实际在 FeedSecret）。
            if mem not in members.get(t, set()):
                problems.append(f"{rel}: 引用 {t}.{mem} 但 {t} 内无该成员声明"
                                f"（该名字是否声明在别的类型里？）")

    print(f"FilmUI 对 FilmCore 的符号引用核对 {checked} 处；FilmCore 类型 {len(core_types)} 个")
    for p in problems:
        print("  ✗", p)
    ok = not problems
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    rev = None
    if "--negctl" in sys.argv:
        i = sys.argv.index("--negctl")
        rev = sys.argv[i + 1] if len(sys.argv) > i + 1 else "HEAD~1"
    sys.exit(run(rev))
