import Foundation

/// Turns a built macOS .app into a signed (Developer ID, hardened runtime), notarized and stapled
/// .dmg and .zip. Without a Developer ID identity it signs ad hoc and skips notarization.
enum MacPackager {
    struct Signing: Sendable {
        var identity: String          // codesign -s value ("-" = ad hoc)
        var keychain: String?
        var teamID: String?
        var notarize: ASCCredentials? // nil = don't notarize
        /// Developer ID provisioning profiles by bundle ID, for targets whose entitlements need one.
        var profiles: [String: Data] = [:]
    }

    struct Output: Sendable {
        var bundleId: String
        var name: String
        var version: String
        var build: String
        var artifacts: [String]       // file names in the output folder
        var notarized: Bool
        var warnings: [String]
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `settings` are xcodebuild build settings for the scheme's targets; `out` is emptied first.
    static func package(settings: [[String: String]], signing: Signing, out: URL,
                        step: @Sendable (String) -> Void) throws -> Output {
        let fm = FileManager.default
        guard let app = settings.first(where: { $0["PRODUCT_TYPE"] == "com.apple.product-type.application" && $0["PLATFORM_NAME"] == "macosx" }),
              let dir = app["TARGET_BUILD_DIR"], let wrapper = app["WRAPPER_NAME"] else {
            throw Failure(message: "The scheme doesn't build a Mac app")
        }
        let built = URL(fileURLWithPath: dir).appendingPathComponent(wrapper)
        guard fm.fileExists(atPath: built.path) else { throw Failure(message: "Built app not found at \(built.path)") }

        try? fm.removeItem(at: out)
        let staging = out.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let appCopy = staging.appendingPathComponent(wrapper)
        try Shell.run("/usr/bin/ditto", [built.path, appCopy.path])

        guard let info = NSDictionary(contentsOf: appCopy.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let bundleId = info["CFBundleIdentifier"] as? String else { throw Failure(message: "The app has no Info.plist") }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? (wrapper as NSString).deletingPathExtension
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? ""
        var warnings: [String] = []

        // 1. Sign inside-out with each target's entitlements.
        step(signing.identity == "-" ? "Signing (ad hoc)…" : "Signing with Developer ID…")
        let (entitlements, profiles) = try entitlementFiles(settings: settings, signing: signing, into: staging, warnings: &warnings)
        var nested: [URL] = []
        if let e = fm.enumerator(at: appCopy, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in e where ["framework", "appex", "app", "xpc", "dylib", "bundle"].contains(url.pathExtension) {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                nested.append(url)
            }
        }
        nested.sort { $0.pathComponents.count > $1.pathComponents.count }
        for url in nested + [appCopy] {
            if let profile = profiles[url.lastPathComponent] {
                try profile.write(to: url.appendingPathComponent("Contents/embedded.provisionprofile"))
            }
            try codesign(url, signing, entitlements: entitlements[url.lastPathComponent])
        }

        // 2. Disk image with an Applications shortcut.
        step("Creating disk image…")
        let base = AppLibrary.safeComponent("\(name)-\(version)")
        let dmg = out.appendingPathComponent("\(base).dmg")
        let dmgRoot = staging.appendingPathComponent("dmg", isDirectory: true)
        try fm.createDirectory(at: dmgRoot, withIntermediateDirectories: true)
        try Shell.run("/usr/bin/ditto", [appCopy.path, dmgRoot.appendingPathComponent(wrapper).path])
        try fm.createSymbolicLink(atPath: dmgRoot.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        try Shell.run("/usr/bin/hdiutil", ["create", "-volname", name, "-srcfolder", dmgRoot.path, "-ov", "-format", "UDZO", dmg.path])
        try? fm.removeItem(at: dmgRoot)
        if signing.identity != "-" { try codesign(dmg, signing, entitlements: nil) }

        // 3. Notarize the disk image (that also covers the app inside), then staple both.
        var notarized = false
        if let creds = signing.notarize {
            step("Notarizing (usually a few minutes)…")
            try notarize(dmg, creds: creds, work: staging)
            step("Stapling…")
            try Shell.run("/usr/bin/xcrun", ["stapler", "staple", dmg.path])
            if (try? Shell.run("/usr/bin/xcrun", ["stapler", "staple", appCopy.path])) == nil {
                warnings.append("Couldn't staple the ticket to the .app in the .zip; it's still notarized (checked online).")
            }
            notarized = true
        } else {
            warnings.append("Not notarized: add a Developer ID Application certificate in Settings ▸ Signing so other Macs open it without warnings.")
        }

        // 4. Zip of the (stapled) app, for auto-updaters and quick copies.
        let zip = out.appendingPathComponent("\(base).zip")
        try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", appCopy.path, zip.path])

        // 5. Icon for the UI.
        if let iconFile = info["CFBundleIconFile"] as? String {
            let icns = appCopy.appendingPathComponent("Contents/Resources")
                .appendingPathComponent(iconFile.hasSuffix(".icns") ? iconFile : iconFile + ".icns")
            _ = try? Shell.run("/usr/bin/sips", ["-s", "format", "png", "-Z", "256", icns.path, "--out", out.appendingPathComponent("icon.png").path])
        }

        return Output(bundleId: bundleId, name: name, version: version, build: build,
                      artifacts: [dmg.lastPathComponent, zip.lastPathComponent], notarized: notarized, warnings: warnings)
    }

    private static func codesign(_ url: URL, _ s: Signing, entitlements: URL?) throws {
        var args = ["-f", "-s", s.identity, "--options", "runtime"]
        if let kc = s.keychain { args += ["--keychain", kc] }
        args.append(s.identity == "-" ? "--timestamp=none" : "--timestamp")
        if let entitlements { args += ["--entitlements", entitlements.path] }
        try Shell.run("/usr/bin/codesign", args + [url.path])
    }

    /// Keys that only work with a provisioning profile on macOS.
    static func needsProfile(_ key: String) -> Bool {
        key.hasPrefix("com.apple.developer.")
            || ["com.apple.application-identifier", "application-identifier", "keychain-access-groups"].contains(key)
    }

    /// Entitlements files and provisioning profiles per bundle wrapper name, with build variables expanded.
    /// Entitlements that need a profile are kept where the target has one (`signing.profiles`) that allows
    /// them, and dropped otherwise.
    private static func entitlementFiles(settings: [[String: String]], signing: Signing, into dir: URL,
                                         warnings: inout [String]) throws -> ([String: URL], [String: Data]) {
        let teamID = signing.teamID
        var result: [String: URL] = [:]
        var profiles: [String: Data] = [:]
        for s in settings where result[s["WRAPPER_NAME"] ?? ""] == nil {
            guard let w = s["WRAPPER_NAME"], let rel = s["CODE_SIGN_ENTITLEMENTS"], !rel.isEmpty, let srcRoot = s["SRCROOT"] else { continue }
            let path = rel.hasPrefix("/") ? rel : (srcRoot as NSString).appendingPathComponent(rel)
            guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            var vars = s
            let prefix = teamID.map { $0 + "." } ?? ""
            vars["AppIdentifierPrefix"] = prefix
            vars["TeamIdentifierPrefix"] = prefix
            let profileData = s["PRODUCT_BUNDLE_IDENTIFIER"].flatMap { signing.profiles[$0] }
            let allowed = profileData.flatMap { Signer.plist(inProfile: $0)?["Entitlements"] as? [String: Any] }
            var out: [String: Any] = [:]
            for (key, value) in plist {
                guard needsProfile(key) else { out[key] = expand(value, vars); continue }
                guard let allowed else {
                    warnings.append("\(w): dropped \(key) (needs a provisioning profile)")
                    continue
                }
                guard let allowedValue = allowed[key] else {
                    warnings.append("\(w): dropped \(key) (not enabled for this App ID)")
                    continue
                }
                // Fixed values in the profile (e.g. aps-environment=production) win.
                if let v = allowedValue as? String, !v.contains("*") { out[key] = v } else { out[key] = expand(value, vars) }
            }
            if let allowed, let profileData {
                for key in ["com.apple.application-identifier", "com.apple.developer.team-identifier"] {
                    if let v = allowed[key] { out[key] = v }
                }
                // Developer ID builds talk to the production CloudKit environment.
                if out["com.apple.developer.icloud-services"] != nil, allowed["com.apple.developer.icloud-container-environment"] != nil {
                    out["com.apple.developer.icloud-container-environment"] = "Production"
                }
                profiles[w] = profileData
            }
            let file = dir.appendingPathComponent("\(w).entitlements")
            try PropertyListSerialization.data(fromPropertyList: out, format: .xml, options: 0).write(to: file)
            result[w] = file
        }
        return (result, profiles)
    }

    private static func expand(_ value: Any, _ settings: [String: String]) -> Any {
        if var s = value as? String {
            while let r = s.firstRange(of: /\$[({]([A-Za-z0-9_]+)(?::[^)}]*)?[)}]/) {
                let name = String(s[r].dropFirst(2).dropLast()).split(separator: ":").first.map(String.init) ?? ""
                s.replaceSubrange(r, with: settings[name] ?? "")
            }
            return s
        }
        if let a = value as? [Any] { return a.map { expand($0, settings) } }
        if let d = value as? [String: Any] { return d.mapValues { expand($0, settings) } }
        return value
    }

