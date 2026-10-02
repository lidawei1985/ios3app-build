# -*- coding: utf-8 -*-
"""三款 iOS App 可交互预览原型生成器 v2：内容优先大厂式布局。
变更（2026-09-19 用户指令）：界面内不放 LOGO 名字；去掉片库数量卡；海报/导航/按钮按手机屏与主流流媒体规范重排。
输出单文件 HTML：build/prototype/index.html"""
import json, os, html

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # ios-three-apps/
FEED = os.path.join(BASE, "build", "feed-baseline")
OUT = os.path.join(BASE, "build", "prototype")
os.makedirs(OUT, exist_ok=True)

PRODUCTS = [
    {"key": "xingmu", "name": "星幕", "mode": "normal", "accent": "#E8443A", "glyph": "star", "tagline": "海量影视 · 每日更新", "live": True},
    {"key": "xinwu",  "name": "心屋", "mode": "child",  "accent": "#F5A623", "glyph": "house", "tagline": "孩子的专属小影院", "live": False},
    {"key": "yehang", "name": "夜航", "mode": "adult",  "accent": "#7C4DFF", "glyph": "moon", "tagline": "深夜航线 · 仅限成人", "live": True},
]

def trim_items(items):
    out = []
    for it in items or []:
        poster = (it.get("poster") or {})
        img = poster.get("thumb") or poster.get("url") or ""
        play = it.get("play") or {}
        urls = []
        d = play.get("default_url") or ""
        if d: urls.append(d)
        for ln in play.get("lines") or []:
            u = ln.get("url") or ""
            if u and u not in urls: urls.append(u)
        out.append({
            "id": it.get("dedup_id") or "",
            "t": it.get("title") or "",
            "y": it.get("year") or "",
            "cat": it.get("aggregate_category_name") or "",
            "q": it.get("quality_score") or 0,
            "img": img,
            "sum": (it.get("summary") or "")[:110],
            "play": urls[:3],
            "act": (it.get("actors") or [])[:4],
            "dir": (it.get("directors") or [])[:3],
            "type": it.get("content_type") or "",
        })
    return out

DATA = {}
for p in PRODUCTS:
    h = json.load(open(os.path.join(FEED, f"home_{p['mode']}.json"), encoding="utf-8"))
    pool = trim_items((h.get("pool") or []) + (h.get("posters") or []))
    seen, uniq = set(), []
    for it in pool:
        if it["id"] and it["id"] not in seen and it["img"]:
            seen.add(it["id"]); uniq.append(it)
    DATA[p["key"]] = {
        "name": p["name"], "mode": p["mode"], "accent": p["accent"], "glyph": p["glyph"],
        "tagline": p["tagline"], "live": p["live"], "total": h.get("total"), "version": h.get("version"),
        "categories": (h.get("categories") or [])[:24],
        "items": uniq,
    }

