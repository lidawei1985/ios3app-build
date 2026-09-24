import Foundation
import os

/// 统一日志：三产品共用 tag 前缀 = 产品名，便于隔离排查。
public enum FilmLog {
    public static var productTag: String = "Film"

    public static func d(_ msg: String) { log(msg, .debug) }
    public static func i(_ msg: String) { log(msg, .info) }
    public static func w(_ msg: String) { log(msg, .error) }   // 警告与错误同通道，避免吞

    private static func log(_ msg: String, _ level: OSLogType) {
        Logger(subsystem: "tv.filmcollector.\(productTag.lowercased())", category: "app")
            .log(level: level, "\(msg, privacy: .public)")
    }
}

/// App 全局错误类型（网络/数据/播放分层，UI 据此展示对应状态页）。
public enum FilmError: Error, LocalizedError {
    case network(String)
    case decode(String)
    case emptyCatalog
    case playback(String)
    case allBasesFailed([String])

    public var errorDescription: String? {
        switch self {
        case .network(let m): return "网络异常：\(m)"
        case .decode(let m): return "数据解析异常：\(m)"
        case .emptyCatalog: return "片库暂无内容"
        case .playback(let m): return "播放失败：\(m)"
        case .allBasesFailed(let e): return "全部数据通道不可用：\(e.joined(separator: " | "))"
        }
    }
}
