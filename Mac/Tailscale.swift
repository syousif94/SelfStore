import Foundation
import Observation

/// Shares SelfStore's local HTTP port on the tailnet with `tailscale serve`, which gives it a real
/// *.ts.net HTTPS certificate. iOS requires HTTPS for itms-services installs, so this is the install path.
@MainActor @Observable
final class TailscaleManager {
    static let shared = TailscaleManager()

    private(set) var cliPath: String?
    private(set) var dnsName: String?          // "host.tailnet.ts.net"
    private(set) var isServing = false
    private(set) var status = "Checking Tailscale…"
    private(set) var busy = false

    var baseURL: URL? {
        #if DEBUG
        // Screenshots: `-demoTailscaleURL https://my-mac.example.ts.net:8767`
        if let demo = UserDefaults.standard.string(forKey: "demoTailscaleURL") { return URL(string: demo) }
        #endif
        guard isServing, let dnsName else { return nil }
        return URL(string: "https://\(dnsName):\(Settings.shared.tailscalePort)")
    }

    private init() {
        cliPath = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Reads state; if sharing is enabled but not configured, configures it.
    func sync() async {
        #if DEBUG
        // Demo/screenshot mode never touches the real `tailscale serve` configuration.
        if UserDefaults.standard.string(forKey: "demoTailscaleURL") != nil { status = "Sharing"; return }
        #endif
        guard let cli = cliPath else {
            status = "Tailscale CLI not found. Install Tailscale to enable installs."
            dnsName = nil; isServing = false
            return
        }
        busy = true
        defer { busy = false }
        let port = Settings.shared.tailscalePort
        let httpPort = Settings.shared.httpPort
        let want = Settings.shared.shareOverTailscale

        let result: (dns: String?, serving: Bool, error: String?) = await Task.detached {
            do {
                let statusJSON = try JSONSerialization.jsonObject(with: Shell.run(cli, ["status", "--json"])) as? [String: Any]
                guard (statusJSON?["BackendState"] as? String) == "Running",
                      let me = statusJSON?["Self"] as? [String: Any],
                      var dns = me["DNSName"] as? String, !dns.isEmpty else {
                    return (nil, false, "Tailscale is not connected.")
                }
                if dns.hasSuffix(".") { dns.removeLast() }
                var serving = Self.isConfigured(cli: cli, host: dns, port: port, httpPort: httpPort)
                if want && !serving {
                    try Shell.run(cli, ["serve", "--bg", "--yes", "--https=\(port)", "http://127.0.0.1:\(httpPort)"])
                    serving = Self.isConfigured(cli: cli, host: dns, port: port, httpPort: httpPort)
                } else if !want && serving {
                    try Shell.run(cli, ["serve", "--https=\(port)", "off"])
                    serving = false
                }
                return (dns, serving, nil)
            } catch {
                return (nil, false, error.localizedDescription)
            }
        }.value

        dnsName = result.dns
        isServing = result.serving
        if let error = result.error {
            status = error
        } else if result.serving {
            status = "Serving on tailnet"
        } else {
            status = want ? "Could not enable tailscale serve" : "Tailscale sharing is off"
        }
        ServerController.shared.updateBonjour()
    }

    nonisolated private static func isConfigured(cli: String, host: String, port: UInt16, httpPort: UInt16) -> Bool {
        guard let data = try? Shell.run(cli, ["serve", "status", "--json"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["Web"] as? [String: Any],
              let site = web["\(host):\(port)"] as? [String: Any],
              let handlers = site["Handlers"] as? [String: Any],
              let root = handlers["/"] as? [String: Any],
              let proxy = root["Proxy"] as? String else { return false }
        return proxy.hasSuffix(":\(httpPort)") || proxy.hasSuffix(":\(httpPort)/")
    }
}
