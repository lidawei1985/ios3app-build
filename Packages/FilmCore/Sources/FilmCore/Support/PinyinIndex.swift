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
    /// ★ 2026-10-11 v84 重排（用户实测反馈：搜 llz 出来的全是「拦路贼/恋老症/连理枝/流浪者」
    ///   这类片名首字母碰巧匹配的杂片，李丽珍参演的片一条看不见）：
    ///   旧表把人名命中统一压在片名前缀命中之后 —— 库 2 万条时人名还能挤进前排，
    ///   7.4 万条后片名首字母命中暴涨、人名全被压出首屏。对齐大牌口径：
    ///   **人名「前缀」命中置顶**（搜 llz 第一眼就是李丽珍参演的片，带「演员 李丽珍」标）；
    ///   人名「包含」命中仍在片名前缀档之后。
    public enum Tier: Int, Comparable {
        case personPrefix = 0    // 人名首字母/全拼前缀命中（llz → 李丽珍）——置顶
        case iniPrefix = 1       // 片名首字母前缀（lldq → 流浪地球）
        case fullPrefix = 2      // 片名全拼前缀（liulang → 流浪地球）
        case person = 3          // 演员 / 导演包含命中
        case iniContains = 4     // 片名首字母包含
        case fullContains = 5    // 片名全拼包含
        case fuzzy = 6           // 跳字容错（漏字/片名带「的」等连接字仍可命中）
        case none = 99

        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    /// 线程安全缓存（NSLock 保护；标 @unchecked Sendable 以适配并发调用）。
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: Key] = [:]
        /// v83：自上次落盘后新现算的键数（读盘填充的不算）——决定冷启动要不要重写盘文件。
        private var addedSincePersist = 0

        func key(for text: String) -> Key {
            lock.lock()
            if let hit = cache[text] { lock.unlock(); return hit }
            lock.unlock()

            let k = Self.compute(text)

            lock.lock()
            if cache[text] == nil { addedSincePersist += 1 }
            // 上限兜底防异常数据把内存撑爆。
            // ★ 2026-10-11 v83：工作集实测 60 万+ 唯一文本（7.4 万片名 + 几十万演员/导演名），
            //   旧上限 25 万 < 工作集 → 写满就 removeAll 全清 → 每次搜索大量现算（转圈 30~40s 实锤）。
            //   阈值必须高于「读盘填充后的常驻量」，否则新键一插就触发全清。
            if cache.count > 900_000 { cache = Dictionary(cache.prefix(600_000).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a }) }
            cache[text] = k
            lock.unlock()
            return k
        }

        /// v82 预热专用：批量写入（一次加锁；不覆盖已有键——与并发搜索的现算结果兼容）。
        /// ★ 2026-10-11 v83 致命 bug 修复：旧写法写入后 `count > 25万` 触发 removeAll——
        ///   预热一次性写入 60 万键，**写完立刻把自己全清了**（106 秒预热归零，真机 livediag 实锤）。
        ///   上限已提至 60 万（≥工作集），并改成只清"超出部分"不再整表清空。
        func insertBatch(_ pairs: [(String, Key)]) {
            guard !pairs.isEmpty else { return }
            lock.lock()
            var added = 0
            for (t, k) in pairs where cache[t] == nil { cache[t] = k; added += 1 }
            addedSincePersist += added
            if cache.count > 900_000 { // 物理兜底：只会在数据规模异常膨胀时触发
                cache = Dictionary(cache.prefix(600_000).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
            }
            lock.unlock()
        }

        fileprivate static func compute(_ text: String) -> Key {
            let raw = latinizeWithTones(text)                       // 例：吕 → "lǚ"
            let plain = stripDiacritics(raw).replacingOccurrences(of: " ", with: "")
            let vForm = stripDiacritics(vMapped(raw)).replacingOccurrences(of: " ", with: "")
            let initials = stripDiacritics(raw)
                .split(separator: " ")
                .compactMap { $0.first }
                .map(String.init)
                .joined()
            // v83 内存优化：99.9% 文本无 ü，vForm == plain 时直接复用同一 String
            //（Swift String 赋值是 COW 引用共享，不产生第二份存储）→ 全量键省 ~1/3 内存。
            let v = (vForm == plain) ? plain : vForm
            return Key(full: plain, fullV: v, initials: initials)
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

        /// 把中文 → 带分音符（ü/ǖ/ǘ/ǚ/ǜ）的音节映射为 v：lǚ → lv。
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

        // MARK: 持久化（v83）

        /// v83：返回 texts 中尚未进缓存的部分（差集），供 warmUp 只补缺、不重算。
        func filterMissing(_ texts: [String]) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            guard !cache.isEmpty else { return texts }
            return texts.filter { cache[$0] == nil }
        }

        /// 把当前缓存全量写盘。格式：magic "PYI1" + Int32 ver + Int32 count + N×(4 长度前缀 UTF-8 串)。
        func persist(to path: String) -> Int {
            lock.lock()
            let entries = Array(cache)
            lock.unlock()
            guard !entries.isEmpty else { return 0 }

            var buf = Data()
            buf.reserveCapacity(entries.count * 120 + 16)
            func putInt(_ v: Int32) {
                withUnsafeBytes(of: v.littleEndian) { buf.append(contentsOf: $0) }
            }
            func putStr(_ s: String) {
                let d = Array(s.utf8)
                putInt(Int32(d.count))
                buf.append(contentsOf: d)
            }
            buf.append(Data("PYI1".utf8))
            putInt(1)
            putInt(Int32(entries.count))
            for (t, k) in entries {
                putStr(t); putStr(k.full); putStr(k.fullV); putStr(k.initials)
            }
            do {
                let tmp = path + ".tmp"
                try buf.write(to: URL(fileURLWithPath: tmp), options: .atomic)
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                try FileManager.default.moveItem(atPath: tmp, toPath: path)
                return entries.count
            } catch {
                try? FileManager.default.removeItem(atPath: path + ".tmp")
                return 0
            }
        }

        /// 仅当新增键数达到阈值才重写盘文件（日常冷启动白写 70MB 没意义）。
        func persistIfDirty(to path: String, minNewEntries: Int) -> Int {
            lock.lock()
            let dirty = addedSincePersist
            lock.unlock()
            guard dirty >= minNewEntries else { return 0 }
            let n = persist(to: path)
            if n > 0 {
                lock.lock()
                addedSincePersist = 0
                lock.unlock()
            }
            return n
        }

        /// 读盘填充缓存（合并语义，不覆盖已有键）。返回读入条数（0 = 无文件/损坏）。
        func loadPersisted(from path: String) -> Int {
            guard let data = FileManager.default.contents(atPath: path), data.count > 12,
                  data[0] == UInt8(ascii: "P"), data[1] == UInt8(ascii: "Y"),
                  data[2] == UInt8(ascii: "I"), data[3] == UInt8(ascii: "1") else { return 0 }
            var off = 0
            func rdInt() -> Int32? {
                guard off + 4 <= data.count else { return nil }
                let b0 = UInt32(data[off]), b1 = UInt32(data[off + 1])
                let b2 = UInt32(data[off + 2]), b3 = UInt32(data[off + 3])
                off += 4
                return Int32(bitPattern: b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
            }
            func rdStr() -> String? {
                guard let n = rdInt(), n >= 0, off + Int(n) <= data.count else { return nil }
                let s = String(data: data.subdata(in: off..<off + Int(n)), encoding: .utf8)
                off += Int(n)
                return s
            }
            off = 4
            guard rdInt() == 1, let cnt = rdInt(), cnt > 0, cnt < 5_000_000 else { return 0 }
            var pairs: [(String, Key)] = []
            pairs.reserveCapacity(Int(cnt))
            for _ in 0..<cnt {
                guard let t = rdStr(), let f = rdStr(), let v = rdStr(), let i = rdStr() else { break }
                pairs.append((t, Key(full: f, fullV: v, initials: i)))
            }
            guard !pairs.isEmpty else { return 0 }
            lock.lock()
            for (t, k) in pairs where cache[t] == nil { cache[t] = k }
            lock.unlock()
            return pairs.count
        }
    }

    private static let store = Store()

    /// 取文本的拼音键（带缓存）。
    public static func key(for text: String) -> Key { store.key(for: text) }

    /// v82 搜索转圈根修：冷启动并行预热。
    ///
    /// 此前首次拼音搜索（如 `llz`）要对「片名 + 演员 + 导演」几十万个字符串**串行**现算
    /// 拼音键（每个都要跑 CFStringTransform），真机实测整屏「搜索中…」转圈 50~80 秒；
    /// 且 App 每次冷启动缓存都从零开始，第一次搜索必付全额 —— 用户感知就是「搜索一直转圈」。
    /// 现改为：库就绪后（CatalogStore.boot 末尾）后台并行预建全部键，用户搜索时全部命中缓存。
    /// compute 是纯函数（无共享可变状态），可放心并行；并发度 = 活跃核数。
    public static func warmUp(items: [FeedItem]) {
        var texts = Set<String>(minimumCapacity: items.count * 8)
        for it in items {
            let t = it.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { texts.insert(t) }
            for a in (it.actors ?? []) where !a.isEmpty { texts.insert(a) }
            for d in (it.directors ?? []) where !d.isEmpty { texts.insert(d) }
        }
        warmUp(texts: Array(texts))
    }

    /// 并行批量预计算（去重后的文本集）。并行切片 + 一次加锁合并，避免逐条锁往返。
    ///
    /// 注意：`DispatchQueue.concurrentPerform` 的闭包签名是 `(Int) -> Void`，
    /// 不能直接 `return [(String, Key)]`（CI 实测编译错：declared closure result
    /// '[(String, Key)]' is incompatible with contextual type 'Void'）→ 用 Sendable 盒子收集。
    public static func warmUp(texts: [String]) {
        // v83：已缓存的（含读盘填充的）直接跳过——库换代后只补差集，冷启动不重复付 106s 全额。
        let targets = store.filterMissing(texts.filter { !$0.isEmpty })
        guard !targets.isEmpty else { return }
        let n = targets.count
        let chunks = max(1, min(n, ProcessInfo.processInfo.activeProcessorCount * 2))
        let per = (n + chunks - 1) / chunks
        let box = BatchBox()
        box.reserve(n)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lo = c * per, hi = min(n, lo + per)
            guard lo < hi else { return }
            var out: [(String, Key)] = []
            out.reserveCapacity(hi - lo)
            for i in lo..<hi { out.append((targets[i], Store.compute(targets[i]))) }
            box.add(out)
        }
        store.insertBatch(box.all())
    }

    /// 并行预热的收集盒（NSLock 保护；闭包跨线程写入需要 Sendable）。
    private final class BatchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buf: [(String, Key)] = []
        func reserve(_ n: Int) { lock.lock(); buf.reserveCapacity(n); lock.unlock() }
        func add(_ xs: [(String, Key)]) { lock.lock(); buf.append(contentsOf: xs); lock.unlock() }
        func all() -> [(String, Key)] { lock.lock(); defer { lock.unlock() }; return buf }
    }

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

    /// 人名（演员/导演）档位：**前缀命中置顶（v84）**，包含命中人名档。
    public static func personTier(_ name: String, needle: String) -> Tier {
        guard !needle.isEmpty else { return .none }
        let k = key(for: name)
        guard !k.initials.isEmpty else { return .none }
        if k.initials.hasPrefix(needle) || k.full.hasPrefix(needle) || k.fullV.hasPrefix(needle) { return .personPrefix }
        if k.initials.contains(needle) || k.full.contains(needle) || k.fullV.contains(needle) { return .person }
        return .none
    }

    // MARK: - 预热结果落盘持久化（v83）
    //
    // 冷启动每次重算 60 万键（真机实测 106 秒）不可接受 → 预热完成后整体写盘，
    // 下次冷启动直接读盘填充缓存（秒级就绪），首搜即命中、不再转圈。
    // 键是纯函数结果（同文本同键），与库版本无关，不随换代失效；
    // 库新增条目 → 新文本现算进缓存，下次冷启动全量重存覆盖。

    /// 把当前缓存全量写盘（先写 .tmp 再原子替换）。返回写入条数（0 = 失败）。
    @discardableResult
    public static func persist(to path: String) -> Int { store.persist(to: path) }

    /// 仅当「自上次落盘后新增键数 ≥ minNewEntries」时才重写盘文件（避免日常冷启动白写 70MB）。
    /// 返回写入条数（0 = 不需要写/失败）。
    @discardableResult
    public static func persistIfDirty(to path: String, minNewEntries: Int) -> Int {
        store.persistIfDirty(to: path, minNewEntries: minNewEntries)
    }

    /// 从盘上读入缓存（与已有缓存合并、不覆盖）。返回读入条数（0 = 无文件/损坏）。
    @discardableResult
    public static func loadPersisted(from path: String) -> Int { store.loadPersisted(from: path) }
}
