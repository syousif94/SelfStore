import CryptoKit
import Foundation

/// Re-signs an .ipa with the SelfStore Apple Distribution identity. Ad hoc: every (nested) bundle gets a fresh
/// IOS_APP_ADHOC profile that includes all registered devices. App Store: IOS_APP_STORE profiles, for TestFlight.
struct Signer: Sendable {
    enum Mode: Sendable { case adHoc, appStore }

    struct Context: Sendable {
        var client: ASCClient
        var keychain: SigningKeychain
        var identity: SigningKeychain.Identity
        var certificateID: String
        var devices: [ASCClient.Device]
    }

    struct Report: Sendable {
        var bundles: [String]
        var devices: Int
        var warnings: [String]
    }

    struct SignError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let context: Context
    var mode: Mode = .adHoc
    /// Moves bundle IDs to the user's prefix before signing (nil = keep the IDs in the .ipa).
    var rename: BundleRename? = nil
    var profilesDir: URL { context.keychain.dir.appendingPathComponent("profiles", isDirectory: true) }

    func resign(input: URL, output: URL) async throws -> Report {
        guard mode == .appStore || !context.devices.isEmpty else {
            throw SignError(message: "No devices are registered. Register an iPhone first (open the SelfStore page on it and tap Register This iPhone).")
        }
        try context.keychain.prepare()
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("selfstore-sign-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        try Shell.run("/usr/bin/ditto", ["-x", "-k", input.path, work.path])
        let payload = work.appendingPathComponent("Payload")
        guard let appName = try fm.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") }) else {
            throw SignError(message: "No Payload/*.app in the .ipa")
        }
        let app = payload.appendingPathComponent(appName)
        if fm.fileExists(atPath: app.appendingPathComponent("Watch").path) {
            throw SignError(message: "Apps with an embedded Watch app aren't supported for re-signing yet.")
        }

        // Inside-out: deepest nested code first, the app last.
        var nested: [URL] = []
        if let e = fm.enumerator(at: app, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let url as URL in e {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                switch url.pathExtension {
                case "framework", "appex", "app", "xpc": nested.append(url)
                case "dylib": nested.append(url)
                default: break
                }
            }
        }
        nested.sort { $0.pathComponents.count > $1.pathComponents.count }

        if let rename {
            for url in nested + [app] where ["app", "appex", "xpc"].contains(url.pathExtension) {
                try rename.apply(toBundle: url)
            }
        }

        var signed: [String] = []
        var warnings: [String] = []
        for url in nested {
            switch url.pathExtension {
            case "appex", "app", "xpc":
                let (id, w) = try await signBundle(url)
                signed.append(id); warnings += w
            default:
                try codesign(url, entitlements: nil)
            }
        }
        let (mainID, w) = try await signBundle(app)
        signed.insert(mainID, at: 0)
        warnings += w

        try? fm.removeItem(at: output)
        let entries = try fm.contentsOfDirectory(atPath: work.path).filter { !$0.hasPrefix(".") && !$0.hasPrefix("__MACOSX") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = work
        p.arguments = ["-qry", output.path] + entries
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SignError(message: "zip failed (\(p.terminationStatus))") }
        return Report(bundles: signed, devices: context.devices.count, warnings: warnings)
    }

    // MARK: - Bundles

