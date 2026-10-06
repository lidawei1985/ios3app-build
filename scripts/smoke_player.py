"""轻量播放器验收：横竖屏/倍速/线路/锁定，全部短等待，不阻塞。"""
import time
from playwright.sync_api import sync_playwright

OUT = r"F:/2026-09-19-15-19-07/ios-three-apps/build/prototype"
URL = "http://127.0.0.1:8125/index.html"

with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={"width": 1500, "height": 1000})
    ctx.route("**/*", lambda r: r.abort() if r.request.resource_type == "image" else r.continue_())
    pg = ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL, wait_until="domcontentloaded", timeout=20000)
    time.sleep(1.5)

    # 1) 竖屏播放器（控制条齐全）
    pg.evaluate("playItem(DATA[app].items[0].id,0)")
    time.sleep(1.2)
    pg.screenshot(path=OUT + "/p_player_portrait.png")
    land_before = pg.evaluate("document.querySelector('.phone').classList.contains('land')")

    # 2) 切横屏
    pg.evaluate("toggleOrient()")
    time.sleep(0.8)
    pg.screenshot(path=OUT + "/p_player_landscape.png")
    land_after = pg.evaluate("document.querySelector('.phone').classList.contains('land')")

    # 3) 倍速面板 → 选 1.5x
    pg.evaluate("sheetRate()")
    time.sleep(0.4)
    pg.screenshot(path=OUT + "/p_sheet_rate.png")
    pg.evaluate("pickRate(1.5)")
    rate_now = pg.evaluate("document.getElementById('pv').playbackRate")

    # 4) 线路面板
    pg.evaluate("sheetLine()")
    time.sleep(0.4)
    pg.screenshot(path=OUT + "/p_sheet_line.png")
    pg.evaluate("closeSheet()")

    # 5) 锁定
    pg.evaluate("toggleLock()")
    time.sleep(0.3)
    locked = pg.evaluate("locked")
    pg.evaluate("toggleLock()")

    # 6) 退出播放器 → 容器回竖屏
    pg.evaluate("closePlayer()")
    time.sleep(0.4)
    land_closed = pg.evaluate("document.querySelector('.phone').classList.contains('land')")

    # 7) 横屏下浏览分类页（网格 5 列）
    pg.evaluate("applyLand(true);go('cat')")
    time.sleep(0.6)
    pg.screenshot(path=OUT + "/p_browse_landscape.png")
    pg.evaluate("applyLand(false)")

    print("ORIENT portrait->land:", land_before, "->", land_after)
    print("RATE 1.5x applied:", rate_now == 1.5)
    print("LOCK works:", locked)
    print("EXIT resets portrait:", land_closed == False)
    print("JS pageerrors:", errs if errs else "NONE")
    b.close()
