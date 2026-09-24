import Foundation

/// 全局统一 JSON 编解码策略。
/// 关键：生产 feed 是蛇形键（dedup_id / is_adult / default_url…），Swift 模型是驼峰 ——
/// 解码必须 convertFromSnakeCase；本地持久化（收藏/历史/快照）往返必须用对称的
/// convertToSnakeCase + iso8601，否则写出去的文件下次读不回来。
public enum FilmJSON {

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
