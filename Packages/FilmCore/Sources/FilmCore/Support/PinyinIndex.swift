import Foundation

/// 拼音索引：中文文本 → 全拼 / 全拼-ü变体 / 拼音首字母。
///
/// 用途（2026-09-22 用户反馈「搜索首字母用不了很别扭」）：
/// 大牌影视 App 都支持输入拼音首字母搜片（如 `lldq` / `liulangdiqiu` 都能搜到《流浪地球》）。
/// 本索引把文本转成 Latin 拼音（系统 CFStringTransform，无需词库），
/// 分词后取每字首字母，得到与用户输入同构的串，供 `FeedAdapter.searchHits` 做前缀/包含匹配。
///
/// **口径说明（2026-09-22 用户钦定）**：以「大牌（爱奇艺/腾讯视频/优酷/B站）」的搜索体验为标杆，
/// **不照搬 TV 版（TVBox 系）做法**——TV 版依赖中台预生成的 `pinyin_abbr` 字段（只覆盖片名、
/// 且被截断），大牌做法是本地对「片名 + 演员 + 导演」建索、支持任意位置子串与 ü 的 v/lu 双通道。
/// 故此处保留本地转换，**不改为读中台字段**。
///
/// 性能：结果按文本缓存（片名与演员名都是有限集合），首次全量转换后转入内存命中；
/// 调用方应放在后台线程（SearchView 已在 `Task.detached` 中调用）。
public enum PinyinIndex {

    public struct Key: Sendable {
        /// 全拼（去空格，小写）：流浪地球 → liulangdiqiu
        public let full: String
        /// 全拼的 ü→v 变体：吕 → lu(同 full) / lv(本字段)。
        /// 大牌允许「lv」「lu」两种输入搜到「吕」，此字段补齐 v 通道。
        public let fullV: String
        /// 首字母（每字首字母拼接）：流浪地球 → lldq
        public let initials: String
    }

    /// 命中档位（rawValue 越小越靠前）。用于把「最像用户想要的那条」顶到前面。
    public enum Tier: Int, Comparable {
        case iniPrefix = 0        // 片名首字母前缀（lldq → 流浪地球）
        case fullPrefix = 1       // 片名全拼前缀（liulang → 流浪地球）
        case person = 2           // 演员 / 导演命中（大牌：搜 llz 出李丽珍参演的片）
        case iniContains = 3      // 片名首字母包含
        case fullContains = 4     // 片名全拼包含
        case fuzzy = 5            // 跳字容错（漏字/片名带「的」等连接字仍可命中）
        case none = 99

        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    /// 线程安全缓存（NSLock 保护；标 @unchecked Sendable 以适配并发调用）。
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: Key] = [:]

        func key(for text: String) -> Key {
            lock.lock()
            if let hit = cache[text] { lock.unlock(); return hit }
            lock.unlock()

            let k = Self.compute(text)

            lock.lock()
            // 片库标题 + 演员名数量级有限；上限兜底防异常数据把内存撑爆
            if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
            cache[text] = k
            lock.unlock()
            return k
        }

        private static func compute(_ text: String) -> Key {
            let raw = latinizeWithTones(text)                       // 例：吕 → "lǚ"
            let plain = stripDiacritics(raw).replacingOccurrences(of: " ", with: "")
            let vForm = stripDiacritics(vMapped(raw)).replacingOccurrences(of: " ", with: "")
            let initials = stripDiacritics(raw)
                .split(separator: " ")
                .compactMap { $0.first }
                .map(String.init)
                .joined()
            return Key(full: plain, fullV: vForm, initials: initials)
        }

        /// 中文 → 带声调拉丁，转小写。非中文字符原样保留（数字/英文同样可用）。
        private static func latinizeWithTones(_ s: String) -> String {
            let m = NSMutableString(string: s) as CFMutableString
            CFStringTransform(m, nil, kCFStringTransformToLatin, false)
            return (m as String).lowercased()
        }

        private static func stripDiacritics(_ s: String) -> String {
            let m = NSMutableString(string: s) as CFMutableString
            CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
            return (m as String)
        }

        /// 把带分音符（ü/ǖ/ǘ/ǚ/ǜ）的音节映射为 v：lǚ → lv。
        /// 判据用 Unicode 规范分解里是否含组合分音符 U+0308，
        /// 这样声调符号（如 ǚ 同时带 caron 与 diaeresis）也能被识别。
        private static func vMapped(_ s: String) -> String {
            var out = ""
            for ch in s {
                let decomposed = String(ch).decomposedStringWithCanonicalMapping
                if decomposed.unicodeScalars.contains(where: { $0.value == 0x0308 }) {
                    out.append("v")
                } else {
                    out.append(ch)
                }
            }
            return out
        }
    }

    private static let store = Store()

    /// 取文本的拼音键（带缓存）。
    public static func key(for text: String) -> Key { store.key(for: text) }

    /// 查询串是否可作为拼音查询（纯 ASCII 字母/数字，可含空格）。
    /// 中文查询不触发拼音通道，保证常规搜索零额外开销。
    public static func isPinyinQuery(_ q: String) -> Bool {
        guard !q.isEmpty else { return false }
        return q.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " ") }
    }

    /// 归一化查询串：去空格 + 小写（用户可能敲 "liu lang" / "LiuLang"）。
    public static func normalize(_ q: String) -> String {
        q.replacingOccurrences(of: " ", with: "").lowercased()
    }

    /// 片名档位：按 首字母前缀 > 全拼前缀 > 首字母包含 > 全拼包含 > 跳字容错 定档。
    public static func titleTier(_ key: Key, needle: String) -> Tier {
        guard !needle.isEmpty, !key.initials.isEmpty else { return .none }
        if key.initials.hasPrefix(needle) { return .iniPrefix }
        if key.full.hasPrefix(needle) || key.fullV.hasPrefix(needle) { return .fullPrefix }
        if key.initials.contains(needle) { return .iniContains }
        if key.full.contains(needle) || key.fullV.contains(needle) { return .fullContains }
        // 跳字容错（2026-09-24 用户实测：搜「杀人者购物中心」搜不到《杀人者的购物中心》
        // ——片名里一个「的」字打断连续匹配，一般用户直接认为没有这片）：
        // 用户输入按序出现在拼音串里（可跳字）即命中，放最低档。
        if needle.count >= 3, isSubsequence(needle, in: key.initials) || isSubsequence(needle, in: key.full) {
            return .fuzzy
        }
        return .none
    }

    /// 子序列判定：`sub` 的字符按顺序出现在 `text` 中（可跳字不可乱序）。
    /// 用于搜索容错——片名多一个「的/之/了」或用户漏字时仍能命中。
    public static func isSubsequence(_ sub: String, in text: String) -> Bool {
        guard !sub.isEmpty else { return false }
        var it = text.makeIterator()
        func advance() -> Character? { it.next() }
        var cursor = advance()
        if cursor == nil { return false }
        for ch in sub {
            while let c = cursor, c != ch { cursor = advance() }
            if cursor == nil { return false }
            cursor = advance()
        }
        return true
    }

    /// 人名（演员/导演）档位：前缀与包含同档（大牌里人名命中统一排在片名命中之后）。
    public static func personTier(_ name: String, needle: String) -> Tier {
        guard !needle.isEmpty else { return .none }
        let k = key(for: name)
        guard !k.initials.isEmpty else { return .none }
        if k.initials.hasPrefix(needle) || k.full.hasPrefix(needle) || k.fullV.hasPrefix(needle) { return .person }
        if k.initials.contains(needle) || k.full.contains(needle) || k.fullV.contains(needle) { return .person }
        return .none
    }
}
