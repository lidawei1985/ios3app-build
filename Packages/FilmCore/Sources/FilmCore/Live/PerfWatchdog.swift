import Foundation

/// 主线程看门狗（v76 2026-10-05）。
///
/// 为什么必须有：主人报「启动卡一下滑不动 / 响应速度太差」，但 PC 侧 WDA 的证据全是假象
/// （XCUITest 发事件前要等 App「空闲」，主视觉轮播每 5s 动画一次 → 动作挂起 ≠ UI 冻结）。
/// 真相只有一个来源：**主线程自己招供**。后台线程每 100ms 往主线程投一个空块，
/// 投递延迟 = 主线程被占用时长；≥300ms 记入 LiveDiag 黑匣子（1.5s 节流）。
/// 修复前后各跑一轮冷启动+滑动+进直播，黑匣子里「卡 Nms」的条数与时长就是唯一判据。
///
/// 线程安全：`DispatchQueue.main.sync` 从非主线程调用，无重入路径（本线程绝不持主线程要的锁）。
///
/// v76.1（2026-10-05）：光有「卡多久」不够 —— 还要知道**卡在哪一步**。
/// 主线程在进入每个可疑重活前调 `MainThreadMark.set("标签")`（一次加锁入环，纳秒级），
/// 看门狗检出卡顿时把**卡顿窗口内主线程进过的动作**按序回放写进黑匣子
/// ⇒ 一条日志同时给出「时长 + 责任动作链」。
/// 这是在本机 LC guest 里拿不到 os_log / 采样器栈时，唯一能落到**具体代码路径**的取证手段。
///
/// 为什么用环 + 时间窗而不是「当前标签」：`main.sync` 返回时卡顿已经结束，
/// 主线程往往已经走到**下一个**动作 ⇒ 只读"当前标签"会系统性错报成后继动作。
public enum MainThreadMark {

    private struct Entry { let t: Date; let s: String }
    private static let lock = NSLock()
    private static var ring: [Entry] = []
    private static let cap = 80

    public static func set(_ s: String) {
        let e = Entry(t: Date(), s: s)
        lock.lock()
        ring.append(e)
        if ring.count > cap { ring.removeFirst(ring.count - cap) }
        lock.unlock()
    }

    /// 取 (from, to] 窗口内主线程打过的标（时间序，最新在后）。
    public static func window(_ from: Date, _ to: Date) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return ring.filter { $0.t >= from && $0.t <= to }.map { $0.s }
    }
}

/// 后台重活标记（v76.3 2026-10-05）。
///
/// 为什么要有它：v76.2 复测里 `主线程·卡 9029ms` 与**后台**那次
/// `首页·货架计算 9494ms` 时长几乎相等、且卡顿时长随目录条数线性增长
/// （9945→973ms / 19998→2254ms / 89817→9029ms，≈0.1ms/条）。
/// 说明主线程不是自己在算，而是**被同一时间窗里的后台重活拖住**
/// （9 秒纯 CPU + 百万级堆分配会顶住内存分配器与内存带宽，主线程连一个空块都要排队）。
/// 把「卡顿时后台正在跑什么」写进同一条黑匣子日志 ⇒ 一条日志同时给出
/// 「卡多久 + 责任动作链 + 并发重活」，不必再靠推测。
public enum HeavyWork {
    private static let lock = NSLock()
    private static var current: String?

    public static func begin(_ name: String) {
        lock.lock(); current = name; lock.unlock()
    }
    public static func end() {
        lock.lock(); current = nil; lock.unlock()
    }
    /// 供看门狗在**投递前**采样（投递后采样会漏报：重活可能已经结束）。
    public static func name() -> String? {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}

public enum MainThreadWatchdog {
    private static let bootTime = Date()
    private static var started = false

    public static func start() {
        guard !started else { return }
        started = true
        Thread.detachNewThread {
            var lastReport = Date.distantPast
            var reportCount = 0
            while true {
                let expect = Date()
                // ★ 投递前采样：此刻后台在跑什么（投递后再取样会漏报）
                let heavy = HeavyWork.name()
                DispatchQueue.main.sync {}
                let now = Date()
                let lag = Int(now.timeIntervalSince(expect) * 1000)
                if lag >= 300, now.timeIntervalSince(lastReport) > 1.5 {
                    lastReport = now
                    reportCount += 1
                    let sinceBoot = -bootTime.timeIntervalSinceNow
                    let trail = MainThreadMark.window(expect, now)
                    let shown = trail.suffix(6).map { $0 }.joined(separator: " → ")
                    LiveDiag.write("主线程·卡 \(lag)ms（启动后 \(String(format: "%.1f", sinceBoot))s）" +
                                   "并发重活=\(heavy ?? "无")" +
                                   " 窗口动作=\(shown.isEmpty ? "（无标注·疑在 SwiftUI 渲染/系统内）" : shown)")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
}
