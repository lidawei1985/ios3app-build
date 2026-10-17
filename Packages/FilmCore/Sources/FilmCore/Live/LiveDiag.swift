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
    private static let maxLines = 600
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

    /// 清空（设置页「重置直播诊断」用；也便于每次取证前先归零）。
    public static func reset() {
        queue.async {
            mem = []
            loaded = true
            try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
