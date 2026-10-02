import SwiftUI
import ImageIO      // 10-01：CGImageSource 降采样（ImageIO 不由 SwiftUI/UIKit 透传，必须显式导入）

/// 海报图片加载器：内存缓存（NSCache）→ 磁盘缓存 → 网络下载（一次重试）→ 占位图。
/// 铁律（§十）：失败 = 占位图，绝不因图片失败让内容消失。
public final class PosterLoader {

    public static let shared = PosterLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let diskDir: URL
    private let session: URLSession
    private let inflight = NSLock()
    private var inflightTasks: [String: Task<UIImage?, Never>] = [:]
    /// 35包：主视觉 15 张打进 APK（hbn_manifest.json：海报URL→包内文件名），打开就有，不依靠网络
    private let bundled: [String: String] = PosterLoader.loadBundledManifest()

    init() {
        // 10-01 卡顿根修：原来只限「张数 600」——600 张**原尺寸**海报（常见 800×1200，解码后
        // 每张约 3.8MB）常驻内存 ≈ 2GB，内存压力下系统反复回收/重解码，滑动与点击都被拖住。
        // 改成「张数 + 总字节」双重上限，并按**显示所需尺寸**降采样入库（见 `thumb`）。
        memory.countLimit = 400
        memory.totalCostLimit = 96 << 20          // 96MB：够铺满十几屏，超了自动淘汰最久未用
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("posters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        diskDir = dir
        let cfg = URLSessionConfiguration.default
        // 34包提速：超时 15→8s（慢图快速失败落占位，不堵整面墙）；每 host 并发 6→12（60 张墙排队减半）
        cfg.timeoutIntervalForRequest = 8
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20, directory: dir)
        session = URLSession(configuration: cfg)
        primeBundledToDisk()
    }

