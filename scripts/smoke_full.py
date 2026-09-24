"""全方位功能验收：继续观看/热搜/相关推荐/双击快进/长按倍速/持久化。"""
import time
from playwright.sync_api import sync_playwright

OUT = r"F:/2026-09-19-15-19-07/ios-three-apps/build/prototype"
URL = "http://127.0.0.1:8126/index.html"

with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={"width": 1500, "height": 1000})
    ctx.route("**/*", lambda r: r.abort() if r.request.resource_type == "image" else r.continue_())
    pg = ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded", timeout=20000)
    time.sleep(1.5)

    # 1) 播放几秒制造历史 → 回首页看"继续观看"
    pg.evaluate("playItem(DATA[app].items[2].id,0)")
    time.sleep(3.5)
    pg.evaluate("closePlayer()")
    pg.evaluate("go('home')")
    time.sleep(0.5)
    cw = pg.evaluate("document.querySelector('.sec-t') && document.body.innerHTML.includes('继续观看')")
    prog = pg.evaluate("!!document.querySelector('.pcard .prog')")
    pg.screenshot(path=OUT + "/f_home_cw.png")

    # 2) 搜索页：先看热搜榜（空态），再搜索制造历史，回来看历史 chips
    pg.evaluate("go('search')")
    time.sleep(0.8)
    has_hot = pg.evaluate("document.getElementById('sres').innerHTML.includes('热门搜索')")
    pg.screenshot(path=OUT + "/f_search_hot.png")
    pg.evaluate("fillSh('宇宙')")
    time.sleep(1.2)          # 等防抖记录
    pg.evaluate("go('home'); go('search'); fillSh('')")   # 清空搜索词 → 空态显示历史
    time.sleep(0.8)
    has_hist = pg.evaluate("document.getElementById('sres').innerHTML.includes('搜索历史')")

    # 3) 详情页相关推荐
    pg.evaluate("openDetail(DATA[app].items[0].id)")
    time.sleep(0.6)
    rel = pg.evaluate("document.getElementById('pages').innerHTML.includes('相关推荐')")
    pg.screenshot(path=OUT + "/f_detail_rel.png")

    # 4) 播放器：双击快进 + 长按倍速（直接调函数模拟）
    pg.evaluate("playItem(DATA[app].items[0].id,0)")
    time.sleep(3)
    t0 = pg.evaluate("document.getElementById('pv').currentTime")
    pg.evaluate("smartTap({clientX:900,clientY:400})"); time.sleep(0.1)
    pg.evaluate("smartTap({clientX:910,clientY:400})")   # 双击右半屏 → +10s
    time.sleep(0.6)
    t1 = pg.evaluate("document.getElementById('pv').currentTime")
    dbl_ok = (t1 - t0) > 5
    pg.evaluate("lpStart()"); time.sleep(1.2)
    r3 = pg.evaluate("document.getElementById('pv').playbackRate")
    pg.evaluate("lpEnd()")
    r_back = pg.evaluate("document.getElementById('pv').playbackRate")
    pg.screenshot(path=OUT + "/f_player_gesture.png")
    pg.evaluate("closePlayer()")

    # 5) 持久化：收藏后 localStorage 应有 wb_favs
    pg.evaluate("toggleFav(DATA[app].items[0].id)")
    fav_saved = pg.evaluate("JSON.parse(localStorage.getItem('wb_favs')||'{}') && Object.keys(JSON.parse(localStorage.getItem('wb_favs'))).length>0")
    hist_saved = pg.evaluate("Object.keys(JSON.parse(localStorage.getItem('wb_hist')||'{}')).length>0")

    # 6) 我的页：历史进度条 + 清空按钮 + 新入口
    pg.evaluate("go('me'); seg=1; renderPage()")
    time.sleep(0.5)
    me_ok = pg.evaluate("document.getElementById('pages').innerHTML.includes('清空') && document.getElementById('pages').innerHTML.includes('离线缓存')")
    pg.screenshot(path=OUT + "/f_me_hist.png")

    print("CONTINUE-WATCHING:", bool(cw), "progress-bar:", bool(prog))
    print("SEARCH hot:", bool(has_hot), "history:", bool(has_hist))
    print("DETAIL related:", bool(rel))
    print("DBL-TAP seek +10s:", bool(dbl_ok), f"({t0:.1f}->{t1:.1f})")
    print("LONG-PRESS 3x:", r3 == 3, "restore:", r_back == 1)
    print("PERSIST favs:", bool(fav_saved), "hist:", bool(hist_saved))
    print("ME page clear+offline:", bool(me_ok))
    print("JS pageerrors:", errs if errs else "NONE")
    b.close()
