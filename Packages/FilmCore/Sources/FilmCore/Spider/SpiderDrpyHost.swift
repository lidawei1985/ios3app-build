import Foundation
import JavaScriptCore

// MARK: - Spider M3：drpy JS 源宿主（JavaScriptCore + 同步网络桥）
// 桥设计已在 Node 侧验证通过（ios_ctrl/drpy_m3/node_bridge_test.js，五端点全通）。
// 架构：drpy 引擎（drpy2.min.js）+ 解析器（htmlParser.js/cheerio）+ 源 js（rule 对象）双层 JS，
// Swift 侧只提供宿主桥：req 同步网络 / joinUrl / local KV / os stub。
// 模块变换（与 Node 版一致）：剥 ESM import → 顺序 eval；export 转 IIFE return。

/// drpy 源宿主（五端点：home/category/detail/play/search）
public enum SpiderDrpyHost {

    private static var cachedContext: JSContext?
    private static let lock = NSLock()

    /// 六件套 JS 资产（FilmCore bundle js/drpy/ 目录；muban.js 即 drpy 的 模板.js，改 ASCII 名）
    private static let assetKinds: [(name: String, kind: String)] = [
        ("cheerio.min.js", "cheerio"), ("crypto-js.js", "plain"), ("gbk.js", "gbk"),
        ("muban.js", "muban"), ("jsonpathplus.min.js", "plain"), ("htmlParser.js", "htmlParser"),
    ]

