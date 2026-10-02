// Cloudflare Worker：收 UDID → 存起来 → 触发 GitHub 自动签名 → 跳回安装页
//
// 为什么需要它：个人开发者号（¥688）签的包只认"登记过的设备"，登记就要 UDID。
// GitHub Pages 是纯静态、接不了回调，所以这一步必须有个能收 HTTP 的地方。
// Cloudflare Worker 免费额度就够（每天 10 万次请求），全球都能访问。
//
// 部署（一次）：
//   npm i -g wrangler && wrangler login
//   wrangler kv:namespace create DEVICES        → 把拿到的 id 填进 wrangler.toml
//   wrangler secret put GITHUB_TOKEN           → 有 repo 权限的 PAT
//   wrangler deploy
//
// 环境变量（wrangler.toml 的 vars / secrets）：
//   GITHUB_TOKEN  触发 GitHub Actions 用的 PAT（repo 权限）
//   ALLOWED_SLOTS 允许注册的设备总数上限，默认 100（个人号一年就 100 台）

export default {
  async fetch(req, env) {
    const url = new URL(req.url);

    // 1) iOS 装完描述文件后，会把 UDID POST 到这里（body 是 plist 文本）
    if (url.pathname === "/udid" && req.method === "POST") {
      const body = await req.text();
      const m = body.match(/<key>UDID<\/key>\s*<string>([^<]+)<\/string>/);
      const udid = m && m[1].trim();
      if (!udid || !/^[0-9a-fA-F-]{25,60}$/.test(udid)) {
        return new Response("bad udid", { status: 400 });
      }

      const cap = Number(env.ALLOWED_SLOTS || 100);
      const list = JSON.parse((await env.DEVICES.get("list")) || "[]");
      if (!list.includes(udid)) {
        if (list.length >= cap) {
          // 名额满了：别静默失败，明确告诉用户，也方便我们自己加号
          return Response.redirect(
            "https://lidawei1985.github.io/ios3app-build/udid.html?err=full", 302);
        }
        list.push(udid);
        await env.DEVICES.put("list", JSON.stringify(list));
      }

      // 2) 通知 GitHub：有新设备 → 自动跑「注册设备 + 签名 + 上传」
      await fetch(
        "https://api.github.com/repos/lidawei1985/ios3app-build/dispatches", {
        method: "POST",
        headers: {
          "Authorization": "Bearer " + env.GITHUB_TOKEN,
          "Accept": "application/vnd.github+json",
          "User-Agent": "udid-worker",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ event_type: "device-added", client_payload: { udid } }),
      });

      // 3) 跳回安装页，用户接着点安装
      return Response.redirect(
        "https://lidawei1985.github.io/ios3app-build/udid.html?udid=" + udid, 302);
    }

    // 给安装页查询状态用：这台设备登记上没
    if (url.pathname === "/status") {
      const udid = url.searchParams.get("udid") || "";
      const list = JSON.parse((await env.DEVICES.get("list")) || "[]");
      return new Response(JSON.stringify({ ok: list.includes(udid) }), {
        headers: { "Content-Type": "application/json",
                   "Access-Control-Allow-Origin": "*" },
      });
    }

    return new Response("ok");
  },
};
