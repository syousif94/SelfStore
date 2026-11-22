import Foundation

/// The page Safari shows at the server root: every hosted app with its icon, version and an Install button.
enum WebPage {
    static func render(apps: [CatalogApp], info: ServerInfo, base: String) -> String {
        let date = DateFormatter()
        date.dateStyle = .medium
        date.timeStyle = .short

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        func installButton(_ v: CatalogVersion, primary: Bool) -> String {
            guard let url = v.installURL else { return "<span class=\"muted small\">Needs Tailscale</span>" }
            return "<a class=\"btn\(primary ? "" : " small-btn")\" href=\"\(esc(url))\">\(primary ? "Install" : "Get")</a>"
        }
        func icon(_ path: String?) -> String {
            guard let path else { return "<div class=\"icon placeholder\"></div>" }
            return "<img class=\"icon\" src=\"\(esc(base + path))\" alt=\"\">"
        }

        let rows = apps.map { app -> String in
            guard let v = app.latest else { return "" }
            var meta = ["Version \(esc(v.displayVersion))", size(v.size), date.string(from: v.uploadedAt)]
            if let exp = v.expiresAt { meta.append(exp < Date() ? "<b class=\"warn\">profile expired</b>" : "expires \(DateFormatter.localizedString(from: exp, dateStyle: .medium, timeStyle: .none))") }
            let notes = v.notes.map { "<p class=\"notes\">\(esc($0))</p>" } ?? ""
            let older = app.versions.dropFirst().map { o in
                """
                <li><span><b>\(esc(o.displayVersion))</b> <span class="muted">· \(date.string(from: o.uploadedAt))</span>\(o.notes.map { "<br><span class=\"muted small\">\(esc($0))</span>" } ?? "")</span>\(installButton(o, primary: false))</li>
                """
            }.joined()
            let history = older.isEmpty ? "" : "<details><summary>\(app.versions.count - 1) older version\(app.versions.count == 2 ? "" : "s")</summary><ul>\(older)</ul></details>"
            return """
            <section class="card">
              <div class="row">\(icon(app.iconPath ?? v.iconPath))
                <div class="grow"><div class="name">\(esc(app.name))</div><div class="muted small">\(meta.joined(separator: " · "))</div></div>
                \(installButton(v, primary: true))
              </div>\(notes)\(history)
            </section>
            """
        }.joined(separator: "\n")

        let addLink = "\(SelfStoreConstants.urlScheme)://add?url=\(base.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base)"
        let banner = info.installsAvailable ? "" : """
            <div class="card warn-card">Installs need Tailscale HTTPS. Turn on “Share over Tailscale” in SelfStore on \(esc(info.name)).</div>
            """
        // "Get the app" banner for the SelfStore iPhone app itself.
        let getBanner: String = {
            guard let me = apps.first(where: { $0.bundleId == ServerController.iOSBundleId }), let v = me.latest else { return "" }
            return """
            <section class="card getapp"><div class="row">\(icon(me.iconPath ?? v.iconPath))
              <div class="grow"><div class="name">SelfStore app</div><div class="muted small">Install and build this Mac's apps from your iPhone</div></div>
              <a class="btn" href="\(esc(base))/get">Get</a></div></section>
            """
        }()
        let empty = apps.isEmpty ? "<p class=\"muted center\">No apps yet. Agents can upload with <code>POST /api/apps</code>.</p>" : ""

        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <title>SelfStore · \(esc(info.name))</title>
        <style>
          :root { --bg:#f2f2f7; --card:#fff; --text:#000; --muted:#8a8a8e; --accent:#007aff; --line:#e5e5ea; }
          @media (prefers-color-scheme: dark) { :root { --bg:#000; --card:#1c1c1e; --text:#fff; --muted:#8d8d93; --accent:#0a84ff; --line:#2c2c2e; } }
          * { box-sizing:border-box; }
          body { margin:0; background:var(--bg); color:var(--text); font:17px/1.35 -apple-system, system-ui, sans-serif;
                 padding:max(16px, env(safe-area-inset-top)) 16px 40px; }
          main { max-width:640px; margin:0 auto; }
          h1 { font-size:34px; margin:12px 4px 2px; letter-spacing:-0.5px; }
          .sub { margin:0 4px 18px; }
          .card { background:var(--card); border-radius:16px; padding:14px; margin-bottom:12px; }
          .row { display:flex; align-items:center; gap:14px; }
          .grow { flex:1; min-width:0; }
          .icon { width:64px; height:64px; border-radius:15px; flex:none; border:0.5px solid var(--line); object-fit:cover; }
          .placeholder { background:linear-gradient(135deg,#8e8e93,#636366); }
          .name { font-weight:600; font-size:18px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
          .muted { color:var(--muted); } .small { font-size:13px; } .center { text-align:center; }
          .btn { background:var(--accent); color:#fff; text-decoration:none; font-weight:700; font-size:15px;
                 padding:7px 18px; border-radius:999px; flex:none; }
          .small-btn { padding:4px 14px; font-size:13px; }
          .notes { margin:10px 0 0; font-size:14px; white-space:pre-wrap; }
          details { margin-top:10px; border-top:0.5px solid var(--line); padding-top:8px; font-size:14px; }
          summary { color:var(--accent); cursor:pointer; }
          ul { list-style:none; padding:0; margin:6px 0 0; }
          li { display:flex; justify-content:space-between; align-items:center; gap:10px; padding:8px 0; border-bottom:0.5px solid var(--line); }
          li:last-child { border-bottom:0; }
          .warn { color:#ff453a; } .warn-card { color:#ff9f0a; font-size:14px; }
          .add { display:block; text-align:center; color:var(--accent); text-decoration:none; font-size:15px; margin:18px 0 0; }
          code { font-size:13px; }
          .getapp { border:1px solid var(--accent); }
        </style></head>
        <body><main>
          <h1>SelfStore</h1>
          <div class="sub muted">\(esc(info.name)) · \(apps.count) app\(apps.count == 1 ? "" : "s")</div>
          \(banner)
          \(getBanner)
          \(rows)
          \(empty)
          \(info.signingEnabled == true ? "<a class=\"add\" href=\"\(esc(base))/register\">Register this iPhone for installs</a>" : "")
          <a class="add" href="\(esc(addLink))">Add this Mac to the SelfStore app</a>
        </main></body></html>
        """
    }
}
