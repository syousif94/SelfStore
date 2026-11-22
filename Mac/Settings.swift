import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    var shareOverTailscale: Bool { didSet { d.set(shareOverTailscale, forKey: "shareOverTailscale") } }
    /// Required for uploads/deletes that don't come directly from this Mac (e.g. other machines on the tailnet).
    var apiToken: String { didSet { d.set(apiToken, forKey: "apiToken") } }
    /// Uploaded, repo and built apps move to this bundle ID prefix (keeping the last component), e.g. "com.example".
    var bundlePrefix: String { didSet { d.set(bundlePrefix, forKey: "bundlePrefix") } }
    /// Default for imports that don't say whether to rename.
    var renameImports: Bool { didSet { d.set(renameImports, forKey: "renameImports") } }
    let httpPort: UInt16
    let tailscalePort: UInt16

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("SelfStore login item: \(error)") }
        }
    }

    private init() {
        d.register(defaults: [
            "showMenuBarIcon": true,
            "shareOverTailscale": true,
            "httpPort": Int(SelfStoreConstants.defaultHTTPPort),
            "tailscalePort": Int(SelfStoreConstants.defaultTailscalePort),
            "renameImports": true,
        ])
        bundlePrefix = d.string(forKey: "bundlePrefix") ?? ""
        renameImports = d.bool(forKey: "renameImports")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
        shareOverTailscale = d.bool(forKey: "shareOverTailscale")
        httpPort = UInt16(clamping: d.integer(forKey: "httpPort"))
        tailscalePort = UInt16(clamping: d.integer(forKey: "tailscalePort"))
        if let t = d.string(forKey: "apiToken"), !t.isEmpty {
            apiToken = t
        } else {
            apiToken = Self.newToken()
            d.set(apiToken, forKey: "apiToken")
        }
    }

    nonisolated static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
