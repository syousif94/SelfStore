import Foundation

/// Wire format shared by the Mac server and the iOS client.
/// Paths (`iconPath`, `ipaPath`, `manifestPath`) are relative to whichever base URL the client used.
/// `installURL` is absolute (itms-services://…) and always points at the Mac's Tailscale HTTPS address.

public struct CatalogVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var bundleId: String
    public var name: String
    public var version: String
    public var build: String
    public var uploadedAt: Date
    public var size: Int64
    public var notes: String?
    public var minimumOSVersion: String?
    public var expiresAt: Date?
    public var provisionedDevices: Int?
    public var teamName: String?
    public var iconPath: String?
    public var ipaPath: String
    public var manifestPath: String
    public var installURL: String?
    public var testFlight: CatalogTestFlight? = nil
    public var originalBundleId: String? = nil   // set when the Mac moved the app to its bundle ID prefix
    public var source: String? = nil             // "Upload", "Build of X", "owner/repo main @ abc1234"

    public var displayVersion: String { build.isEmpty || build == version ? version : "\(version) (\(build))" }
}

/// Status of this version's latest TestFlight upload.
public struct CatalogTestFlight: Codable, Hashable, Sendable {
    public var state: String             // queued, signing, uploading, succeeded, failed
    public var step: String?
    public var error: String?
    public var startedAt: Date
    public var finishedAt: Date?

    public var isActive: Bool { ["queued", "signing", "uploading"].contains(state) }
}

public struct CatalogApp: Codable, Identifiable, Hashable, Sendable {
    public var bundleId: String
    public var name: String
    public var iconPath: String?
    /// Newest first.
    public var versions: [CatalogVersion]
    public var id: String { bundleId }
    public var latest: CatalogVersion? { versions.first }
}

public struct ServerInfo: Codable, Hashable, Sendable {
    public var service: String          // always "SelfStore"
    public var apiVersion: Int
    public var name: String             // Mac's display name
    public var lanURL: String?          // http://host.local:8765
    public var tailscaleURL: String?    // https://host.tailnet.ts.net:8767
    public var installsAvailable: Bool  // true when Tailscale HTTPS is serving
    public var appCount: Int
    public var signingEnabled: Bool?    // Mac re-signs builds; devices can register at /register
    public var testFlightEnabled: Bool? = nil // POST /api/apps/<bundleId>/<versionId>/testflight works
    public var bundlePrefix: String? = nil      // uploaded and repo .ipa files move to this bundle ID prefix
    public var bundlePrefixSetting: String? = nil // the prefix saved in Settings, even when renaming is off ("" = none)
    public var renameImports: Bool? = nil       // whether uploads move to bundlePrefixSetting by default
    public var reposEnabled: Bool? = nil        // /api/repos exists
}

/// An Xcode project the Mac can build on demand.
public struct CatalogProject: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String              // scheme
    public var fileName: String          // Foo.xcodeproj
    public var bundleId: String?
    public var iconPath: String?
    public var state: String?            // queued, building, signing, succeeded, failed, cancelled
    public var step: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var error: String?
    public var logTail: [String]?
    public var versionId: String?
    public var signingReady: Bool
    public var platform: String? = nil          // "ios" (default) or "macos"
    public var version: String? = nil           // Mac builds: version of the last build
    public var artifacts: [CatalogArtifact]? = nil // Mac builds: .dmg and .zip downloads
    public var notarized: Bool? = nil
    public var warnings: [String]? = nil
    public var repoId: String? = nil             // set for apps built from a repo's selfstore.yml
    public var branch: String? = nil
    public var commit: String? = nil             // commit of the last build

    public var isActive: Bool { ["queued", "building", "signing"].contains(state ?? "") }
    public var isMac: Bool { platform == "macos" }
}

/// A git repo whose selfstore.yml lists prebuilt .ipa files and/or projects to build.
public struct CatalogRepo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String                      // owner/repo
    public var url: String
    public var defaultBranch: String?
    public var state: String                     // idle, pulling, failed
    public var step: String?
    public var error: String?
    public var lastPull: Date?
    public var branches: [CatalogRepoBranch]
    public var targets: [CatalogRepoTarget]

    public var isPulling: Bool { state == "pulling" }
}

public struct CatalogRepoBranch: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var commit: String
    public var subject: String
    public var error: String?
    public var id: String { name }
}

public struct CatalogRepoTarget: Codable, Hashable, Sendable, Identifiable {
    public var id: String                        // "<branch>/<name>"
    public var name: String
    public var branch: String
    public var kind: String                      // ipa, project
    public var path: String
    public var projectId: String?                // kind == project: build it with /api/projects/<projectId>/build
    public var bundleId: String?                 // the library app it publishes to
    public var error: String?
}

/// A downloadable file produced by a Mac build. `path` is relative to the base URL.
public struct CatalogArtifact: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var size: Int64
    public var id: String { name }
}

public enum SelfStoreConstants {
    public static let bonjourType = "_selfstore._tcp"
    public static let defaultHTTPPort: UInt16 = 8765
    public static let defaultTailscalePort: UInt16 = 8767
    public static let urlScheme = "selfstore"
}

public extension JSONDecoder {
    static var selfStore: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public extension JSONEncoder {
    static var selfStore: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