    // MARK: Notarization

    /// `notarytool submit --wait` with the App Store Connect key, written to a private temp file for the call.
    private static func notarize(_ file: URL, creds: ASCCredentials, work: URL) throws {
        let fm = FileManager.default
        let keyDir = work.appendingPathComponent("key-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: keyDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: keyDir) }
        let key = keyDir.appendingPathComponent("AuthKey_\(creds.keyID).p8")
        try Data(creds.privateKeyPEM.utf8).write(to: key)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        let auth = ["--key", key.path, "--key-id", creds.keyID, "--issuer", creds.issuerID]

        let (status, out) = run("/usr/bin/xcrun", ["notarytool", "submit", file.path, "--wait", "--timeout", "45m",
                                                    "--output-format", "json", "--no-progress"] + auth)
        let json = jsonObject(out)
        let id = json?["id"] as? String
        let result = json?["status"] as? String
        if result == "Accepted" { return }
        var message = "Notarization failed"
        if let result { message += " (\(result))" }
        if let id {
            // The log lists exactly which files were rejected and why.
            let (_, log) = run("/usr/bin/xcrun", ["notarytool", "log", id] + auth)
            if let issues = jsonObject(log)?["issues"] as? [[String: Any]], !issues.isEmpty {
                message += ":\n" + issues.prefix(10).map { i in
                    [i["path"] as? String, i["message"] as? String].compactMap { $0 }.joined(separator: ": ")
                }.joined(separator: "\n")
            }
        } else if status != 0 {
            message += ": " + String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)
        }
        throw Failure(message: message)
    }

    /// Runs a tool and returns its exit status and combined output (never throws on failure).
    private static func run(_ path: String, _ args: [String]) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any]
    }
}
