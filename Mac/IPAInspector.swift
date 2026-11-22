import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Shell {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs an executable and returns stdout. Throws on non-zero exit.
    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Drain stderr concurrently so a chatty process can't block on a full pipe.
        var errData = Data()
        let errThread = Thread { errData = err.fileHandleForReading.readDataToEndOfFile() }
        errThread.start()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        while errThread.isExecuting { usleep(1000) }
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure(message: "\((path as NSString).lastPathComponent) failed (\(p.terminationStatus)): \(msg)")
        }
        return data
    }
}

/// Reads metadata and the icon out of an .ipa without unpacking the whole archive.
struct IPAInspector {
    struct Result {
        var bundleId: String
        var name: String
        var version: String
        var build: String
        var minimumOSVersion: String?
        var iconPNG: Data?
        var expiresAt: Date?
        var provisionedDevices: Int?
        var teamName: String?
    }

    enum InspectError: LocalizedError {
        case notAnIPA(String)
        var errorDescription: String? {
            switch self { case .notAnIPA(let why): return "Not a valid .ipa: \(why)" }
        }
    }

    static func inspect(_ ipa: URL) throws -> Result {
        let listing: String
        do {
            listing = String(decoding: try Shell.run("/usr/bin/unzip", ["-Z1", ipa.path]), as: UTF8.self)
        } catch {
            throw InspectError.notAnIPA("could not read zip archive")
        }
        let entries = listing.split(separator: "\n").map(String.init)
        guard let infoEntry = entries.first(where: { $0.range(of: #"^Payload/[^/]+\.app/Info\.plist$"#, options: .regularExpression) != nil }) else {
            throw InspectError.notAnIPA("no Payload/*.app/Info.plist")
        }
        let appDir = String(infoEntry.dropLast("Info.plist".count)) // "Payload/X.app/"

        let infoData = try extract(ipa, infoEntry)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let bundleId = info["CFBundleIdentifier"] as? String else {
            throw InspectError.notAnIPA("Info.plist has no CFBundleIdentifier")
        }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? (appDir.split(separator: "/").last.map { String($0.dropLast(4)) } ?? bundleId)
        let version = (info["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (info["CFBundleVersion"] as? String) ?? ""

        var result = Result(bundleId: bundleId, name: name, version: version, build: build,
                            minimumOSVersion: info["MinimumOSVersion"] as? String)

        // Icon: prefer the declared primary icon files, then anything that looks like an app icon.
        let topLevelPNGs = entries.filter { $0.hasPrefix(appDir) && $0.hasSuffix(".png") && !$0.dropFirst(appDir.count).contains("/") }
        var iconNames: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                iconNames += (primary["CFBundleIconFiles"] as? [String]) ?? []
                if let n = primary["CFBundleIconName"] as? String { iconNames.append(n) }
            }
        }
        iconNames += (info["CFBundleIconFiles"] as? [String]) ?? []
        var candidates = topLevelPNGs.filter { entry in
            let file = String(entry.dropFirst(appDir.count))
            return iconNames.contains { file.hasPrefix($0) }
        }
        if candidates.isEmpty {
            candidates = topLevelPNGs.filter { $0.localizedCaseInsensitiveContains("icon") }
        }
        // Pick the highest resolution candidate.
        var best: (pixels: Int, png: Data)?
        for entry in candidates {
            guard let raw = try? extract(ipa, entry), let png = normalizedPNG(raw) else { continue }
            if png.pixels > (best?.pixels ?? 0) { best = png }
        }
        result.iconPNG = best?.png

        // Provisioning profile: expiry, device count, team.
        if let profEntry = entries.first(where: { $0 == appDir + "embedded.mobileprovision" }),
           let prof = try? extract(ipa, profEntry),
           let plist = embeddedPlist(in: prof) {
            result.expiresAt = plist["ExpirationDate"] as? Date
            result.provisionedDevices = (plist["ProvisionedDevices"] as? [String])?.count
            result.teamName = plist["TeamName"] as? String
        }
        return result
    }

    private static func extract(_ ipa: URL, _ entry: String) throws -> Data {
        // unzip treats [ ] * ? as wildcards; escape them.
        var escaped = ""
        for c in entry { if "[]*?".contains(c) { escaped.append("\\") }; escaped.append(c) }
        return try Shell.run("/usr/bin/unzip", ["-p", ipa.path, escaped])
    }

    /// iOS app PNGs are usually Apple "CgBI" crushed PNGs that browsers can't show.
    /// ImageIO decodes them; re-encode as a standard PNG.
    private static func normalizedPNG(_ data: Data) -> (pixels: Int, png: Data)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (image.width * image.height, out as Data)
    }

    /// A .mobileprovision is a CMS envelope around an XML plist; pull the plist out directly.
    private static func embeddedPlist(in data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let slice = data[start.lowerBound..<end.upperBound]
        return (try? PropertyListSerialization.propertyList(from: Data(slice), format: nil)) as? [String: Any]
    }
}
