import Foundation

/// 本地标题拼音库：把「经手过的影片标题」攒成 `标题 ↔ 拼音键` 映射，用来给拼音搜索做反查。
///
/// 为什么必须有这个（2026-10-17 实测链条）：
///  主人：「换了索倪源……以前可以直接搜索到 LLZ 的影片，比如蜜桃成熟时，现在为什么又搜索不到了」。
///  逐条实测后确认是三件事叠在一起：
///
///  ① **采集源只匹配片名，不匹配演员** —— `wd=李丽珍` 在 360资源 / 天堂采集 / 猫眼 / 红牛3
///     全部 0 条；而 `wd=蜜桃成熟时` 在这 4 家分别回 2 / 3 / 2 / 4 条。⇒ 拿演员名去搜片名，白搭。
///  ② **采集源不认拼音** —— `wd=llz` / `wd=mtscs` 全 0 条。⇒ 纯拼音丢给源必然空。
///  ③ 所以「打 LLZ 能看到蜜桃成熟时」这件事，过去只能靠**本地**有这份标题的拼音索引；
///     一旦本地片库轮换掉那部片（或它本来就不进 feed），拼音搜索就彻底断链。
///
/// 本库把断掉的那一环补回来：任何源（索倪/360/红牛3/天堂……）只要在 App 里被浏览过、
/// 翻过页、或被搜索命中过，标题就落进本库。之后打 `llz` / `mtscs` / `mitao`，
/// 都能反查出「蜜桃成熟时」这个中文标题，再拿中文标题去全源搜 —— 结果与直接搜中文一致。
///
/// 容量与代价：上限 3 万条（约 1.5MB JSON），超限按 FIFO 淘汰；写盘每积攒 80 条批量落一次，
/// 不做「每条都全量编码」那种 O(n²) 傻事。
public enum TitlePinyinCache {

    private static let defaultsKey = "TitlePinyinCache.v1"
    private static let cap = 30_000
    private static let flushEvery = 80

    private struct Entry: Codable { let t: String; let k: String }

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var entries: [Entry] = []
        var known = Set<String>()
        var loaded = false
        var dirty = 0
    }

    private static let store = Store()

    private static func ensureLoadedLocked() {
        guard !store.loaded else { return }
        store.loaded = true
        if let d = UserDefaults.standard.data(forKey: defaultsKey),
           let e = try? JSONDecoder().decode([Entry].self, from: d) {
            store.entries = e
            store.known = Set(e.map(\.t))
        }
    }

    private static func persistLocked() {
        guard let d = try? JSONEncoder().encode(store.entries) else { return }
        UserDefaults.standard.set(d, forKey: defaultsKey)
        store.dirty = 0
    }

    private static func pinyinKey(_ t: String) -> String {
        let k = PinyinIndex.key(for: t)
        return PinyinIndex.normalize(k.initials) + "|" + PinyinIndex.normalize(k.full)
    }

    /// 记一个标题（去重；满额 FIFO 淘汰；写盘按批）。
    public static func record(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, PinyinIndex.hasHan(t) else { return }
        store.lock.lock()
        defer { store.lock.unlock() }
        ensureLoadedLocked()
        guard !store.known.contains(t) else { return }
        store.entries.append(Entry(t: t, k: pinyinKey(t)))
        store.known.insert(t)
        if store.entries.count > cap {
            let drop = store.entries.count - cap
            for e in store.entries.prefix(drop) { store.known.remove(e.t) }
            store.entries.removeFirst(drop)
        }
        store.dirty += 1
        if store.dirty >= flushEvery { persistLocked() }
    }

    /// 批量记录（翻页/搜索回来一屏时用，写一次盘）。
    public static func record(_ titles: [String]) {
        guard !titles.isEmpty else { return }
        store.lock.lock()
        defer { store.lock.unlock() }
        ensureLoadedLocked()
        var added = 0
        for raw in titles {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2, PinyinIndex.hasHan(t), !store.known.contains(t) else { continue }
            store.entries.append(Entry(t: t, k: pinyinKey(t)))
            store.known.insert(t)
            added += 1
            if store.entries.count > cap {
                let drop = store.entries.count - cap
                for e in store.entries.prefix(drop) { store.known.remove(e.t) }
                store.entries.removeFirst(drop)
            }
        }
        guard added > 0 else { return }
        persistLocked()
    }

    /// 按拼音反查中文标题：前缀命中的排前面，最多 `limit` 条。
    public static func lookup(pinyin raw: String, limit: Int = 3) -> [String] {
        let needle = PinyinIndex.normalize(raw)
        guard needle.count >= 2 else { return [] }
        store.lock.lock()
        ensureLoadedLocked()
        let snapshot = store.entries
        store.lock.unlock()
        guard !snapshot.isEmpty else { return [] }
        var prefix: [String] = []
        var other: [String] = []
        for e in snapshot {
            guard let bar = e.k.firstIndex(of: "|") else { continue }
            let ini = String(e.k[e.k.startIndex..<bar])
            let full = String(e.k[e.k.index(after: bar)...])
            if ini.hasPrefix(needle) || full.hasPrefix(needle) {
                prefix.append(e.t)
                if prefix.count >= limit { break }
            } else if other.count < limit * 4, ini.contains(needle) || full.contains(needle) {
                other.append(e.t)
            }
        }
        return Array((prefix + other).prefix(limit))
    }

    public static var count: Int {
        store.lock.lock(); defer { store.lock.unlock() }
        ensureLoadedLocked()
        return store.entries.count
    }

    /// 立刻落盘（切后台/退出前调一次）。
    public static func flush() {
        store.lock.lock(); defer { store.lock.unlock() }
        ensureLoadedLocked()
        persistLocked()
    }

    public static func clear() {
        store.lock.lock(); defer { store.lock.unlock() }
        store.entries = []
        store.known = []
        store.loaded = true
        store.dirty = 0
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