    /// 35包双通道资源查找：XcodeGen 对 `sources: - Apps/Xingmu` 目录的资源落地位置
    /// 有两种可能（bundle 根 或 保留 HeroBundled 子目录），此处**两条都试**，
    /// 不赌 CI 的目录布局（实测哪个命中都行）。
    static func bundledResourcePath(name: String, ext: String) -> String? {
        if let p = Bundle.main.path(forResource: name, ofType: ext) { return p }
        if let p = Bundle.main.path(forResource: name, ofType: ext, inDirectory: "HeroBundled") { return p }
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "HeroBundled"),
           FileManager.default.fileExists(atPath: u.path) { return u.path }
        return nil
    }

    private static func loadBundledManifest() -> [String: String] {
        var data: Data?
        if let u = Bundle.main.url(forResource: "hbn_manifest", withExtension: "json"),
           let d = try? Data(contentsOf: u) {
            data = d
        } else if let p = bundledResourcePath(name: "hbn_manifest", ext: "json"),
                  let d = try? Data(contentsOf: URL(fileURLWithPath: p)) {
            data = d
        }
        guard let d = data, let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }

    private func bundledImage(_ key: String) -> UIImage? {
        guard let fn = bundled[key] else { return nil }
        let name = (fn as NSString).deletingPathExtension
        let ext = (fn as NSString).pathExtension
        guard let p = PosterLoader.bundledResourcePath(name: name, ext: ext) else { return nil }
        return UIImage(contentsOfFile: p)
    }

    /// 落磁盘缓存（35包原则：包内 hero 直接写进磁盘缓存，网络只做后台静默更新）
    private func primeBundledToDisk() {
        let map = bundled
        guard !map.isEmpty else { return }
        let dir = diskDir
        Task.detached(priority: .background) {
            for (url, fn) in map {
                let name = (fn as NSString).deletingPathExtension
                let ext = (fn as NSString).pathExtension
                guard let src = PosterLoader.bundledResourcePath(name: name, ext: ext) else { continue }
                let dst = dir.appendingPathComponent(PosterLoader.stableDigest(url))
                if !FileManager.default.fileExists(atPath: dst.path) {
                    try? FileManager.default.copyItem(atPath: src, toPath: dst.path)
                }
            }
        }
    }

    /// 跨启动稳定的摘要（35包根修：Swift hashValue 每次启动随机化 → 旧磁盘缓存键全废，
    /// 每次冷启动全部重新下载 = 「海报每次打开都慢」的隐藏根因；改 FNV-1a 持久键）
    static func stableDigest(_ s: String) -> String {
        var h: UInt64 = 14695981039346656037
        for b in s.utf8 { h ^= UInt64(b); h = h &* 1099511628211 }
        return String(h, radix: 16)
    }

    public func image(for urlString: String?, thumbPriority: Bool = false) async -> UIImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        // 34包：缓存 key 统一为 URL 本体（原 thumbPriority 加 "t:" 前缀导致同图双份缓存/重复下载）
        let key = urlString
        if let hit = memory.object(forKey: key as NSString) { return hit }
        // 35包：包内 hero 清单命中即秒出（先于磁盘/网络）
        if let b = bundledImage(key) {
            remember(b, key)
            return b
        }
        if let disk = loadDisk(key) {
            remember(disk, key)
            return disk
        }
        // 去重并发请求
        inflight.lock()
        if let existing = inflightTasks[key] { inflight.unlock(); return await existing.value }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            defer {
                self.inflight.lock(); self.inflightTasks[key] = nil; self.inflight.unlock()
            }
            var img = await self.download(urlString)
            // 重试退避（2026-09-21 增强：弱网/拥塞场景 1→3 轮；被墙 IP 重试仍失败则落占位）
            for backoff in [400_000_000.0, 2_000_000_000.0] where img == nil {
                try? await Task.sleep(nanoseconds: UInt64(backoff))
                img = await self.download(urlString)
            }
            if let img {
                self.remember(img, key)
                self.saveDisk(key, img)
            }
            return img
        }
        inflightTasks[key] = task
        inflight.unlock()
        return await task.value
    }

    private func download(_ urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }
        for _ in 0..<2 {
            if let (data, resp) = try? await session.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let img = PosterLoader.thumb(from: data) {
                return img
            }
        }
        return nil
    }

    /// 入库（带字节成本，交给 NSCache 按内存量淘汰）。
    private func remember(_ img: UIImage, _ key: String) {
        let cost = Int(img.size.width * img.size.height * 4)
        memory.setObject(img, forKey: key as NSString, cost: max(1, cost))
    }

    /// 降采样成显示所需尺寸（10-01 卡顿根修）。
    ///
    /// 原实现直接 `UIImage(data:)`：拿到的**原图**往往是 800~1200px 宽，而海报格实际只画
    /// 120×180pt（2x 也才 240×360）。多出来的像素有两个坏处：
    ///  ① 内存成倍膨胀（见 `init` 的 `totalCostLimit` 注释）；
    ///  ② `UIImage` 是**懒解码**——真正解码发生在 SwiftUI 渲染它的那一刻，也就是**主线程**，
    ///     一张大图解几十毫秒，海报墙一屏几十张就是几百毫秒的卡顿（用户报「海报点完半天才出现」）。
    /// 这里用 ImageIO 直接出缩略图并 `ShouldCacheImmediately`，解码在**后台线程**一次做完，
    /// 落到 SwiftUI 手里时已是「可直接画的小图」。
    static func thumb(from data: Data, maxSide: CGFloat = 600) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }

    /// 首屏预热（34包）：catalog 就绪后后台把主视觉/首屏货架海报先拉进缓存，
    /// 用户滑到时直接命中内存/磁盘，不再「转圈等图」。后台低优先级、串行慢拉，不抢前台带宽。
    public func prefetch(_ urlStrings: [String], limit: Int = 24) {
        let urls = Array(urlStrings.prefix(limit))
        guard !urls.isEmpty else { return }
        Task.detached(priority: .background) { [weak self] in
            for u in urls {
                guard let self else { return }
                _ = await self.image(for: u)
            }
        }
    }

    private func diskURL(_ key: String) -> URL {
        // 35包：跨启动稳定键（原 hashValue 随机化导致磁盘缓存跨启动全废）
        return diskDir.appendingPathComponent(PosterLoader.stableDigest(key))
    }
    private func loadDisk(_ key: String) -> UIImage? {
        // 同 `thumb`：磁盘里的图也是原尺寸，这里一并降采样 + 后台解码，
        // 不让「解大图」这件事留到主线程渲染时才发生。
        guard let data = try? Data(contentsOf: diskURL(key)) else { return nil }
        return PosterLoader.thumb(from: data)
    }
    private func saveDisk(_ key: String, _ img: UIImage) {
        guard let data = img.jpegData(compressionQuality: 0.82) else { return }
        try? data.write(to: diskURL(key), options: .atomic)
    }
}

/// 海报视图：加载中占位（轻微呼吸动画）→ 成图渐显；失败显示占位图标与片名首字，不空白。
public struct PosterImage: View {
    let urlString: String?
    var cornerRadius: CGFloat = 8
    var contentMode: SwiftUI.ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    public init(urlString: String?, cornerRadius: CGFloat = 8, contentMode: SwiftUI.ContentMode = .fill) {
        self.urlString = urlString
        self.cornerRadius = cornerRadius
        self.contentMode = contentMode
    }

    public var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .clipped()
        .cornerRadius(cornerRadius)
        .task(id: urlString) {
            failed = false
            image = await PosterLoader.shared.image(for: urlString, thumbPriority: true)
            if image == nil { failed = true }
        }
    }

    private var placeholder: some View {
        Rectangle()
            // 2026-09-23 用户：「货架背景颜色能不能透明化」——旧值 #1C2230 是实色，
            //  会挡住整页取色背景、在货架上糊出一块块深色砖。改半透明玻璃，透出海报取色底。
            .fill(Color.white.opacity(0.07))
            .overlay(
                Group {
                    if failed {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.28))
                    } else {
                        ProgressView().tint(.white.opacity(0.3))
                    }
                }
            )
    }
}
