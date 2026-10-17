import Foundation

/// 端上直播黑匣子（v44 2026-10-03）。
///
/// 为什么必须有：主人要求「坏了缺了得能知道哪个不出图了」。此前端上**一个字都不写**，
/// 排障只能靠截图猜——而截图根本分不清「没出画」和「出画后卡死」，
/// 「一直切」到底是哪条线在什么时候被判死也看不见。
///
/// 现在每次关键状态迁移都落盘到 `Documents/livediag.txt`（PC 侧用 HouseArrest 直接拉走）：
///   · 进页 / 起播（台名 + 线号 + 完整 URL）
///   · AVPlayerItem 的**真错误码**（NSURLErrorDomain / AVFoundationErrorDomain）
///   · 首次出画的时刻与播放位置
///   · 卡顿多久 → 原地重连还是换线（以及换到哪条）
///   · 本机自体检的**实测耗时**（判断「这条网到底带不带得动 2.7Mbps 的流」的唯一硬证据）
public enum LiveDiag {
    private static let queue = DispatchQueue(label: "live.diag")
    private static let maxLines = 1200
    private static var mem: [String] = []
    private static var loaded = false

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        f.timeZone = TimeZone.current
        return f
    }()

    /// 落盘位置（App 沙盒 Documents 下，PC 侧 _livediag_pull.py 直接读它）。
    public static var fileURL: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return dir.appendingPathComponent("livediag.txt")
    }

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let t = try? String(contentsOf: fileURL, encoding: .utf8) {
            mem = t.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
    }

    /// 写一条（自带时间戳）。
    public static func write(_ s: String) {
        queue.async {
            loadIfNeeded()
            mem.append("[\(fmt.string(from: Date()))] \(s)")
            if mem.count > maxLines { mem.removeFirst(mem.count - maxLines) }
            try? (mem.joined(separator: "\n") + "\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// 源请求专用账本 —— **独立文件、只追加、不参与环形裁剪**。
    ///
    /// 为什么另开一份（2026-10-17 主人「看下日志源加载超级慢」）：主日志是 1200 行环形缓冲，
    /// 而海报「取图」每 5 秒就写一条，几分钟就把源请求记录整个刷没了 —— 拉回来的 600 行
    /// 里**一条源请求都没有**，慢在哪完全查不到。源请求量小（一次进页几条），单独落盘毫无压力。
    /// 上限 1MB：超了就清空重来（保最新，绝不让沙盒膨胀）。
    public static var siteFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("livediag_site.txt")
    }

    public static func writeSite(_ s: String) {
        queue.async {
            let url = siteFileURL
            let line = "[\(fmt.string(from: Date()))] \(s)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let sz = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, sz > 1_048_576 {
                try? data.write(to: url, options: .atomic)   // 超 1MB → 清空重开
                return
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 清空（设置页「重置直播诊断」用；也便于每次取证前先归零）。
    public static func reset() {
        queue.async {
            mem = []
            loaded = true
            try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
