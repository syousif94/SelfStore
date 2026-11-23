import Foundation

/// Moves an app's bundle IDs to the user's preferred prefix while re-signing.
///
/// The main app keeps the last component of its ID: `com.someone.Notes` → `com.sammyyousif.Notes`.
/// Anything nested under the app's ID keeps its tail (`com.someone.Notes.Share` → `com.sammyyousif.Notes.Share`),
/// and other IDs on the old prefix (`com.someone.NotesWidget`, `group.com.someone.shared`) move to the new prefix.
/// An optional suffix (used for non-default git branches) is appended to the app ID, so branches install side by side.
struct BundleRename: Codable, Hashable, Sendable {
    var from: String   // original main app bundle ID
    var to: String     // new main app bundle ID

    /// The new main app ID for `original`, or nil when nothing would change.
    static func target(for original: String, prefix: String?, suffix: String?) -> String? {
        let cleanPrefix = (prefix ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        let cleanSuffix = suffix.map(sanitize).flatMap { $0.isEmpty ? nil : $0 }
        guard !cleanPrefix.isEmpty || cleanSuffix != nil else { return nil }
        let last = original.split(separator: ".").last.map(String.init) ?? original
        var out = cleanPrefix.isEmpty ? original : "\(cleanPrefix).\(last)"
        if let cleanSuffix { out += ".\(cleanSuffix)" }
        return out == original ? nil : out
    }

    /// A cleaned-up prefix (`com.example`), or nil when it isn't a valid bundle ID prefix.
    static func validPrefix(_ raw: String) -> String? {
        let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        guard !clean.isEmpty, clean.count <= 100 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) } }) else { return nil }
        return clean
    }

    /// Bundle ID components allow letters, digits and hyphens.
    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let mapped = String(s.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" })
        return mapped.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }

    private var fromParts: [Substring] { from.split(separator: ".") }
    private var oldPrefix: [Substring] { Array(fromParts.dropLast()) }
    /// `to` without the app's last component and suffix, i.e. the user's prefix.
    private var newPrefix: [Substring] {
        let toParts = to.split(separator: ".")
        let last = fromParts.last ?? ""
        // Find where the app's own name sits in the new ID; everything before it is the new prefix.
        if let i = toParts.lastIndex(of: last) { return Array(toParts[..<i]) }
        return Array(toParts.dropLast())
    }
    private var suffix: [Substring] {
        let toParts = to.split(separator: ".")
        let last = fromParts.last ?? ""
        if let i = toParts.lastIndex(of: last) { return Array(toParts[(i + 1)...]) }
        return []
    }

    /// Rewrites one identifier-like string (a bundle ID, app group, iCloud container, keychain group…).
    /// Matching is done on whole dot-separated components so `com.someoneelse` is never touched by `com.someone`.
    func map(_ s: String) -> String {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let app = fromParts
        // 1. The full app ID anywhere in the string (group.<appID>, iCloud.<appID>, <appID>.Share …).
        if let i = find(app, in: parts) {
            let replaced = parts[..<i] + to.split(separator: ".") + parts[(i + app.count)...]
            return replaced.joined(separator: ".")
        }
        // 2. Other identifiers on the app's old prefix.
        let old = oldPrefix
        guard old.count >= 2 || (old.count == 1 && !["com", "org", "net", "io", "app", "dev"].contains(String(old[0]))),
              let i = find(old, in: parts), i + old.count < parts.count else { return s }
        var replaced = Array(parts[..<i]) + newPrefix + Array(parts[(i + old.count)...])
        replaced += suffix
        return replaced.joined(separator: ".")
    }

    private func find(_ needle: [Substring], in hay: [Substring]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    // MARK: Applying to a bundle

    /// Info.plist keys that hold bundle identifiers of this app or its companions.
    private static let infoKeys = ["CFBundleIdentifier", "WKCompanionAppBundleIdentifier", "WKAppBundleIdentifier"]
    /// Entitlement keys whose values are identifiers derived from the bundle ID.
    static let entitlementKeys = [
        "com.apple.security.application-groups",
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.ubiquity-container-identifiers",
        "com.apple.developer.ubiquity-kvstore-identifier",
        "keychain-access-groups",
    ]

    /// Rewrites the bundle IDs in a bundle's Info.plist (keeping its binary/XML format). Returns the new ID.
    @discardableResult
    func apply(toBundle bundle: URL) throws -> String? {
        let url = bundle.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var info = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            return nil
        }
        for key in Self.infoKeys { if let s = info[key] as? String { info[key] = map(s) } }
        if var ext = info["NSExtension"] as? [String: Any], var attrs = ext["NSExtensionAttributes"] as? [String: Any] {
            for key in Self.infoKeys { if let s = attrs[key] as? String { attrs[key] = map(s) } }
            ext["NSExtensionAttributes"] = attrs
            info["NSExtension"] = ext
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: url)
        return info["CFBundleIdentifier"] as? String
    }

    /// Rewrites identifier values in an entitlements dictionary. Team prefixes (`ABCDE12345.`) are kept as-is;
    /// the signer retargets them separately.
    func apply(toEntitlements ent: [String: Any]) -> [String: Any] {
        var out = ent
        for key in Self.entitlementKeys {
            if let s = out[key] as? String { out[key] = mapKeepingTeam(s) }
            if let a = out[key] as? [Any] { out[key] = a.map { ($0 as? String).map(mapKeepingTeam) ?? $0 } }
        }
        return out
    }

    private func mapKeepingTeam(_ s: String) -> String {
        if let m = s.firstMatch(of: /^([A-Z0-9]{10}|SELFSTORE|\$\([A-Za-z]+\))\.(.+)$/) {
            return "\(m.1).\(map(String(m.2)))"
        }
        return map(s)
    }
}