    private func signBundle(_ bundle: URL) async throws -> (String, [String]) {
        let infoURL = bundle.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else {
            throw SignError(message: "\(bundle.lastPathComponent) has no CFBundleIdentifier")
        }
        let profileData = try await profile(for: bundleID)
        guard let profile = Self.plist(inProfile: profileData),
              let team = (profile["TeamIdentifier"] as? [String])?.first,
              let allowed = profile["Entitlements"] as? [String: Any] else {
            throw SignError(message: "Couldn't read the provisioning profile for \(bundleID)")
        }
        try profileData.write(to: bundle.appendingPathComponent("embedded.mobileprovision"))

        var original = currentEntitlements(bundle)
        if let rename { original = rename.apply(toEntitlements: original) }
        let (entitlements, warnings) = Self.entitlements(original: original, allowed: allowed,
                                                         team: team, bundleID: bundleID, appStore: mode == .appStore)
        let entURL = FileManager.default.temporaryDirectory.appendingPathComponent("selfstore-\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: entURL)
        defer { try? FileManager.default.removeItem(at: entURL) }
        try codesign(bundle, entitlements: entURL)
        return (bundleID, warnings.map { "\(bundleID): \($0)" })
    }

    private func codesign(_ url: URL, entitlements: URL?) throws {
        var args = ["-f", "-s", context.identity.sha1, "--keychain", context.keychain.path, "--timestamp=none"]
        if let entitlements { args += ["--entitlements", entitlements.path, "--generate-entitlement-der"] }
        try Shell.run("/usr/bin/codesign", args + [url.path])
    }

    private func currentEntitlements(_ bundle: URL) -> [String: Any] {
        guard let data = try? Shell.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", bundle.path]),
              let start = data.range(of: Data("<?xml".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: Data(data[start.lowerBound...]), format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    /// Keeps the app's own entitlements where the profile allows them, retargeted at our team,
    /// and fills in the ones every ad hoc app needs.
    static func entitlements(original: [String: Any], allowed: [String: Any], team: String, bundleID: String,
                             appStore: Bool = false) -> ([String: Any], [String]) {
        let oldTeam = (original["com.apple.developer.team-identifier"] as? String)
            ?? (original["application-identifier"] as? String)?.split(separator: ".").first.map(String.init)
        func retarget(_ v: Any) -> Any {
            if let s = v as? String, let oldTeam, oldTeam != team, s.hasPrefix(oldTeam + ".") { return team + s.dropFirst(oldTeam.count) }
            if let a = v as? [Any] { return a.map(retarget) }
            return v
        }
        var out: [String: Any] = [:]
        var warnings: [String] = []
        for (key, value) in original {
            if ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "beta-reports-active"].contains(key) { continue }
            guard let allowedValue = allowed[key] else {
                warnings.append("dropped \(key) (not enabled for this App ID)")
                continue
            }
            // Fixed values in the profile (e.g. aps-environment=production) win.
            if let s = allowedValue as? String, !s.contains("*") { out[key] = s } else { out[key] = retarget(value) }
        }
        out["application-identifier"] = "\(team).\(bundleID)"
        out["com.apple.developer.team-identifier"] = team
        out["get-task-allow"] = false
        // TestFlight needs beta-reports-active; App Store profiles allow it.
        if appStore, allowed["beta-reports-active"] != nil { out["beta-reports-active"] = true }
        if out["keychain-access-groups"] == nil, allowed["keychain-access-groups"] != nil {
            out["keychain-access-groups"] = ["\(team).\(bundleID)"]
        }
        return (out, warnings)
    }

    // MARK: - Profiles

    /// Reuses a cached profile when it still uses our certificate and (ad hoc) covers exactly the registered devices.
    private func profile(for bundleID: String) async throws -> Data {
        let fm = FileManager.default
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let appStore = mode == .appStore
        let cache = profilesDir.appendingPathComponent(appStore ? "\(bundleID).appstore.mobileprovision" : "\(bundleID).mobileprovision")
        let wantUDIDs = Set(context.devices.map(\.udid))
        if let data = try? Data(contentsOf: cache), let p = Self.plist(inProfile: data),
           appStore ? p["ProvisionedDevices"] == nil : (p["ProvisionedDevices"] as? [String]).map(Set.init) == wantUDIDs,
           let exp = p["ExpirationDate"] as? Date, exp > Date().addingTimeInterval(14 * 86400),
           let certs = p["DeveloperCertificates"] as? [Data],
           certs.contains(where: { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() == context.identity.sha1 }) {
            return data
        }
        let resource: String
        do {
            resource = try await context.client.bundleIDResource(for: bundleID)
        } catch let e as ASCError where e.status == 409 && e.message.contains("is not available") {
            throw SignError(message: "\(bundleID) is registered to another developer, so it can't be signed with your team. "
                + "Move the app to your own bundle ID prefix (Settings ▸ Bundle IDs, or the prefix field when uploading) and try again.")
        }
        let created = appStore
            ? try await context.client.createAppStoreProfile(
                name: "SelfStore App Store \(bundleID)", bundleIDResource: resource, certificateID: context.certificateID)
            : try await context.client.createAdHocProfile(
                name: "SelfStore \(bundleID)", bundleIDResource: resource,
                certificateID: context.certificateID, deviceIDs: context.devices.map(\.id))
        try created.content.write(to: cache)
        return created.content
    }

    static func plist(inProfile data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: Data(data[start.lowerBound..<end.upperBound]), format: nil)) as? [String: Any]
    }
}