    private static func bundleAsset(_ name: String) -> String? {
        if let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "js/drpy"),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let url = Bundle.module.url(forResource: name, withExtension: nil),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return nil
    }

    // MARK: - 模块变换（与 Node 桥同款字符串替换）

    static func transform(_ js: String, kind: String) -> String {
        switch kind {
        case "engine":
            var t = js
            t = t.replacingOccurrences(of: "import cheerio from\"assets://js/lib/cheerio.min.js\";", with: "")
            t = t.replacingOccurrences(of: "import\"assets://js/lib/crypto-js.js\";", with: "")
            t = t.replacingOccurrences(of: "import 模板 from\"./模板.js\";", with: "")
            t = t.replacingOccurrences(of: "import{gbkTool}from\"./gbk.js\";", with: "")
            t = t.replacingOccurrences(
                of: "export default{init:init,home:home,homeVod:homeVod,category:category,detail:detail,play:play,search:search,DRPY:DRPY};",
                with: "var __drpy={init:init,home:home,homeVod:homeVod,category:category,detail:detail,play:play,search:search,DRPY:DRPY};")
            return t

        case "cheerio":
            // export{a as b,...} → IIFE return 对象；default 即 cheerio 工厂（load/jp 等为模块级导出）
            guard let openRange = js.range(of: "export{"),
                  let closeRange = js.range(of: "}"), openRange.lowerBound < closeRange.lowerBound
            else { return js }
            let before = String(js[js.startIndex..<openRange.lowerBound])
            let body = String(js[js.index(after: openRange.lowerBound)..<closeRange.lowerBound])
            let after = String(js[js.index(after: closeRange.lowerBound)...])
            let pairs = body.split(separator: ",").compactMap { p -> String? in
                let trimmed = p.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.components(separatedBy: " as ")
                guard parts.count == 2 else { return trimmed }
                return parts[1] + ": " + parts[0]
            }
            return "var cheerio=(function(){" + before + "return {" + pairs.joined(separator: ",") + "};" + after + "})();"

        case "htmlParser":
            var t = js
            t = t.replacingOccurrences(of: "import * as cheerio from 'cheerio';", with: "")
            t = t.replacingOccurrences(of: "import {urljoin} from \"../utils/utils.js\";", with: "")
            t = t.replacingOccurrences(of: "import '../libs_drpy/jsonpathplus.min.js'", with: "")
            t = t.replacingOccurrences(of: "export const jsonpath = {", with: "const jsonpath = {")
            t = t.replacingOccurrences(of: "export const jsoup = Jsoup;", with: "return { Jsoup: Jsoup };")
            return "var __htmlParser=(function(){" + t + "})();\nvar jsoup=new __htmlParser.Jsoup();"

        case "gbk":
            return js.replacingOccurrences(of: "export function gbkTool()", with: "function gbkTool()")

        case "muban":
            return js.replacingOccurrences(of: "export default {muban,getMubans}", with: "var 模板={muban,getMubans}")

        default:
            return js
        }
    }

    // MARK: - JS 环境构建

    /// 构建完整 JS 环境（引擎+解析器+桥），失败返回 nil。线程安全（一次构建全局复用）。
    static func makeContext() -> JSContext? {
        lock.lock()
        defer { lock.unlock() }
        if let c = cachedContext { return c }
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, exc in
            let msg = exc?.toString() ?? "unknown"
            DrpyLog.log("JSC exception: \(msg)")
        }

        // ---- 宿主桥 1：req 同步网络（JS 传 (url, objJSON)，Swift 同步执行返回 JSON）----
        let reqBridge: @convention(block) (String, String) -> String = { url, objJSON in
            SpiderDrpyHost.performRequest(url: url, optsJSON: objJSON)
        }
        ctx.setObject(reqBridge, forKeyedSubscript: "__reqNative" as NSString)
        ctx.evaluateScript("""
        function req(url, obj) {
            var s = __reqNative(String(url), obj ? JSON.stringify(obj) : '{}');
            try { return JSON.parse(s); } catch (e) { return { content: '', code: 0 }; }
        }
        """)

        // ---- 宿主桥 2：joinUrl（纯 JS，与 Node 桥同款；JSC 无 URL API）----
        ctx.evaluateScript("""
        function joinUrl(base, rel) {
            base = base || ''; rel = rel || '';
            if (/^https?:\\/\\//i.test(rel)) return rel;
            if (!rel) return base;
            if (rel.substring(0,2) === '//') return base.substring(0, base.indexOf('//')) + rel;
            if (!/^https?:\\/\\//i.test(base)) return rel;
            var m = base.match(/^(https?:\\/\\/[^\\/?#]+)([^?#]*)(\\?[^#]*)?(#.*)?$/);
            if (!m) return rel;
            var origin = m[1], path = m[2] || '/';
            if (rel.substring(0,1) === '/') return origin + rel;
            if (rel.substring(0,1) === '#') return base.split('#')[0] + rel;
            if (rel.substring(0,1) === '?') return origin + path + rel;
            var dir = path.substring(0, path.lastIndexOf('/') + 1) || '/';
            var segs = (dir + rel).split('/');
            var out = [];
            for (var i = 0; i < segs.length; i++) {
                if (segs[i] === '..') out.pop();
                else if (segs[i] === '.') { }
                else out.push(segs[i]);
            }
            return origin + out.join('/');
        }
        """)

        // ---- 宿主桥 3：os / local / timer stub ----
        ctx.evaluateScript("var os={open:function(){throw new Error('os.open unsupported')},read:function(){return 0},close:function(){}};")
        ctx.evaluateScript("var local={get:function(){return null},set:function(){},delete:function(){}};")
        ctx.evaluateScript("var setTimeout=function(){return 0},clearTimeout=function(){},setInterval=function(){return 0},clearInterval=function(){};")

        // ---- 模块加载（顺序敏感：解析器 → 绑定 → 引擎）----
        for item in assetKinds {
            guard let src = bundleAsset(item.name) else {
                DrpyLog.log("drpy asset missing: \(item.name)")
                return nil
            }
            ctx.evaluateScript(transform(src, kind: item.kind))
        }
        // pdfh/pdfa/pd 绑定（引擎 defaultParser 顶层求值需要它们先存在；实现 = htmlParser 的 jsoup）
        ctx.evaluateScript("""
        var pdfh=function(html,parse){return jsoup.pdfh(html,parse)};
        var pdfa=function(html,parse){return jsoup.pdfa(html,parse)};
        var pd=function(html,parse,base){return jsoup.pd(html,parse,base||'')};
        """)
        guard let engineSrc = bundleAsset("drpy2.min.js") else {
            DrpyLog.log("drpy asset missing: drpy2.min.js")
            return nil
        }
        ctx.evaluateScript(transform(engineSrc, kind: "engine"))
        cachedContext = ctx
        return ctx
    }

    // MARK: - 同步网络（JSC block 里信号量等待；URLSession 回调在并发队列，无死锁）

    private static let httpSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private static func performRequest(url: String, optsJSON: String) -> String {
        guard let u = URL(string: url) else { return "{\"content\":\"\",\"code\":0}" }
        var req = URLRequest(url: u)
        let opts = (try? FilmJSON.decoder().decode(DrpyReqOpts.self, from: Data(optsJSON.utf8))) ?? DrpyReqOpts()
        req.httpMethod = (opts.method ?? "GET").uppercased() == "POST" ? "POST" : "GET"
        var headers = opts.headers ?? [:]
        if headers["User-Agent"] == nil && headers["user-agent"] == nil {
            headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body = opts.body, req.httpMethod == "POST" {
            req.httpBody = Data(body.utf8)
            if headers["Content-Type"] == nil { req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        }
        let sem = DispatchSemaphore(value: 0)
        var payload: Data?
        var code = 0
        httpSession.dataTask(with: req) { data, resp, _ in
            payload = data
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)
        let content = String(data: payload ?? Data(), encoding: .utf8)
            ?? String(data: payload ?? Data(), encoding: .isoLatin1) ?? ""
        // 手工拼 JSON（避免 Any Encodable）；做标准 JSON 字符串转义
        var esc = content
        esc = esc.replacingOccurrences(of: "\\", with: "\\\\")
        esc = esc.replacingOccurrences(of: "\"", with: "\\\"")
        esc = esc.replacingOccurrences(of: "\n", with: "\\n")
        esc = esc.replacingOccurrences(of: "\r", with: "\\r")
        esc = esc.replacingOccurrences(of: "\t", with: "\\t")
        return "{\"content\":\"" + esc + "\",\"code\":" + String(code) + "}"
    }

    private struct DrpyReqOpts: Codable {
        var method: String?
        var headers: [String: String]?
        var body: String?
    }

    // MARK: - 五端点公开 API

    /// 加载源（sourceJS = drpy 源文件全文），初始化 rule。
    public static func load(sourceJS: String) throws {
        guard let ctx = makeContext() else { throw DrpyError.engineUnavailable }
        guard let drpy = ctx.objectForKeyedSubscript("__drpy"), !drpy.isUndefined,
              let initFn = drpy.objectForKeyedSubscript("init"), initFn.isObject else {
            throw DrpyError.engineUnavailable
        }
        initFn.call(withArguments: [sourceJS])
        if let exc = ctx.exception {
            let msg = exc.toString() ?? "?"
            ctx.exception = nil
            throw DrpyError.sourceInitFailed(msg)
        }
    }

    public static func home() -> String { call("home") ?? "{}" }
    public static func homeVod() -> String { call("homeVod") ?? "{}" }
    public static func category(tid: String, page: Int) -> String { call("category", [tid, page]) ?? "{}" }
    public static func detail(_ id: String) -> String { call("detail", [id]) ?? "{}" }
    public static func play(flag: String, id: String) -> String { call("play", [flag, id]) ?? "{}" }
    public static func search(_ keyword: String) -> String { call("search", [keyword, false]) ?? "{}" }

    private static func call(_ name: String, _ args: [Any] = []) -> String? {
        guard let ctx = makeContext(),
              let drpy = ctx.objectForKeyedSubscript("__drpy"),
              let fn = drpy.objectForKeyedSubscript(name), fn.isObject else { return nil }
        let r = fn.call(withArguments: args)
        if let exc = ctx.exception {
            DrpyLog.log("drpy \(name) error: \(exc.toString() ?? "?")")
            ctx.exception = nil
            return nil
        }
        return r?.toString()
    }

    public enum DrpyError: LocalizedError {
        case engineUnavailable
        case sourceInitFailed(String)
        public var errorDescription: String? {
            switch self {
            case .engineUnavailable: return "drpy 引擎初始化失败（缺资产或 JSC 异常）"
            case .sourceInitFailed(let m): return "drpy 源初始化失败：\(m)"
            }
        }
    }
}

/// 轻量日志（独立通道，避免与 filmLog 循环依赖）
enum DrpyLog {
    static var sink: ((String) -> Void)?
    static func log(_ msg: String) {
        sink?(msg)
    }
}
