import Foundation
import FilmCore

/// 年份清洗：源站脏数据（如 2030「穿越」年份）不外显、不参与筛选与排序。
/// 铁律：只影响展示与筛选，不删除底层数据。
public extension FeedItem {
    /// 校验通过的展示年份（1900~当前年）；越界年份返回 nil，非纯数字原样保留。
    var displayYear: String? {
        guard let y = year, !y.isEmpty else { return nil }
        guard let n = Int(y) else { return y }
        let current = Calendar.current.component(.year, from: Date())
        return (1900...current).contains(n) ? y : nil
    }
}
