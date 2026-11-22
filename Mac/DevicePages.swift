import Foundation

/// iPhone registration: a "Profile Service" .mobileconfig makes iOS post its UDID back to SelfStore,
/// which registers it with App Store Connect and re-signs the hosted apps to include it.
enum DevicePages {
    static func enrollProfile(base: String, secret: String, macName: String) -> Data {
        let url = "\(base)/api/devices/enroll?c=\(secret)"
        let plist: [String: Any] = [
            "PayloadContent": [
                "URL": url,
                "DeviceAttributes": ["UDID", "PRODUCT", "VERSION", "DEVICE_NAME", "SERIAL"],
                "Challenge": secret,
            ],
            "PayloadOrganization": "SelfStore",
            "PayloadDisplayName": "Register with SelfStore",
            "PayloadDescription": "Sends this device's identifier to SelfStore on \(macName) so it can sign apps for it. Nothing is installed.",
            "PayloadIdentifier": "com.sammyyousif.selfstore.register",
            "PayloadUUID": UUID().uuidString,
            "PayloadType": "Profile Service",
            "PayloadVersion": 1,
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    static func registerPage(base: String, ready: Bool) -> String {
        page(title: "Register This iPhone", body: ready ? """
            <p>SelfStore signs apps only for registered devices. Registering sends this iPhone's identifier (UDID)
            to the Mac, which adds it to your Apple developer account.</p>
            <ol>
              <li>Tap <b>Download Profile</b> and allow the download.</li>
              <li>Open <b>Settings</b>, tap <b>Profile Downloaded</b>, then <b>Install</b>.</li>
              <li>You'll come back here when it's done. Apps are re-signed for this iPhone in a minute or two.</li>
            </ol>
            <a class="btn" href="\(esc(base))/register.mobileconfig">Download Profile</a>
            <p class="muted small">Each registered device uses one of the account's yearly device slots.</p>
            """ : "<p>Signing isn't set up on this Mac yet. In SelfStore on the Mac, open Settings ▸ Signing and import an App Store Connect API key.</p>",
            base: base)
    }

    static func registeredPage(name: String, error: String?, base: String) -> String {
        if let error {
            return page(title: "Registration Failed", body: "<p>\(esc(name)) couldn't be registered:</p><p class=\"warn\">\(esc(error))</p>", base: base)
        }
        return page(title: "Registered", body: """
            <p><b>\(esc(name))</b> is registered. SelfStore is re-signing the apps to include it, which takes a minute or two.</p>
            <p class="muted">You can remove the profile from Settings ▸ General ▸ VPN &amp; Device Management; it isn't needed anymore.</p>
            """, base: base)
    }

    /// Install page for the SelfStore iPhone app. Opening it in Safari offers the install right away.
    static func getAppPage(version v: CatalogVersion, base: String, iconURL: String?, signingEnabled: Bool, macName: String) -> String {
        let icon = iconURL.map { "<img class=\"appicon\" src=\"\(esc($0))\" alt=\"\">" } ?? ""
        let install = v.installURL.map { url in
            """
            <a class="btn" id="install" href="\(esc(url))">Install SelfStore</a>
            <script>
              // Offer the install as soon as the page opens on an iPhone/iPad.
              if (/iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.maxTouchPoints > 1 && /Mac/.test(navigator.userAgent))) {
                setTimeout(function () { location.href = document.getElementById("install").href; }, 400);
              }
            </script>
            """
        } ?? "<p class=\"warn\">Installs need Tailscale sharing turned on in SelfStore on \(esc(macName)).</p>"
        let register = signingEnabled
            ? "<p class=\"muted small\">If the install fails, this iPhone isn't registered yet: <a href=\"\(esc(base))/register\">register it</a>, wait a minute, then come back.</p>"
            : ""
        return page(title: "SelfStore for iPhone", body: """
            <div class="center">\(icon)
              <div class="appname">SelfStore</div>
              <div class="muted">Version \(esc(v.displayVersion)) · from \(esc(macName))</div>
            </div>
            \(install)
            <p class="muted small">After installing, open SelfStore and add this Mac to browse, install and build apps.</p>
            \(register)
            """, base: base)
    }

    static func simplePage(title: String, body: String, base: String) -> String { page(title: title, body: body, base: base) }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func page(title: String, body: String, base: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <meta name="color-scheme" content="light dark"><title>SelfStore · \(esc(title))</title>
        <style>
          :root { --bg:#f2f2f7; --card:#fff; --text:#000; --muted:#8a8a8e; --accent:#007aff; }
          @media (prefers-color-scheme: dark) { :root { --bg:#000; --card:#1c1c1e; --text:#fff; --muted:#8d8d93; --accent:#0a84ff; } }
          body { margin:0; background:var(--bg); color:var(--text); font:17px/1.4 -apple-system, system-ui, sans-serif; padding:24px 16px; }
          main { max-width:560px; margin:0 auto; background:var(--card); border-radius:16px; padding:20px; }
          h1 { margin:0 0 12px; font-size:28px; } ol { padding-left:20px; } li { margin:6px 0; }
          .btn { display:block; text-align:center; background:var(--accent); color:#fff; text-decoration:none; font-weight:700;
                 padding:12px; border-radius:12px; margin:18px 0 8px; }
          .muted { color:var(--muted); } .small { font-size:13px; } .warn { color:#ff453a; }
          .center { text-align:center; } .appname { font-size:22px; font-weight:700; margin-top:10px; }
          .appicon { width:96px; height:96px; border-radius:22px; border:0.5px solid rgba(128,128,128,.3); }
          a.back { display:block; text-align:center; color:var(--accent); margin-top:16px; text-decoration:none; }
        </style></head><body><main><h1>\(esc(title))</h1>\(body)
        <a class="back" href="\(esc(base))/">Back to SelfStore</a></main></body></html>
        """
    }
}
