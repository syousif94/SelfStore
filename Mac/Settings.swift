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
    /// Where project builds (DerivedData, logs, Mac .dmg/.zip) go. Empty = the default in Application Support.
    /// Change it with ProjectStore.setBuildsFolder, which moves existing builds.
    private(set) var buildsFolder: String { didSet { d.set(buildsFolder, forKey: "buildsFolder") } }
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
        buildsFolder = d.string(forKey: "buildsFolder") ?? ""
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

    nonisolated static let defaultBuildsRoot = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SelfStore/builds", isDirectory: true)

    var usesCustomBuildsFolder: Bool { !buildsFolder.isEmpty }
    var buildsRoot: URL {
        usesCustomBuildsFolder ? URL(fileURLWithPath: buildsFolder, isDirectory: true) : Self.defaultBuildsRoot
    }
    /// A custom folder on a drive that isn't connected is unavailable; it is never created in its place.
    var buildsRootAvailable: Bool {
        guard usesCustomBuildsFolder else { return true }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: buildsFolder, isDirectory: &isDir) && isDir.boolValue
    }
    func setBuildsRoot(_ url: URL?) {
        guard let url, url.standardizedFileURL != Self.defaultBuildsRoot.standardizedFileURL else { buildsFolder = ""; return }
        buildsFolder = url.standardizedFileURL.path
    }

    nonisolated static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
