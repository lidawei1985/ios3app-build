# -*- coding: utf-8 -*-
"""归并口径终验：拿普查到的全部真实源分类名（481 条）跑 NavPolicy 新口径。"""
import json, io, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

GROUPS = [
    ("成人动漫", ["里番", "裏番", "肉番", "H动漫", "H动画", "エロアニメ", "成人动漫", "成人动画",
                  "动漫无码", "动漫有码", "卡通动漫", "动漫", "卡通", "动画", "漫剧", "两性课堂", "两性"]),
    ("三级", ["三级", "三級", "三级片", "情色", "色情", "限制级", "Category III", "CAT III",
              "港台三级", "香港三级", "台湾三级", "日本三级", "韩国三级", "西方三级", "欧美三级"]),
    ("伦理", ["伦理", "理论"]),
    ("写真热舞", ["写真热舞", "写真", "热舞", "唯美", "模特", "主播", "素人", "网红", "自拍", "偷拍", "盗摄", "裸聊", "擦边"]),
    ("自拍探花", ["探花", "门事件", "黑料", "网曝", "抖阴"]),
    ("精选推荐", ["中文字幕", "精品推荐", "推荐", "热门", "最新", "视频一区", "视频二区"]),
    ("成人真人", ["无码", "無碼", "有码", "有碼", "AV解说", "AV", "精品", "成人"]),
]
KID = ["儿童", "儿歌", "亲子", "早教", "幼教", "少儿", "宝宝", "幼儿园", "益智", "科普"]
EXCLUDED = ["综艺", "真人秀", "体育", "赛事", "篮球", "足球", "斯诺克", "台球", "运动",
            "电视剧", "连续剧", "国产剧", "港剧", "台剧", "日剧", "韩剧", "欧美剧", "海外剧",
            "泰剧", "台湾剧", "香港剧", "韩国剧", "日本剧", "港澳剧",
            "电影", "动作片", "喜剧片", "爱情片", "科幻片", "恐怖片", "剧情片", "战争片",
            "惊悚片", "悬疑片", "犯罪片", "灾难片", "西部片", "古装片", "历史片", "4K",
            "短剧", "爽剧", "爽文", "女频", "脑洞", "古装仙侠", "仙侠", "穿越",
            "动画", "动漫", "卡通", "漫剧", "有声动漫",
            "纪录片", "记录片", "预告片", "预告", "解说", "演唱", "MV", "小说", "图文"]
KEEP = ["里番", "裏番", "肉番", "成人", "H动漫", "H动画", "エロ", "无码", "無碼", "有码", "有碼",
        "情色", "色情", "三级", "三級", "限制级", "18禁", "R18", "AV", "激情", "擦边"]


def has(n, ws):
    low = n.lower()
    return any(w.lower() in low for w in ws)


def nav_title(n):
    if has(n, KID):
        return None
    if has(n, EXCLUDED) and not has(n, KEEP):
        return None
    for t, ws in GROUPS:
        if has(n, ws):
            return t
    return "其他"


d = json.load(io.open("F:/IOS3APP/ios_ctrl/adult_cats_census.json", encoding="utf-8"))
names = set()
for src, v in d["results"].items():
    for c in v.get("names", []):
        names.add(c)
print("参与验证的真实源分类名：%d 个\n" % len(names))

grouped, dropped = {}, []
for n in sorted(names):
    t = nav_title(n)
    if t is None:
        dropped.append(n)
    else:
        grouped.setdefault(t, []).append(n)

for t, _ in GROUPS:
    lst = grouped.get(t, [])
    print("【%s】%d 个源分类" % (t, len(lst)))
    print("   " + " / ".join(lst) if lst else "   （无）")
print("\n【其他（题材，二级筛选细分）】%d 个" % len(grouped.get("其他", [])))
print("   " + " / ".join(grouped.get("其他", [])[:60]) + (" …" if len(grouped.get("其他", [])) > 60 else ""))
print("\n【已挡掉（非成人正常影视 / 儿童向）】%d 个" % len(dropped))
print("   " + " / ".join(dropped))

print("\n" + "=" * 60)
print("关键校验（用户三条口径）")
print("=" * 60)
checks = [("日本伦理", "伦理"), ("韩国伦理", "伦理"), ("西方伦理", "伦理"), ("伦理", "伦理"),
          ("情色", "三级"), ("三级", "三级"), ("港台三级", "三级"), ("三级伦理", "三级"),
          ("两性课堂", "成人动漫"), ("里番", "成人动漫"), ("激情动漫", "成人动漫"), ("擦边短剧", "写真热舞"),
          ("动画片", None), ("动漫", None), ("卡通动漫", None), ("欧美动漫", None),
          ("综艺", None), ("电视剧", None), ("电影", None), ("体育赛事", None),
          ("中文字幕", "精选推荐"), ("精品推荐", "精选推荐"),
          ("日本无码", "成人真人"), ("自拍偷拍", "写真热舞"), ("强奸乱伦", "其他")]
ok = True
for n, want in checks:
    got = nav_title(n)
    good = got == want
    ok = ok and good
    print("  %-10s → %-10s 期望 %-10s %s" % (n, got, want, "✅" if good else "❌"))
print("\nRESULT: %s" % ("PASS" if ok else "FAIL"))
