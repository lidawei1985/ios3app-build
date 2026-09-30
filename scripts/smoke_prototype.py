# -*- coding: utf-8 -*-
"""v3 原型全链路冒烟：配置应用/站点启停/直播测播/设置页 + 截图"""
import time
from playwright.sync_api import sync_playwright

OUT = r"F:/2026-09-19-15-19-07/ios-three-apps/build/prototype"

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1200, "height": 980})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto("http://127.0.0.1:8125/index.html", wait_until="networkidle", timeout=60000)
    time.sleep(2)
    pg.screenshot(path=OUT + "/v3_home.png")

    # 1) 我的页（设置 + TVBox 配置订阅入口）
    pg.evaluate("go('me')")
    time.sleep(0.6)
    pg.screenshot(path=OUT + "/v3_me.png")

    # 2) 配置管理专页：填示例配置并应用
    pg.evaluate("openCfg()")
    time.sleep(0.4)
    pg.evaluate("document.getElementById('cfgtxt') && fillDemo()")
    pg.screenshot(path=OUT + "/v3_cfg_page.png")
    pg.evaluate("applyCfgText()")
    time.sleep(0.6)
    pg.screenshot(path=OUT + "/v3_cfg_applied.png")

    # 3) 站点启停开关
    pg.evaluate("toggleSite(0)")
    time.sleep(0.4)

    # 4) 直播测播（演示频道 = mux 测试流）
    pg.evaluate("testLive(0)")
    time.sleep(8)
    pg.screenshot(path=OUT + "/v3_live_play.png")
    playing = pg.evaluate("!!document.getElementById('pv') && document.getElementById('pv').currentTime>0")

    # 5) 设置页
    pg.evaluate("closePlayer();go('me');openSettings()")
    time.sleep(0.6)
    pg.screenshot(path=OUT + "/v3_settings.png")

    # 6) 恢复默认（清掉演示配置）
    pg.evaluate("openCfg();clearCfg()")
    time.sleep(0.4)

    print("LIVE PLAYING:", playing)
    print("JS pageerrors:", errs if errs else "NONE")
    b.close()