TPL = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>三款 iOS App · 交互原型</title>
<script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.13/dist/hls.min.js"></script>
<style>
:root{ --bg:#0B0E14; --card:#151A23; --card2:#1C2230; --tx:#F2F4F8; --tx2:#9AA3B2; --accent:#E8443A; }
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{background:#05070b;color:#dfe4ee;font-family:-apple-system,"PingFang SC","Segoe UI",Roboto,"Microsoft YaHei",sans-serif;
     display:flex;flex-direction:column;align-items:center;padding:26px 16px 60px;min-height:100vh}
h1{font-size:20px;font-weight:700;margin-bottom:4px}
.sub{font-size:12px;color:#8a93a3;margin-bottom:16px;text-align:center;line-height:1.7}
.switcher{display:flex;gap:14px;margin-bottom:22px}
.appchip{width:52px;height:52px;border-radius:17px;display:flex;align-items:center;justify-content:center;cursor:pointer;
  background:var(--card);border:1.5px solid #232a38;transition:.18s}
.appchip svg{width:26px;height:26px;stroke:none;fill:#fff;opacity:.85;transition:.18s}
.appchip:hover{transform:translateY(-2px)}
.appchip.active{border-color:var(--ac);box-shadow:0 0 0 3px color-mix(in srgb,var(--ac) 25%,transparent)}
.appchip.active svg{opacity:1}
.hint{font-size:11px;color:#6b7484;margin-top:10px}

/* ===== iPhone ===== */
.phone{width:390px;height:844px;background:#000;border-radius:54px;padding:10px;position:relative;
  box-shadow:0 0 0 2px #2a2f3a,0 30px 80px rgba(0,0,0,.7);flex-shrink:0}
.screen{width:100%;height:100%;border-radius:44px;overflow:hidden;position:relative;background:var(--bg);display:flex;flex-direction:column}
.island{position:absolute;top:10px;left:50%;transform:translateX(-50%);width:118px;height:34px;background:#000;border-radius:20px;z-index:60}
.statusbar{height:52px;flex-shrink:0;display:flex;align-items:flex-end;justify-content:space-between;padding:0 30px 5px;
  font-size:14px;font-weight:600;color:var(--tx);position:relative;z-index:50}
.statusbar .right{display:flex;gap:6px;align-items:center;font-size:12px}
.apparea{flex:1;position:relative;overflow:hidden;display:flex;flex-direction:column}
#pages{flex:1;min-height:0;overflow-y:auto;scrollbar-width:none}
#pages::-webkit-scrollbar{display:none}
.tabbar{flex-shrink:0;display:flex;background:rgba(11,14,20,.94);backdrop-filter:blur(16px);border-top:1px solid #1d2330;
  padding:7px 4px 20px;z-index:40}
.tab{flex:1;display:flex;flex-direction:column;align-items:center;gap:3px;font-size:10px;color:var(--tx2);cursor:pointer;padding:4px 0;transition:.15s}
.tab svg{width:23px;height:23px;stroke:currentColor;fill:none;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.tab.active{color:var(--accent);font-weight:700}

/* ===== 顶部条（首页：logo 图标位，无文字） ===== */
.topbar{display:flex;align-items:center;justify-content:space-between;padding:4px 16px 8px;flex-shrink:0}
.topbar .glyph{width:30px;height:30px;border-radius:9px;background:var(--accent);display:flex;align-items:center;justify-content:center}
.topbar .glyph svg{width:18px;height:18px;fill:#fff}
.topbar .acts{display:flex;gap:16px}
.topbar .acts svg{width:21px;height:21px;stroke:var(--tx);fill:none;stroke-width:1.9;stroke-linecap:round;cursor:pointer}
.ptitle{font-size:28px;font-weight:800;color:var(--tx);padding:2px 16px 10px}

/* ===== 海报卡（2:3 手机适配） ===== */
.sec-t{font-size:16.5px;font-weight:700;color:var(--tx);margin:18px 16px 10px;display:flex;align-items:center;justify-content:space-between}
.sec-t .morelnk{font-size:12px;color:var(--tx2);font-weight:500;cursor:pointer}
.rail{display:flex;gap:10px;overflow-x:auto;padding:2px 16px 8px;scrollbar-width:none}
.rail::-webkit-scrollbar{display:none}
.pcard{width:114px;flex-shrink:0;cursor:pointer}
.pcard .img{width:114px;aspect-ratio:2/3;border-radius:12px;overflow:hidden;background:var(--card2);position:relative}
.pcard img{width:100%;height:100%;object-fit:cover;display:block;transition:.2s}
.pcard:hover img{transform:scale(1.04)}
.pcard .yr{position:absolute;right:6px;bottom:6px;font-size:9px;background:rgba(0,0,0,.55);color:#fff;padding:1px 5px;border-radius:4px}
.pcard .t{font-size:12.5px;color:var(--tx);margin-top:7px;line-height:1.35;height:34px;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
/* 海报骨架屏 shimmer */
.shm{background:linear-gradient(110deg,#141922 30%,#1f2632 45%,#141922 60%);background-size:200% 100%;animation:shm 1.15s linear infinite}
@keyframes shm{to{background-position:-200% 0}}
/* 继续观看：进度条 */
.pcard .prog{position:absolute;left:0;right:0;bottom:0;height:3.5px;background:rgba(255,255,255,.22)}
.pcard .prog i{display:block;height:100%;background:var(--accent);border-radius:0 2px 2px 0}
.pcard .rsum{position:absolute;left:6px;top:6px;font-size:9px;background:var(--accent);color:#fff;padding:1.5px 6px;border-radius:5px;font-weight:700}
/* 热搜编号榜 */
.hotrow{display:flex;align-items:center;gap:11px;padding:9px 16px;cursor:pointer}
.hotrow:active{background:#161c26}
.hotrow .no{width:17px;text-align:center;font-size:12.5px;font-weight:800;color:var(--tx2);font-style:italic;flex-shrink:0}
.hotrow .no.top{color:#f25d43}
.hotrow .ht{font-size:13px;color:var(--tx);font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.hotrow .hm{margin-left:auto;font-size:10.5px;color:var(--tx2);flex-shrink:0}
.sect-hd{display:flex;align-items:center;justify-content:space-between;padding:0 16px}
.sect-hd .cl{font-size:11px;color:var(--tx2);background:none;border:none;cursor:pointer;padding:4px 8px}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px 12px;padding:4px 16px}
.grid .pcard{width:auto}
.grid .pcard .img{width:100%}

/* ===== Hero（全幅沉浸式） ===== */
.hero{position:relative;aspect-ratio:1/1.1;overflow:hidden;cursor:pointer;margin-top:-42px}
.hero img{width:100%;height:100%;object-fit:cover;display:block}
.hero .grad{position:absolute;inset:0;background:linear-gradient(180deg,rgba(11,14,20,.15) 40%,rgba(11,14,20,.92) 88%,var(--bg))}
.hero .info{position:absolute;left:0;right:0;bottom:0;padding:16px 18px 14px}
.hero .t{font-size:22px;font-weight:800;color:#fff;text-shadow:0 2px 10px rgba(0,0,0,.5)}
.hero .m{font-size:12px;color:rgba(255,255,255,.78);margin-top:5px}
.hero .btns{display:flex;gap:10px;margin-top:12px}
.hbtn{flex:1;display:flex;align-items:center;justify-content:center;gap:7px;padding:12px 0;border-radius:11px;
  font-size:14.5px;font-weight:700;border:none;cursor:pointer;letter-spacing:.5px}
.hbtn:active{transform:scale(.97)}
.hbtn.primary{background:#fff;color:#0b0e14}
.hbtn.ghost{background:rgba(60,64,75,.75);color:#fff;backdrop-filter:blur(6px)}
.hbtn svg{width:16px;height:16px;fill:currentColor}

/* ===== 组件 ===== */
.chips{display:flex;gap:8px;overflow-x:auto;padding:2px 16px 8px;scrollbar-width:none}
.chips::-webkit-scrollbar{display:none}
.chip{flex-shrink:0;padding:8px 15px;border-radius:20px;background:var(--card);color:var(--tx2);font-size:12.5px;cursor:pointer;border:none;transition:.15s;font-weight:500}
.chip.on{background:var(--accent);color:#fff;font-weight:700}
.more{display:block;margin:16px auto;padding:11px 24px;border-radius:12px;background:var(--card);color:var(--accent);
  border:1px solid #262d3c;font-size:13px;cursor:pointer;font-weight:600}
.searchbar{margin:6px 16px 14px;display:flex;align-items:center;gap:9px;background:var(--card);border-radius:13px;padding:12px 13px}
.searchbar svg{width:16px;height:16px;stroke:var(--tx2);fill:none;stroke-width:2}
.searchbar input{flex:1;background:none;border:none;outline:none;color:var(--tx);font-size:14.5px}
.searchbar input::placeholder{color:#5d6675}
.empty{text-align:center;padding:60px 30px;color:var(--tx2)}
.empty .ic{font-size:40px;margin-bottom:10px;opacity:.5}
.empty .tt{font-size:15px;font-weight:700;color:var(--tx)}
.empty .st{font-size:12px;margin-top:5px;line-height:1.7}

/* 详情 */
.detail-hero{height:300px;position:relative;background:var(--card2)}
.detail-hero img{width:100%;height:100%;object-fit:cover}
.detail-hero .g{position:absolute;inset:0;background:linear-gradient(180deg,rgba(11,14,20,.25) 30%,rgba(11,14,20,.55) 62%,var(--bg))}
.backbtn{position:absolute;top:12px;left:14px;width:36px;height:36px;border-radius:50%;background:rgba(15,17,22,.6);
  backdrop-filter:blur(6px);border:none;color:#fff;font-size:19px;cursor:pointer;z-index:5;display:flex;align-items:center;justify-content:center}
.dhead{display:flex;gap:13px;padding:0 16px;margin-top:-72px;position:relative;z-index:2;align-items:flex-end}
.dhead .poster{width:104px;height:156px;border-radius:12px;overflow:hidden;box-shadow:0 10px 28px rgba(0,0,0,.55);background:var(--card2);flex-shrink:0}
.dhead img{width:100%;height:100%;object-fit:cover}
.dhead .t{font-size:21px;font-weight:800;color:var(--tx);line-height:1.3;padding-bottom:4px}
.tags{display:flex;gap:8px;flex-wrap:wrap;margin:13px 16px 0}
.tag{padding:4px 11px;border-radius:14px;background:var(--card);color:var(--tx2);font-size:11.5px}
.btnrow{display:flex;gap:10px;margin:16px 16px 0}
.btn{flex:1;display:flex;align-items:center;justify-content:center;gap:7px;padding:13px 0;border-radius:13px;
  font-size:15px;font-weight:700;cursor:pointer;border:none;transition:.15s;letter-spacing:.5px}
.btn:active{transform:scale(.97)}
.btn.primary{background:var(--accent);color:#fff;box-shadow:0 6px 18px color-mix(in srgb,var(--accent) 35%,transparent)}
.btn.ghost{background:var(--card);color:var(--tx);border:1px solid #2a3140;flex:0 0 112px}
.btn.ghost.faved{color:var(--accent);border-color:var(--accent)}
.sum{margin:14px 16px 0;font-size:13px;color:var(--tx2);line-height:1.8}
.credits{margin:14px 16px 0;font-size:12.5px;color:var(--tx2);line-height:2}
.credits b{color:var(--tx);font-weight:600;margin-right:8px}
.lines{margin:0 16px}
.line{display:flex;align-items:center;gap:10px;background:var(--card);border-radius:11px;padding:12px 14px;margin-top:9px;
  cursor:pointer;border:1px solid transparent;transition:.15s}
.line:hover{border-color:var(--accent)}
.line .ic{color:var(--accent);font-size:13px}
.line .nm{font-size:13px;color:var(--tx);font-weight:600}
.line .host{margin-left:auto;font-size:10.5px;color:var(--tx2)}

/* 播放器 */
.player{position:absolute;inset:0;background:#000;z-index:80;display:flex;align-items:center;justify-content:center}
.player video{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000}
.player .top{position:absolute;top:0;left:0;right:0;display:flex;align-items:center;gap:10px;padding:50px 18px 12px;
  background:linear-gradient(180deg,rgba(0,0,0,.7),transparent);z-index:5}
.player .top .t{color:#fff;font-size:14px;font-weight:600}
.player .fail{position:relative;z-index:4;text-align:center;padding:30px;background:rgba(10,10,12,.82);border-radius:18px;max-width:290px}
.player .fail .ic{font-size:38px;opacity:.7}
.player .fail .t{color:#fff;font-size:16px;font-weight:700;margin:8px 0 4px}
.player .fail .s{color:rgba(255,255,255,.65);font-size:12px;line-height:1.6;margin-bottom:16px}
.player .fail .btnrow{margin:0}
/* 播放器控制层（竖屏/横屏通用） */
.player .ctrl{position:absolute;inset:0;z-index:3;display:flex;flex-direction:column;justify-content:space-between;
  opacity:1;transition:opacity .25s;pointer-events:auto;
  background:linear-gradient(180deg,rgba(0,0,0,.55),transparent 24%,transparent 76%,rgba(0,0,0,.62))}
.player .ctrl.hide{opacity:0;pointer-events:none}
.player .ctrl .tapzone{position:absolute;inset:0;z-index:-1}
.trow{display:flex;align-items:center;gap:9px;padding:52px 16px 8px}
.ptitle{color:#fff;font-size:13.5px;font-weight:600;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pbtn{width:38px;height:38px;border-radius:50%;background:rgba(255,255,255,.13);border:none;color:#fff;
  font-size:15px;cursor:pointer;flex-shrink:0;display:flex;align-items:center;justify-content:center;backdrop-filter:blur(6px)}
.pbtn:active{transform:scale(.92)}
.pbar{display:flex;align-items:center;gap:10px;padding:10px 16px 22px}
.seek{flex:1;-webkit-appearance:none;appearance:none;height:4px;border-radius:2px;background:rgba(255,255,255,.28);outline:none;cursor:pointer}
.seek::-webkit-slider-thumb{-webkit-appearance:none;width:14px;height:14px;border-radius:50%;background:var(--accent);cursor:pointer;box-shadow:0 0 8px rgba(0,0,0,.5)}
.tm{color:rgba(255,255,255,.82);font-size:11px;font-variant-numeric:tabular-nums;flex-shrink:0}
.pchip{padding:7px 13px;border-radius:17px;background:rgba(255,255,255,.15);border:none;color:#fff;
  font-size:11.5px;cursor:pointer;font-weight:600;flex-shrink:0;backdrop-filter:blur(6px)}
.sheet{position:absolute;left:0;right:0;bottom:0;background:rgba(17,20,27,.97);border-radius:20px 20px 0 0;
  padding:16px 18px 24px;z-index:6;backdrop-filter:blur(12px);border-top:1px solid #232a38}
.sheet .sh-t{color:#fff;font-size:13px;font-weight:700;margin-bottom:12px;display:flex;align-items:center;justify-content:space-between}
.sheet .sh-x{color:var(--tx2);font-size:16px;cursor:pointer;background:none;border:none}
.sheet .opts{display:flex;flex-wrap:wrap;gap:9px}
.sheet .opt{padding:8px 16px;border-radius:18px;background:#232a38;color:var(--tx);font-size:12.5px;cursor:pointer;border:none}
.sheet .opt.on{background:var(--accent);color:#fff;font-weight:700}
/* 横屏模式：手机容器整体转横 + 控制条贴边 */
.phone.land{width:864px;height:424px;border-radius:40px}
.phone.land .screen{border-radius:30px}
.phone.land .grid{grid-template-columns:repeat(5,1fr)}
.phone.land .player .trow{padding:14px 18px 8px}
.phone.land .player .pbar{padding:8px 20px 16px}
.phone.land .player video{object-fit:contain}
.phone.land .player .top{padding:12px 18px 8px}

/* 我的 */
.profile{display:flex;align-items:center;gap:14px;padding:6px 18px 16px}
.profile .av{width:58px;height:58px;border-radius:18px;display:flex;align-items:center;justify-content:center}
.profile .av svg{width:28px;height:28px;fill:#fff}
.profile .nm{font-size:18px;font-weight:800;color:var(--tx)}
.profile .sub2{font-size:11px;color:var(--tx2);margin-top:3px}
.seg{display:flex;margin:0 16px 8px;background:var(--card);border-radius:11px;padding:3px}
.seg button{flex:1;padding:9px 0;border:none;border-radius:9px;background:none;color:var(--tx2);font-size:13px;cursor:pointer;font-weight:600;transition:.15s}
.seg button.on{background:var(--card2);color:var(--tx);box-shadow:0 2px 8px rgba(0,0,0,.35)}
.listrow{display:flex;align-items:center;gap:12px;padding:10px 16px;cursor:pointer}
.listrow .img{width:50px;height:75px;border-radius:8px;overflow:hidden;background:var(--card2);flex-shrink:0}
.listrow img{width:100%;height:100%;object-fit:cover}
.listrow .t{font-size:13.5px;color:var(--tx);font-weight:600;line-height:1.4}
.listrow .m{font-size:11px;color:var(--tx2);margin-top:3px}
.mbtn{display:block;width:calc(100% - 32px);margin:10px 16px 0;padding:12px 0;border-radius:12px;background:var(--card);
  color:var(--accent);border:1px solid #262d3c;font-size:13.5px;font-weight:600;cursor:pointer}
.ver{font-size:10.5px;color:#565f6f;text-align:center;padding:18px 0 6px}


/* 设置页 */
.sgroup{margin:0 16px 14px;background:var(--card);border-radius:14px;overflow:hidden}
.srow{display:flex;align-items:center;gap:10px;padding:13px 16px;border-bottom:1px solid #1a2029;min-height:48px}
.srow:last-child{border-bottom:none}
.srow .ic2{font-size:16px;width:22px;text-align:center}
.srow .lb{font-size:13.5px;font-weight:600;color:var(--tx)}
.srow .sub{flex:1;font-size:11px;color:var(--tx2);margin-top:2px}
.srow .val{margin-left:auto;font-size:12px;color:var(--tx2)}
.srow .chev{color:#565f6f;font-size:15px;margin-left:6px}
.srow.click{cursor:pointer}
.srow.click:active{background:#1a2029}
.sw{width:46px;height:28px;border-radius:14px;background:#2a3140;position:relative;cursor:pointer;transition:.2s;flex-shrink:0;margin-left:auto}
.sw.on{background:var(--accent)}
.sw::after{content:'';position:absolute;top:3px;left:3px;width:22px;height:22px;border-radius:50%;background:#fff;transition:.2s}
.sw.on::after{left:21px}
.badge{font-size:9.5px;padding:2px 7px;border-radius:9px;background:color-mix(in srgb,var(--accent) 20%,transparent);color:var(--accent);font-weight:700}
.badge.gray{background:#232a38;color:var(--tx2)}
.siterow{display:flex;align-items:center;gap:10px;padding:11px 16px;border-bottom:1px solid #1a2029}
.siterow .nm{font-size:13px;font-weight:600;color:var(--tx)}
.siterow .api{font-size:10px;color:var(--tx2);margin-top:2px;max-width:190px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.siterow.off .nm,.siterow.off .api{opacity:.4}
.toast{position:absolute;left:50%;bottom:110px;transform:translateX(-50%);background:rgba(30,34,44,.95);color:#fff;
  font-size:12.5px;padding:10px 18px;border-radius:20px;z-index:120;white-space:nowrap;backdrop-filter:blur(8px)}

/* 直播 */
.liverow{display:flex;align-items:center;gap:12px;margin:0 16px 10px;background:var(--card);border-radius:13px;padding:14px;cursor:pointer}
.liverow .ic{width:38px;height:38px;border-radius:11px;background:color-mix(in srgb,var(--accent) 18%,transparent);
  display:flex;align-items:center;justify-content:center;color:var(--accent);font-size:15px}
.liverow .t{font-size:14px;font-weight:600;color:var(--tx)}
.liverow .s{font-size:11px;color:var(--tx2);margin-top:2px}
.liverow .pl{margin-left:auto;color:var(--accent);font-size:17px}
</style>
</head>
<body>
<h1>三款 iOS App · 交互原型</h1>
<div class="sub">真实生产数据 + 真实海报直链 + 真实播放（HLS）· 内容优先布局 · 按手机屏与主流流媒体规范设计<br>
界面内不展示 LOGO 名字与片库数量 · 三 App 以图标与主题色区分，内容池严格隔离</div>
<div class="switcher" id="switcher"></div>
<div class="phone"><div class="island"></div><div class="screen" id="screen"></div></div>
<div class="hint" id="hint">👆 点上方图标切换产品（左→右：普通影视 / 儿童 / 成人）· 手机里所有 Tab、海报、按钮均可点</div>

<script>
const DATA = __DATA__;
const GLYPH = {
  star:'<svg viewBox="0 0 24 24"><path d="M12 2.5l2.9 5.9 6.5.9-4.7 4.6 1.1 6.5L12 17.3l-5.8 3.1 1.1-6.5L2.6 9.3l6.5-.9z"/></svg>',
  house:'<svg viewBox="0 0 24 24"><path d="M12 3l9 8h-2.5v9h-4.8v-6h-3.4v6H5.5v-9H3z"/></svg>',
  moon:'<svg viewBox="0 0 24 24"><path d="M20.5 14.8A8.6 8.6 0 0 1 9.2 3.5a8.6 8.6 0 1 0 11.3 11.3z"/></svg>'
};
const ICONS = {
  home:'<svg viewBox="0 0 24 24"><path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z"/></svg>',
  grid:'<svg viewBox="0 0 24 24"><rect x="3" y="3" width="7.5" height="7.5" rx="2"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="2"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="2"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="2"/></svg>',
  search:'<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.8-3.8"/></svg>',
  live:'<svg viewBox="0 0 24 24"><path d="M4 9v6M8 5v14M12 8v8M16 4v16M20 9v6"/></svg>',
  me:'<svg viewBox="0 0 24 24"><circle cx="12" cy="8" r="4"/><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6"/></svg>',
  bell:'<svg viewBox="0 0 24 24"><path d="M18 9a6 6 0 1 0-12 0c0 6-2.5 7-2.5 7h17S18 15 18 9"/><path d="M10 20a2 2 0 0 0 4 0"/></svg>',
  play:'<svg viewBox="0 0 24 24"><path d="M7 4.5v15l13-7.5z"/></svg>',
  info:'<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 8h.01M11 12h1v5h1" stroke-width="2"/></svg>'
};
let app='xingmu', tab='home', seg=0;
let favs={}, hist={};
try{favs=JSON.parse(localStorage.getItem('wb_favs')||'{}')}catch(e){}
try{hist=JSON.parse(localStorage.getItem('wb_hist')||'{}')}catch(e){}
function saveLib(){ try{
  localStorage.setItem('wb_favs',JSON.stringify(favs));
  localStorage.setItem('wb_hist',JSON.stringify(hist));
}catch(e){} }
let selCat=null, selYear=null, visible=60;

const esc=(s)=>String(s??'').replace(/[<>&"]/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;'}[c]));
const fmt=(n)=>n>=10000?(n/10000).toFixed(1)+'万':String(n??0);
const D=()=>DATA[app];

function renderSwitcher(){
  document.getElementById('switcher').innerHTML = Object.keys(DATA).map(k=>{
    const p=DATA[k];
    return '<div class="appchip '+(k===app?'active':'')+'" style="--ac:'+p.accent+'" title="'+p.name+'" onclick="switchApp(\''+k+'\')">'
      + GLYPH[p.glyph] + '</div>';
  }).join('');
  document.getElementById('screen').style.setProperty('--accent', D().accent);
}
function switchApp(k){ app=k; tab='home'; selCat=null; selYear=null; visible=60; render(); }

function tabsFor(){ const t=[['home','首页',ICONS.home],['cat','分类',ICONS.grid],['search','搜索',ICONS.search]];
  if(D().live) t.push(['live','直播',ICONS.live]); t.push(['me','我的',ICONS.me]); return t; }

function render(){
  renderSwitcher();
  const s=document.getElementById('screen');
  const tabs=tabsFor();
  let tabbar='<div class="tabbar">' + tabs.map((x)=>{
    return '<div class="tab '+(tab===x[0]?'active':'')+'" onclick="go(\''+x[0]+'\')">'+x[2]+'<span>'+x[1]+'</span></div>';
  }).join('') + '</div>';
  s.innerHTML='<div class="statusbar"><span id="clock">'+new Date().toTimeString().slice(0,5)+'</span>'
    +'<span class="right">●●● 🛜 🔋</span></div>'
    +'<div class="apparea"><div id="pages"></div></div>'+tabbar;
  renderPage();
  tickClock();
}
function go(t){ tab=t; renderPage();
  const tb=document.querySelectorAll('.tab'); const ks=tabsFor().map(x=>x[0]);
  tb.forEach((e,i)=>e.classList.toggle('active',ks[i]===t)); }

function renderPage(){
  const root=document.getElementById('pages');
  if(tab==='home') root.innerHTML=pageHome();
  else if(tab==='cat') root.innerHTML='<div class="ptitle">分类</div>'+pageCat();
  else if(tab==='search') root.innerHTML='<div class="ptitle">搜索</div>'+pageSearch();
  else if(tab==='live') root.innerHTML='<div class="ptitle">直播</div>'+pageLive();
  else root.innerHTML='<div class="ptitle">我的</div>'+pageMe();
}
function pcard(it){ return '<div class="pcard" onclick="openDetail(\''+it.id+'\')">'
  +'<div class="img"><img class="shm" src="'+esc(it.img)+'" loading="lazy" onload="this.classList.remove(\'shm\')" onerror="this.classList.remove(\'shm\');this.style.opacity=.12">'
  +(it.y?'<div class="yr">'+esc(it.y)+'</div>':'')+'</div><div class="t">'+esc(it.t)+'</div></div>'; }
/* 继续观看卡：续播角标 + 进度条，点击直接续播 */
function ccard(it,h){ const pct=h.d>0?Math.min(100,h.p/h.d*100):(h.p>0?6:0);
  return '<div class="pcard" onclick="playItem(\''+it.id+'\',0)">'
  +'<div class="img"><img class="shm" src="'+esc(it.img)+'" loading="lazy" onload="this.classList.remove(\'shm\')" onerror="this.classList.remove(\'shm\');this.style.opacity=.12">'
  +'<div class="rsum">续播</div><div class="prog"><i style="width:'+pct.toFixed(1)+'%"></i></div></div>'
  +'<div class="t">'+esc(it.t)+'</div></div>'; }
function rail(title,items,extra){ if(!items.length)return '';
  return '<div class="sec-t">'+title+(extra||'')+'</div><div class="rail">'
    + items.slice(0,20).map(pcard).join('') + '</div>'; }

function pageHome(){
  const items=D().items;
  const hero=items[0];
  const hot=items.filter(i=>i.img).slice(1,21);
  const fresh=[...items.filter(i=>i.y)].sort((a,b)=>(b.y>a.y?1:-1)).slice(0,20);
  const resume=Object.entries(hist).map(([id,h])=>({id:id,h:h}))
    .filter(x=>D().items.some(i=>i.id===x.id)).sort((a,b)=>b.h.at-a.h.at).slice(0,12)
    .map(x=>{const it=D().items.find(i=>i.id===x.id); return {it:it,h:x.h};}).filter(x=>x.it);
  let h='';
  /* 顶部频道导航（腾讯式） */
  h+='<div class="chips" style="padding:2px 16px 8px">'
    +'<button class="chip on" onclick="scrollToTop()">精选</button>'
    +D().categories.slice(0,8).map(c=>'<button class="chip" onclick="jumpCat(\''+esc(c.id)+'\')">'+esc(c.name)+'</button>').join('')+'</div>';
  if(hero){
    h+='<div class="hero" onclick="openDetail(\''+hero.id+'\')"><img src="'+esc(hero.img)+'" onerror="this.remove()">'
      +'<div class="grad"></div><div class="info"><div class="t">'+esc(hero.t)+'</div>'
      +'<div class="m">'+[hero.y,hero.cat,hero.q?Math.round(hero.q*10)+' 分':''].filter(Boolean).join(' · ')+'</div>'
      +'<div class="btns"><button class="hbtn primary" onclick="event.stopPropagation();playItem(\''+hero.id+'\',0)">▶ 播放</button>'
      +'<button class="hbtn ghost" onclick="event.stopPropagation();openDetail(\''+hero.id+'\')">ⓘ 详情</button></div></div></div>';
  }
  if(resume.length){
    h+='<div class="sec-t">继续观看</div><div class="rail">'
      +resume.map(x=>ccard(x.it,x.h)).join('')+'</div>';
  }
  h+=rail('热门推荐',hot);
  h+=rail('新片速递',fresh);
  h+='<div class="sec-t">分类<button class="morelnk" onclick="go(\'cat\')">全部 ›</button></div>'
    +'<div class="chips">'+D().categories.map(c=>
      '<button class="chip" onclick="jumpCat(\''+esc(c.id)+'\')">'+esc(c.name)+'</button>').join('')+'</div>';
  h+='<div style="height:30px"></div>';
  return h;
}
function scrollToTop(){ const pg=document.getElementById('pages'); if(pg)pg.scrollTo({top:0,behavior:'smooth'}); }
function jumpCat(id){ selCat=id; selYear=null; visible=60; tab='cat'; render(); }

function pageCat(){
  const items=D().items;
  const cf= selCat? items.filter(i=>i.cat && (i.cat===D().categories.find(c=>c.id===selCat)?.name||selCat)) : items;
  let years=[]; const seen=new Set();
  for(const it of cf){ if(it.y && !seen.has(it.y)){seen.add(it.y);years.push(it.y);if(years.length>15)break;} }
  years=years.sort().reverse();
  const fl= selYear? cf.filter(i=>i.y===selYear) : cf;
  const onSites=(cfg&&!cfg.repo)?cfg.sites.filter(x=>x.on):[];
  let h=(onSites.length?'<div class="sec-t">自定义点播站点</div><div class="chips">'+onSites.map(s2=>'<button class="chip" onclick="toast(\'真机端：按站点 api 实时采集（TVBox 蜘蛛逻辑原生运行）\')">'+esc(s2.name)+'</button>').join('')+'</div>':'')
  +'<div class="chips" style="padding-top:6px">'
    +'<button class="chip '+(selCat?'':'on')+'" onclick="pickCat(null)">全部</button>'
    +D().categories.map(c=>'<button class="chip '+(selCat===c.id?'on':'')+'" onclick="pickCat(\''+esc(c.id)+'\')">'+esc(c.name)+'</button>').join('')+'</div>';
  if(years.length){
    h+='<div class="chips"><button class="chip '+(selYear?'':'on')+'" onclick="selYear=null;renderPage()">年份</button>'
      +years.map(y=>'<button class="chip '+(selYear===y?'on':'')+'" onclick="pickYear(\''+y+'\')">'+y+'</button>').join('')+'</div>';
  }
  return h+catGrid(fl);
}
function catGrid(fl){
  if(!fl.length) return '<div class="empty"><div class="ic">🎬</div><div class="tt">该分类暂无内容</div><div class="st">换个分类或年份看看</div></div>';
  let h='<div class="grid">'+fl.slice(0,visible).map(pcard).join('')+'</div>';
  if(fl.length>visible) h+='<button class="more" onclick="visible+=60;renderPage()">加载更多（共 '+fl.length+'）</button>';
  return h;
}
function pickCat(id){ selCat=(selCat===id)?null:id; selYear=null; visible=60; renderPage(); }
function pickYear(y){ selYear=(selYear===y)?null:y; visible=60; renderPage(); }

let searchQ='';
let shHist=null; try{shHist=JSON.parse(localStorage.getItem('wb_sh')||'null')}catch(e){}
if(!shHist) shHist=[];
let shTimer=null;
function recordSh(q){
  clearTimeout(shTimer);
  shTimer=setTimeout(()=>{
    q=q.trim(); if(q.length<2)return;
    shHist=[q,...shHist.filter(x=>x!==q)].slice(0,8);
    localStorage.setItem('wb_sh',JSON.stringify(shHist));
  },900);
}
function clearSh(){ shHist=[]; localStorage.removeItem('wb_sh'); renderPage(); }
function fillSh(q){ searchQ=q; const el=document.getElementById('sq'); if(el)el.value=q; onSearch(q); }
function pageSearch(){
  return '<div class="searchbar">🔍<input id="sq" placeholder="搜片名 / 演员 / 导演" value="'+esc(searchQ)+'"'
    +' oninput="onSearch(this.value)">'
    +(searchQ?'<button style="background:none;border:none;color:var(--tx2);font-size:15px;cursor:pointer;padding:0 2px" onclick="fillSh(\'\')">✕</button>':'')
    +'</div><div id="sres">'+searchRes()+'</div>';
}
function onSearch(v){ searchQ=v; recordSh(v); document.getElementById('sres').innerHTML=searchRes(); }
function searchRes(){
  const q=searchQ.trim();
  if(!q){
    let h='';
    if(shHist.length){
      h+='<div class="sect-hd"><div class="sec-t">搜索历史</div><button class="cl" onclick="clearSh()">🗑 清空</button></div>'
        +'<div class="chips" style="padding-top:2px">'+shHist.map(s=>'<button class="chip" onclick="fillSh(\''+esc(s).replace(/'/g,"\\'")+'\')">'+esc(s)+'</button>').join('')+'</div>';
    }
    const hot=D().items.filter(i=>i.img&&i.q).sort((a,b)=>b.q-a.q).slice(0,10);
    if(hot.length){
      h+='<div class="sec-t">热门搜索</div>'+hot.map((it,i)=>
        '<div class="hotrow" onclick="fillSh(\''+esc(it.t).replace(/'/g,"\\'")+'\')">'
        +'<span class="no '+(i<3?'top':'')+'">'+(i+1)+'</span><span class="ht">'+esc(it.t)+'</span>'
        +'<span class="hm">'+(it.q?Math.round(it.q*10)+' 分':'')+'</span></div>').join('');
    }
    return h||'<div class="empty"><div class="ic">🔍</div><div class="tt">搜你想看的</div><div class="st">支持片名、演员、导演（本地秒搜）</div></div>';
  }
  const pre=[],con=[],ppl=[];
  for(const it of D().items){ if(it.t.startsWith(q))pre.push(it); else if(it.t.includes(q))con.push(it);
    else if(it.act.some(a=>a.includes(q))||it.dir.some(d=>d.includes(q)))ppl.push(it); }
  const r=[...pre,...con,...ppl].slice(0,60);
  if(!r.length) return '<div class="empty"><div class="ic">🤔</div><div class="tt">没有找到「'+esc(q)+'」</div><div class="st">试试更短的关键词</div></div>';
  return '<div class="grid">'+r.map(pcard).join('')+'</div>';
}

function pageLive(){
  if(cfg&&cfg.lives.length){
    if(!liveChans&&!liveErr){ loadLive();
      return '<div class="empty"><div class="ic">📡</div><div class="tt">加载自定义频道…</div><div class="st">来自你的 TVBox 配置</div></div>'; }
    const chs=liveChans||[];
    if(!chs.length) return '<div class="empty"><div class="ic">📡</div><div class="tt">配置里没有可用频道</div><div class="st">在配置中心检查 lives 字段（M3U / channels）</div></div>';
    return '<div style="height:8px"></div>'+chs.slice(0,80).map((c,i)=>
      '<div class="liverow" onclick="playLive(liveChans['+i+'])"><div class="ic">📺</div>'
      +'<div><div class="t">'+esc(c.name)+'</div><div class="s">'+esc(c.grp||'自定义直播')+'</div></div><div class="pl">▶</div></div>').join('')
      +'<div class="ver">频道来自你的 TVBox 配置 · 真机端原生播放</div>';
  }
  return '<div class="empty" style="padding-top:90px"><div class="ic">📡</div>'
    +'<div class="tt">暂未配置直播源</div>'
    +'<div class="st">在 设置 → TVBox 配置订阅 中添加<br>支持 M3U / JSON 频道表 / 多仓</div>'
    +'<button class="more" style="margin-top:18px" onclick="go(\'me\');openCfg()">去添加</button></div>';
}

let curItem=null;
function openDetail(id){ curItem=D().items.find(i=>i.id===id); if(!curItem)return;
  document.getElementById('pages').innerHTML=detailHTML(); const pg=document.getElementById('pages'); if(pg)pg.scrollTop=0; }
function closeDetail(){ renderPage(); }
function detailHTML(){
  const it=curItem, faved=!!favs[it.id];
  const tags=[it.y,it.cat,it.q?('评分 '+Math.round(it.q*10)):'',it.type==='movie'?'电影':it.type==='tv'?'电视剧':it.type==='short'?'短剧':it.type].filter(Boolean);
  let h='<div class="detail-hero">'+(it.img?'<img src="'+esc(it.img)+'" onerror="this.remove()">':'')
    +'<div class="g"></div><button class="backbtn" onclick="closeDetail()">‹</button></div>'
    +'<div class="dhead"><div class="poster">'+(it.img?'<img src="'+esc(it.img)+'">':'')+'</div>'
    +'<div class="t">'+esc(it.t)+'</div></div>'
    +'<div class="tags">'+tags.map(t=>'<div class="tag">'+esc(t)+'</div>').join('')+'</div>'
    +'<div class="btnrow"><button class="btn primary" onclick="playItem(\''+it.id+'\',0)">'+resumeLabel(it)+'</button>'
    +'<button class="btn ghost '+(faved?'faved':'')+'" id="favbtn" onclick="toggleFav(\''+it.id+'\')">'+(faved?'♥ 已收藏':'♡ 收藏')+'</button></div>';
  if(it.sum) h+='<div class="sum">'+esc(it.sum)+'…</div>';
  if(it.dir.length||it.act.length){
    h+='<div class="credits">';
    if(it.dir.length) h+='<div><b>导演</b>'+esc(it.dir.join(' / '))+'</div>';
    if(it.act.length) h+='<div><b>主演</b>'+esc(it.act.join(' / '))+'</div>';
    h+='</div>';
  }
  if(it.play.length>1){
    h+='<div class="sec-t">播放线路（'+it.play.length+'）</div><div class="lines">';
    it.play.forEach((u,i)=>{
      let host=''; try{ host=new URL(u).host||''; }catch(e){}
      h+='<div class="line" onclick="playItem(\''+it.id+'\','+i+')"><span class="ic">🔗</span>'
        +'<span class="nm">线路 '+(i+1)+'</span><span class="host">'+esc(host)+'</span></div>';
    });
    h+='</div>';
  }
  /* 相关推荐：同分类/同类型优先，海报横滑 */
  const rel=D().items.filter(i=>i.id!==it.id&&i.img&&((it.cat&&i.cat===it.cat)||i.type===it.type)).slice(0,12);
  if(rel.length) h+=rail('相关推荐',rel);
  h+='<div style="height:40px"></div>';
  return h;
}
function resumeLabel(it){ const h=hist[it.id]; return h&&h.p>30?('续播 '+fmtT(h.p)):'▶ 立即播放'; }
function fmtT(s){ s=Math.floor(s); const p=(n)=>String(n).padStart(2,'0');
  return p(Math.floor(s/3600))+':'+p(Math.floor(s%3600/60))+':'+p(s%60); }
function toggleFav(id){ favs[id]=!favs[id]; saveLib(); const b=document.getElementById('favbtn');
  b.classList.toggle('faved',favs[id]); b.textContent=favs[id]?'♥ 已收藏':'♡ 收藏'; toast(favs[id]?'已加入收藏':'已取消收藏'); }

/* ===== 播放器：真实源 + hls.js + 横竖屏/倍速/画质/锁定 ===== */
let hls=null, curLine=0, playTimer=null, locked=false, isLiveP=false, hideT=null, ptick=0;
let rateSt=null; try{rateSt=JSON.parse(localStorage.getItem('wb_rate')||'null')}catch(e){}
if(!rateSt) rateSt={rate:1,land:false};
function fmtT(s){s=Math.max(0,Math.floor(s||0));const m=Math.floor(s/60);return (m<10?'0':'')+m+':'+('0'+(s%60)).slice(-2)}
function applyLand(on){
  rateSt.land=on; localStorage.setItem('wb_rate',JSON.stringify(rateSt));
  document.querySelector('.phone').classList.toggle('land',on);
  const ov=document.getElementById('player'); if(ov) ov.classList.toggle('land',on);
}
function toggleOrient(){
  const on=!document.querySelector('.phone').classList.contains('land');
  applyLand(on); toast(on?'已切换横屏 · 控制条已适配':'已切换竖屏');
}
function toggleLock(){
  locked=!locked;
  const c=document.getElementById('pctrl');
  if(c){ c.classList.toggle('hide',locked);
    c.querySelectorAll('.pbtn,.pchip,.seek').forEach(el=>{ if(!el.id||el.id!=='lockbtn') el.style.display=locked?'none':''; });
    const lb=document.getElementById('lockbtn'); if(lb){ lb.style.display=''; lb.textContent=locked?'🔒':'🔓'; } }
  toast(locked?'已锁定 · 点锁图标解锁':'已解锁');
}
function togglePP(){
  const v=document.getElementById('pv'); if(!v)return;
  if(v.paused){ v.play().catch(()=>{}); const b=document.getElementById('ppbtn'); if(b)b.textContent='⏸'; }
  else { v.pause(); const b=document.getElementById('ppbtn'); if(b)b.textContent='▶'; }
}
function seekBy(d){
  const v=document.getElementById('pv'); if(!v||isLiveP)return;
  v.currentTime=Math.max(0,v.currentTime+d); pokeCtrl();
}
function seekUI(p){ const v=document.getElementById('pv'); if(v) v.currentTime=v.duration*p/100; }
function pokeCtrl(){
  const c=document.getElementById('pctrl'); if(!c||locked)return;
  c.classList.remove('hide'); clearTimeout(hideT);
  hideT=setTimeout(()=>{ if(!locked)c.classList.add('hide'); },3400);
}
function sheetRate(){
  const ps=[0.5,0.75,1,1.25,1.5,2];
  const opts=ps.map(r=>'<button class="opt '+(rateSt.rate===r?'on':'')+'" onclick="pickRate('+r+')">'+(r===1?'正常':r+'x')+'</button>').join('');
  showSheet('倍速播放',opts);
}
function pickRate(r){ rateSt.rate=r; localStorage.setItem('wb_rate',JSON.stringify(rateSt));
  const v=document.getElementById('pv'); if(v)v.playbackRate=r; closeSheet(); toast('倍速 '+(r===1?'正常':r+'x')); }
function sheetQuality(){
  const lv=(hls&&hls.levels)?hls.levels:[];
  if(lv.length<2){ toast('当前源单画质 · 真机端按 HLS 自动适配'); return; }
  const cur=hls.currentLevel;
  const opts='<button class="opt '+(cur===-1?'on':'')+'" onclick="pickQ(-1)">自动</button>'
    +lv.map((l,i)=>'<button class="opt '+(i===cur?'on':'')+'" onclick="pickQ('+i+')">'+(l.height?l.height+'P':Math.round(l.bitrate/1000)+'k')+'</button>').join('');
  showSheet('画质',opts);
}
function pickQ(i){ if(hls)hls.currentLevel=i; closeSheet(); }
function sheetLine(){
  if(isLiveP||!curItem)return;
  const opts=curItem.play.map((u,i)=>'<button class="opt '+(i===curLine?'on':'')+'" onclick="pickLine('+i+')">线路 '+(i+1)+'</button>').join('');
  showSheet('播放线路',opts);
}
function pickLine(i){ closeSheet(); curLine=i; startPlay(curItem.play[curLine]);
  const t=document.querySelector('.player .ptitle'); if(t)t.textContent=curItem.t+' · 线路 '+(curLine+1); }
/* 手势：单击显隐控制 / 双击左右半屏快退快进 / 长按 3 倍速 */
let lastTap=0, lastTapX=0, lpT=null, lpOn=false;
function smartTap(e){
  const now=Date.now();
  if(now-lastTap<280 && Math.abs(e.clientX-lastTapX)<90){
    lastTap=0;
    if(isLiveP)return;
    const r=document.querySelector('.screen').getBoundingClientRect();
    const x=e.clientX-r.left, left=x<r.width/2;
    seekBy(left?-10:10); toast(left?'⏪ 快退 10s':'快进 10s ⏩');
    return;
  }
  lastTap=now; lastTapX=e.clientX;
  pokeCtrl();
}
function lpStart(){ if(isLiveP)return;
  lpT=setTimeout(()=>{ const v=document.getElementById('pv');
    if(v){ v.playbackRate=3; lpOn=true; toast('⏩ 3 倍速快进中 · 松手恢复'); } },700);
}
function lpEnd(){ clearTimeout(lpT);
  if(lpOn){ const v=document.getElementById('pv'); if(v)v.playbackRate=rateSt.rate||1; lpOn=false; } }
function showSheet(title,opts){
  closeSheet();
  const sh=document.createElement('div'); sh.className='sheet'; sh.id='psheet';
  sh.innerHTML='<div class="sh-t">'+title+'<button class="sh-x" onclick="closeSheet()">✕</button></div><div class="opts">'+opts+'</div>';
  document.querySelector('.player').appendChild(sh);
}
function closeSheet(){ document.getElementById('psheet')?.remove(); }
/* 播放器外壳：竖屏/横屏控制条一应俱全 */
function playerShell(title,url,live){
  isLiveP=!!live; locked=false;
  applyLand(rateSt.land);
  const ov=document.createElement('div'); ov.className='player'+(rateSt.land?' land':''); ov.id='player';
  ov.innerHTML='<video id="pv" autoplay playsinline muted></video>'
    +'<div class="ctrl" id="pctrl" onclick="smartTap(event)" onpointerdown="lpStart()" onpointerup="lpEnd()" onpointercancel="lpEnd()" onmouseleave="lpEnd()">'
    +'<div class="tapzone"></div>'
    +'<div class="trow"><button class="pbtn" onclick="event.stopPropagation();closePlayer()">‹</button>'
    +'<span class="ptitle">'+esc(title)+'</span>'
    +'<button class="pbtn" id="lockbtn" onclick="event.stopPropagation();toggleLock()">🔓</button>'
    +'<button class="pbtn" onclick="event.stopPropagation();toggleOrient()" title="横竖屏切换">⇄</button></div>'
    +'<div class="pbar">'
    +(live?'':'<button class="pbtn" id="ppbtn" onclick="event.stopPropagation();togglePP()">⏸</button>'
          +'<button class="pbtn" onclick="event.stopPropagation();seekBy(-10)">«</button>')
    +'<span class="tm" id="ptm">'+(live?'● 直播中':'00:00 / 00:00')+'</span>'
    +(live?'':'<input class="seek" id="pseek" type="range" min="0" max="100" value="0" onclick="event.stopPropagation()" oninput="seekUI(this.value)">'
          +'<button class="pbtn" onclick="event.stopPropagation();seekBy(10)">»</button>')
    +'<button class="pchip" onclick="event.stopPropagation();sheetRate()">倍速</button>'
    +(live?'':'<button class="pchip" onclick="event.stopPropagation();sheetLine()">线路</button>')
    +'<button class="pchip" onclick="event.stopPropagation();sheetQuality()">画质</button>'
    +'</div></div><div id="pfail"></div>';
  document.querySelector('.screen').appendChild(ov);
  hideT=setTimeout(()=>{ if(!locked)document.getElementById('pctrl')?.classList.add('hide'); },3400);
}
function playItem(id,line){
  const it=D().items.find(i=>i.id===id); if(!it||!it.play.length)return;
  curItem=it; curLine=line||0;
  playerShell(it.t+' · 线路 '+(curLine+1),it.play[curLine],false);
  hist[id]={t:it.t,img:it.img,p:0,at:Date.now()}; saveLib();
  startPlay(it.play[curLine]);
}
function startPlay(url){
  const v=document.getElementById('pv'), pf=document.getElementById('pfail');
  if(!v)return; pf.innerHTML='';
  if(hls){hls.destroy();hls=null}
  v.onerror=()=>showFail('当前线路不可用，可重试或切换其他线路');
  if(window.Hls && Hls.isSupported() && /\.m3u8/i.test(url)){
    hls=new Hls({manifestLoadingTimeOut:8000,manifestLoadingMaxRetry:1,levelLoadingTimeOut:8000,fragLoadingTimeOut:12000});
    hls.on(Hls.Events.ERROR,(e,d)=>{ if(d.fatal) showFail('HLS 流加载失败（'+(d.details||'').slice(0,40)+'）'); });
    hls.on(Hls.Events.MANIFEST_PARSED,()=>{ if(hls.levels&&hls.levels.length>1)toast('画质可选：'+hls.levels.map(l=>l.height||'').filter(Boolean).join('/')+'P'); });
    hls.loadSource(url); hls.attachMedia(v);
  } else { v.src=url; }
  v.playbackRate=rateSt.rate||1;
  v.play().catch(()=>{});
  clearInterval(playTimer);
  playTimer=setInterval(()=>{
    if(!curItem)return;
    const h=hist[curItem.id]; if(h&&v.currentTime)h.p=v.currentTime;
    if(h&&v.duration)h.d=v.duration;
    if(++ptick%5===0)saveLib();
    const tm=document.getElementById('ptm'), sk=document.getElementById('pseek');
    if(tm&&v.duration) tm.textContent=fmtT(v.currentTime)+' / '+fmtT(v.duration);
    if(sk&&v.duration&&!sk.matches(':active')) sk.value=v.currentTime/v.duration*100;
  },1000);
}
function showFail(msg){
  const pf=document.getElementById('pfail'); if(!pf)return;
  document.getElementById('pv')?.pause();
  let b='<button class="btn primary" style="flex:0 0 100px" onclick="retryPlay()">↻ 重试</button>';
  if(curItem&&curItem.play.length>1) b+='<button class="btn ghost" style="color:#fff;border-color:#444" onclick="sheetLine()">⇄ 切换线路</button>';
  pf.innerHTML='<div class="fail"><div class="ic">⚠️</div><div class="t">播放失败</div>'
    +'<div class="s">'+esc(msg)+'</div><div class="btnrow">'+b+'</div></div>';
}
function retryPlay(){ if(curItem)startPlay(curItem.play[curLine]); }
function closePlayer(){ if(hls){hls.destroy();hls=null} clearInterval(playTimer); clearTimeout(hideT);
  closeSheet(); applyLand(false); locked=false;
  document.getElementById('player')?.remove(); }


/* ===== 设置存储 / toast ===== */
let ST=null; try{ ST=JSON.parse(localStorage.getItem('wb_st')||'null'); }catch(e){}
if(!ST) ST={quality:'自动',autoNext:true,skipIntro:true,bgPlay:true,hardDec:true,dataWarn:true};
function saveST(){ localStorage.setItem('wb_st',JSON.stringify(ST)); }
function toast(msg){ const t=document.createElement('div'); t.className='toast'; t.textContent=msg;
  document.querySelector('.screen').appendChild(t); setTimeout(()=>t.remove(),1800); }

/* ===== TVBox 配置中心：多仓/单仓 JSON，驱动直播+点播 ===== */
let cfg=null; try{ cfg=JSON.parse(localStorage.getItem('wb_tvbox_cfg')||'null'); }catch(e){ cfg=null; }
let liveChans=null, liveErr='';
function parseM3U(text){
  const out=[]; let cur=null;
  text.split(/\r?\n/).forEach(line=>{
    line=line.trim();
    if(line.startsWith('#EXTINF')){ cur={name:line.split(',').pop().trim()||'频道',url:''}; }
    else if(line && !line.startsWith('#') && cur){ cur.url=line; out.push(cur); cur=null; }
  });
  return out;
}
function parseCfgJSON(j){
  if(j&&Array.isArray(j.urls)&&j.urls.length) return {repo:true,repos:j.urls.filter(u=>u&&u.url),sites:[],lives:[],src:j._src||''};
  const sites=(j.sites||[]).filter(x=>x&&x.name).map(x=>({name:x.name,type:x.type,api:x.api||'',on:true}));
  const lives=[];
  (j.lives||[]).forEach(l=>{
    if(l&&l.channels){ l.channels.forEach(c=>{ if(c&&c.name&&(c.urls||c.url))
      lives.push({name:c.name,url:(c.urls||[c.url])[0],m3u:false,grp:l.name||'自定义'}); }); }
    else if(l&&l.url){ lives.push({name:l.name||'直播源',url:l.url,m3u:true,grp:l.name||'自定义'}); }
  });
  return {repo:false,repos:[],sites:sites,lives:lives,src:j._src||'JSON'};
}
function persistCfg(){ localStorage.setItem('wb_tvbox_cfg',JSON.stringify({repo:cfg.repo,repos:cfg.repos,sites:cfg.sites,lives:cfg.lives,src:cfg.src})); }
function applyCfgJSON(j,src){ j._src=src; cfg=parseCfgJSON(j); persistCfg(); liveChans=null; liveErr=''; openCfg(); toast('配置已应用'); }
function fetchURL(u){
  const m=u.match(/^https?:\/\/raw\.githubusercontent\.com\/([^\/]+)\/([^\/]+)\/(main|master)\/(.*)$/);
  if(m) u='https://fastly.jsdelivr.net/gh/'+m[1]+'/'+m[2]+'@'+m[3]+'/'+m[4];
  return fetch(u).then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); return r.text(); });
}
/* ---- 配置中心页 ---- */
function openCfg(){
  const root=document.getElementById('pages');
  root.innerHTML=cfgHTML(); root.scrollTop=0;
}
function cfgHTML(){
  let h='<div style="display:flex;align-items:center;gap:10px;padding:6px 16px 12px">'
    +'<button class="backbtn" style="position:static;flex-shrink:0" onclick="go(\'me\')">‹</button>'
    +'<div class="sec-t" style="margin:0">TVBox 配置</div></div>';
  if(cfg&&cfg.repo){
    h+='<div class="sec-t">多仓配置（'+cfg.repos.length+' 个仓库）</div><div class="sgroup">'
      +cfg.repos.map((r,i)=>'<div class="srow click" onclick="pickRepo('+i+')"><span class="ic2">📦</span>'
        +'<div><div class="lb">'+esc(r.name||('仓库 '+(i+1)))+'</div><div class="sub">'+esc(r.url.slice(0,60))+'</div></div>'
        +'<span class="chev">›</span></div>').join('')+'</div>'
      +'<div class="ver">点按仓库名拉取并切换到该仓配置</div>';
  } else {
    h+='<div style="margin:0 16px 12px;background:var(--card);border-radius:14px;padding:14px 16px">'
      +'<div style="font-size:13px;font-weight:700;color:var(--tx)">'+(cfg?'● 已加载自定义配置':'○ 未加载（使用内置生产 feed）')+'</div>'
      +(cfg?'<div style="font-size:11.5px;color:var(--tx2);margin-top:5px;line-height:1.8">来源：'+esc((cfg.src||'JSON').slice(0,50))
        +'<br>点播站点 '+cfg.sites.length+' 个 · 直播频道 '+cfg.lives.length+' 个</div>':'')
      +'</div>';
    h+='<div class="sec-t">订阅配置地址</div>'
      +'<div class="searchbar" style="margin-bottom:10px"><input id="cfgurl" placeholder="填 TVBox 接口 / 配置 JSON 地址" value="'+(cfg&&!cfg.repo?esc(cfg.src.startsWith('http')?cfg.src:''):'')+'"></div>'
      +'<button class="mbtn" style="margin-top:0" onclick="fetchCfg()">⤓ 拉取并应用</button>';
    h+='<div class="sec-t">或粘贴 JSON</div>'
      +'<textarea id="cfgtxt" placeholder="粘贴 TVBox 配置 JSON（sites / lives / 多仓 urls）"'
      +' style="display:block;width:calc(100% - 32px);margin:0 16px;height:104px;background:var(--card);border:1px solid #262d3c;border-radius:12px;color:var(--tx);font-size:12px;padding:10px;font-family:ui-monospace,monospace;resize:none;outline:none"></textarea>'
      +'<button class="mbtn" onclick="applyCfgText()">✓ 保存并应用</button>'
      +'<button class="mbtn" style="color:var(--tx2)" onclick="fillDemo()">填入示例配置</button>'
      +(cfg?'<button class="mbtn" style="color:#e8636a;border-color:#3a2530" onclick="clearCfg()">✕ 恢复默认（清除自定义配置）</button>':'');
  }
  if(cfg&&!cfg.repo&&cfg.sites.length){
    h+='<div class="sec-t">点播站点（'+cfg.sites.filter(x=>x.on).length+'/'+cfg.sites.length+' 启用）</div><div class="sgroup">'
      +cfg.sites.map((x,i)=>'<div class="siterow'+(x.on?'':' off')+'"><div style="flex:1;min-width:0">'
        +'<div class="nm">'+esc(x.name)+' <span class="badge gray">type '+x.type+'</span></div>'
        +'<div class="api">'+esc((x.api||'—').slice(0,60))+'</div></div>'
        +'<div class="sw '+(x.on?'on':'')+'" onclick="toggleSite('+i+')"></div></div>').join('')+'</div>';
  }
  if(cfg&&!cfg.repo&&cfg.lives.length){
    h+='<div class="sec-t">直播源（'+cfg.lives.length+'）</div><div class="sgroup">'
      +cfg.lives.slice(0,30).map((l,i)=>'<div class="srow click" onclick="testLive('+i+')"><span class="ic2">📡</span>'
        +'<div style="flex:1;min-width:0"><div class="lb">'+esc(l.name)+'</div><div class="sub">'+esc((l.url||'').slice(0,50))+'</div></div>'
        +'<span class="badge">'+(l.m3u?'M3U':'直连')+'</span></div>').join('')+'</div>';
  }
  h+='<div class="ver" style="padding-top:6px">多仓 urls / 单仓 sites+lives 均支持 · M3U 频道表自动解析<br>真机端原生请求无跨域限制，浏览器预览仅支持允许跨域地址</div>';
  return h;
}
function fillDemo(){
  document.getElementById('cfgtxt').value=JSON.stringify({
    sites:[{key:"demo",name:"演示站点",type:0,api:"https://example.com/api.php/provide/vod"},
           {key:"demo2",name:"备用站点",type:1,api:"https://example2.com/vod"}],
    lives:[{name:"演示直播",channels:[{name:"演示频道",urls:["https://p.bvvvvvvvvv1f.com/video/jigongzhijianglongjiangshi/HD国语版/index.m3u8"]}]}]
  },null,1);
}
function applyCfgText(){
  const txt=document.getElementById('cfgtxt').value.trim();
  if(!txt) return toast('请先粘贴配置 JSON');
  try{ applyCfgJSON(JSON.parse(txt),'粘贴 JSON'); }
  catch(e){ toast('JSON 解析失败：'+e.message); }
}
function clearCfg(){ cfg=null; localStorage.removeItem('wb_tvbox_cfg'); liveChans=null; liveErr=''; openCfg(); toast('已恢复默认 feed'); }
function fetchCfg(){
  const u=document.getElementById('cfgurl').value.trim();
  if(!u) return toast('请先填配置地址');
  toast('正在拉取配置…');
  fetchURL(u).then(t=>applyCfgJSON(JSON.parse(t),u))
    .catch(e=>toast('拉取失败：'+String(e.message).slice(0,40)));
}
function pickRepo(i){
  const r=cfg.repos[i];
  toast('拉取仓库 '+r.name+'…');
  fetchURL(r.url).then(t=>applyCfgJSON(JSON.parse(t),r.url))
    .catch(e=>toast('仓库拉取失败：'+String(e.message).slice(0,40)));
}
function toggleSite(i){ cfg.sites[i].on=!cfg.sites[i].on; persistCfg(); openCfg(); }
function testLive(i){
  const l=cfg.lives[i];
  if(l.m3u){ toast('解析 M3U…');
    fetchURL(l.url).then(t=>{ const chs=parseM3U(t);
      if(!chs.length) return toast('M3U 里没有可用频道');
      liveChans=chs; go('live'); playLive(liveChans[0]); }).catch(()=>toast('M3U 拉取失败'));
  } else { liveChans=[{name:l.name,url:l.url,grp:l.grp}]; go('live'); playLive(liveChans[0]); }
}
/* ---- 直播页（自定义配置驱动） ---- */
function loadLive(){
  liveErr='';
  const m3us=cfg.lives.filter(l=>l.m3u), direct=cfg.lives.filter(l=>!l.m3u);
  let done=direct.map(l=>({name:l.name,url:l.url,grp:l.grp}));
  if(!m3us.length){ liveChans=done; renderPage(); return; }
  Promise.all(m3us.map(l=>fetchURL(l.url).then(t=>parseM3U(t)).catch(()=>[])))
    .then(arrs=>{ liveChans=done.concat(...arrs); renderPage(); })
    .catch(()=>{ liveErr='M3U 拉取失败'; liveChans=done; renderPage(); });
}
function playLive(ch){
  playerShell(ch.name,ch.url,true);
  startPlay(ch.url);
}
/* ---- 设置页 ---- */
function openSettings(){
  const root=document.getElementById('pages');
  const sw=(k)=>'<div class="sw '+(ST[k]?'on':'')+'" onclick="ST.'+k+'=!ST.'+k+';saveST();openSettings()"></div>';
  root.innerHTML='<div style="display:flex;align-items:center;gap:10px;padding:6px 16px 12px">'
    +'<button class="backbtn" style="position:static;flex-shrink:0" onclick="go(\'me\')">‹</button>'
    +'<div class="sec-t" style="margin:0">设置</div></div>'
    +'<div class="sec-t">TVBox 配置</div><div class="sgroup">'
    +'<div class="srow click" onclick="openCfg()"><span class="ic2">🧩</span><div style="flex:1"><div class="lb">配置订阅</div>'
    +'<div class="sub">'+(cfg?('已加载 · '+(cfg.repo?(cfg.repos.length+' 个仓库'):(cfg.sites.length+' 站点 / '+cfg.lives.length+' 频道'))):'使用内置生产 feed · 支持多仓/单仓 JSON')+'</div></div><span class="chev">›</span></div>'
    +'<div class="srow click" onclick="toast(\'真机端：自动按订阅地址刷新配置\')"><span class="ic2">⟳</span><div class="lb">自动更新配置</div>'+sw('autoCfg')+'</div></div>'
    +'<div class="sec-t">播放器</div><div class="sgroup">'
    +'<div class="srow click" onclick="ST.quality=ST.quality===\'自动\'?\'高清\':ST.quality===\'高清\'?\'流畅\':\'自动\';saveST();openSettings()">'
    +'<span class="ic2">🎞</span><div class="lb">画质偏好</div><span class="val">'+ST.quality+' ›</span></div>'
    +'<div class="srow"><span class="ic2">⏭</span><div class="lb">自动连播下一集</div>'+sw('autoNext')+'</div>'
    +'<div class="srow"><span class="ic2">⏱</span><div class="lb">自动跳过片头</div>'+sw('skipIntro')+'</div>'
    +'<div class="srow"><span class="ic2">🎧</span><div class="lb">后台播放（音频继续）</div>'+sw('bgPlay')+'</div>'
    +'<div class="srow"><span class="ic2">⚡</span><div class="lb">硬件解码（真机默认开）</div>'+sw('hardDec')+'</div></div>'
    +'<div class="sec-t">通用</div><div class="sgroup">'
    +'<div class="srow click" onclick="cleanCache()"><span class="ic2">🧹</span><div class="lb">清理图片缓存</div><span class="val" id="csize">'+cacheSize()+'</span></div>'
    +'<div class="srow click" onclick="toast(\'当前为深色主题（与产品视觉一致）\')"><span class="ic2">🌙</span><div class="lb">外观</div><span class="val">深色 ›</span></div>'
    +'<div class="srow click" onclick="toast(\'已是最新版本 v1.0\')"><span class="ic2">⬆</span><div class="lb">检查更新</div><span class="val">v1.0 ›</span></div></div>'
    +'<div class="sec-t">关于</div><div class="sgroup">'
    +'<div class="srow click" onclick="toast(\'真机端：打开用户协议\')"><div class="lb">用户协议</div><span class="chev">›</span></div>'
    +'<div class="srow click" onclick="toast(\'真机端：打开隐私政策\')"><div class="lb">隐私政策</div><span class="chev">›</span></div>'
    +'<div class="srow"><div class="lb">数据适配器</div><span class="val">ios-v1-20260919</span></div></div>'
    +'<div class="ver">iOS v1.0 · 设置与配置即时生效（localStorage 持久化）</div>';
  root.scrollTop=0;
}
let cacheMB=12.6;
function cacheSize(){ return cacheMB<1? cacheMB.toFixed(1)+' KB' : cacheMB.toFixed(1)+' MB'; }
function cleanCache(){ cacheMB=0; openSettings(); toast('缓存已清理'); }

/* ===== 我的 ===== */
function pageMe(){
  const favList=D().items.filter(i=>favs[i.id]);
  const histList=Object.entries(hist).map(([id,h])=>({id:id,...h}))
    .filter(h=>DATA[app].items.some(i=>i.id===h.id)).sort((a,b)=>b.at-a.at);
  const clearBtn=(seg===1&&histList.length)?'<button class="cl" onclick="clearHist()">🗑 清空</button>':'';
  const rows=(list,sub)=>list.length? list.map(h=>'<div class="listrow" onclick="openDetail(\''+h.id+'\')">'
      +'<div class="img">'+(h.img?'<img class="shm" src="'+esc(h.img)+'" onload="this.classList.remove(\'shm\')" onerror="this.classList.remove(\'shm\');this.style.opacity=.12">':'')+'</div>'
      +'<div style="flex:1;min-width:0"><div class="t">'+esc(h.t)+'</div>'
      +'<div class="m">'+sub(h)+'</div>'
      +(seg===1&&h.d>0?'<div style="margin-top:6px;height:3px;border-radius:2px;background:#232a38;overflow:hidden"><i style="display:block;height:100%;width:'+Math.min(100,h.p/h.d*100).toFixed(1)+'%;background:var(--accent)"></i></div>':'')
      +'</div></div>').join('')
   : '<div class="empty" style="padding:34px"><div class="ic">♡</div><div class="st">'+sub(null)+'</div></div>';
  return '<div style="margin:0 16px 12px;background:var(--card);border-radius:12px;overflow:hidden">'
  +'<div class="srow click" onclick="openCfg()"><span class="ic2">🧩</span><div style="flex:1"><div class="lb">TVBox 配置订阅</div><div class="sub">'+(cfg?(cfg.repo?(cfg.repos.length+' 个仓库'):(cfg.sites.length+' 站点 / '+cfg.lives.length+' 频道')):'内置生产 feed · 点此填入你自己的配置')+'</div></div><span class="chev">›</span></div>'
  +'<div class="srow click" onclick="openSettings()"><span class="ic2">⚙️</span><div class="lb">设置</div><span class="chev">›</span></div></div>'
  +'<div class="profile"><div class="av" style="background:var(--accent)"><svg viewBox="0 0 24 24"><circle cx="12" cy="8" r="4"/><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6"/></svg></div>'
    +'<div><div class="nm">我的</div><div class="sub2">'+D().tagline+'</div></div></div>'
    +'<div class="seg"><button class="'+(seg===0?'on':'')+'" onclick="seg=0;renderPage()">收藏 '+favList.length+'</button>'
    +'<button class="'+(seg===1?'on':'')+'" onclick="seg=1;renderPage()">历史 '+histList.length+'</button></div>'
    +(clearBtn?'<div class="sect-hd"><span style="flex:1"></span>'+clearBtn+'</div>':'')
    +(seg===0?rows(favList,()=>'点击查看详情'):rows(histList,h=>h.d>0?('看到 '+fmtT(h.p)+' / '+fmtT(h.d)):(h.p>0?('看到 '+fmtT(h.p)):'刚开始看')))
    +'<button class="mbtn" style="margin-top:16px" onclick="alert(\'真机端：重新全量同步分片（单飞闸门 + 进度胶囊）\')">⟳ 重新同步片库</button>'
    +'<div style="margin:0 16px 12px;background:var(--card);border-radius:12px;overflow:hidden">'
    +'<div class="srow click" onclick="toast(\'真机端：影片详情页可缓存到本地离线观看\')"><span class="ic2">⬇</span><div style="flex:1"><div class="lb">离线缓存</div><div class="sub">下载影片到本地 · 无网也能看</div></div><span class="chev">›</span></div>'
    +'<div class="srow click" onclick="toast(\'真机端：打开帮助与反馈\')"><span class="ic2">💬</span><div class="lb">帮助与反馈</div><span class="chev">›</span></div></div>'
    +'<div class="ver">iOS v1.0 · Adapter ios-v1</div>';
}
function clearHist(){ hist={}; localStorage.setItem('wb_hist',JSON.stringify(hist)); renderPage(); toast('观看历史已清空'); }

function tickClock(){ const c=document.getElementById('clock'); if(c) c.textContent=new Date().toTimeString().slice(0,5); }
setInterval(tickClock,10000);
render();
</script>
</body>
</html>
"""

data_js = json.dumps(DATA, ensure_ascii=False, separators=(",", ":"))
out_html = TPL.replace("__DATA__", data_js)
path = os.path.join(OUT, "index.html")
open(path, "w", encoding="utf-8").write(out_html)
print("OK", path, f"{os.path.getsize(path)/1024:.0f} KB")
for k, v in DATA.items():
    print(f"  {k}: pool={len(v['items'])} total={v['total']} cats={len(v['categories'])}")
