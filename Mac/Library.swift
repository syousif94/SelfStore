import Foundation
import Observation

/// One stored build. Persisted as record.json next to app.ipa and icon.png.
struct StoredVersion: Codable, Identifiable, Hashable {
    var id: String          // "<version>-<build>", filesystem safe
    var bundleId: String
    var name: String
    var version: String
    var build: String
    var uploadedAt: Date
    var size: Int64
    var notes: String?
    var minimumOSVersion: String?
    var expiresAt: Date?
    var provisionedDevices: Int?
    var teamName: String?
    var hasIcon: Bool
    var resignedAt: Date? = nil
    var signingWarnings: [String]? = nil
    var testFlight: TestFlightRecord? = nil
    /// The bundle ID inside the uploaded .ipa when SelfStore moved it to the preferred prefix (nil = unchanged).
    var originalBundleId: String? = nil
    /// Where the build came from, e.g. "Upload", "Build of Notes", "github.com/x/y main @ abc1234".
    var source: String? = nil

    /// How the original .ipa's IDs are rewritten whenever this version is signed.
    var renaming: BundleRename? { originalBundleId.map { BundleRename(from: $0, to: bundleId) } }

    var displayVersion: String { build.isEmpty || build == version ? version : "\(version) (\(build))" }
}

struct StoredApp: Identifiable, Hashable {
    var bundleId: String
    var versions: [StoredVersion]   // newest first
    var id: String { bundleId }
    var latest: StoredVersion { versions[0] }
    var name: String { latest.name }
}

enum LibraryError: LocalizedError {
    case notFound
    case duplicate(String)
    var errorDescription: String? {
        switch self {
        case .notFound: return "Not found"
        case .duplicate(let v): return "Version \(v) already exists (pass replace=true to overwrite)"
        }
    }
}

/// On-disk store of hosted apps:
///   ~/Library/Application Support/SelfStore/apps/<bundleId>/<versionId>/{app.ipa, icon.png, record.json}
@MainActor @Observable
final class AppLibrary {
    static let shared = AppLibrary()

    private(set) var apps: [StoredApp] = []
    let root: URL
    var appsDir: URL { root.appendingPathComponent("apps", isDirectory: true) }
    var incomingDir: URL { root.appendingPathComponent("incoming", isDirectory: true) }

    private init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SelfStore", isDirectory: true)
        try? FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: incomingDir)
        try? FileManager.default.createDirectory(at: incomingDir, withIntermediateDirectories: true)
        reload()
        // TestFlight uploads interrupted by a quit are reported as failed.
        for app in apps {
            for v in app.versions where v.testFlight?.isActive == true {
                var r = v.testFlight!
                r.state = .failed; r.error = "Interrupted"; r.step = nil; r.finishedAt = Date()
                try? setTestFlight(v.bundleId, v.id, r)
            }
        }
    }

    func setTestFlight(_ bundleId: String, _ versionId: String, _ record: TestFlightRecord?) throws {
        guard var v = version(bundleId, versionId) else { throw LibraryError.notFound }
        v.testFlight = record
        try JSONEncoder.selfStore.encode(v).write(to: versionDir(bundleId, versionId).appendingPathComponent("record.json"))
        reload()
    }

    /// The build to re-sign from: the original upload if SelfStore re-signed it, else the stored .ipa.
    func sourceIPA(_ v: StoredVersion) -> URL {
        let original = versionDir(v.bundleId, v.id).appendingPathComponent("original.ipa")
        return FileManager.default.fileExists(atPath: original.path) ? original : ipaURL(v)
    }

    func reload() {
        let fm = FileManager.default
        let decoder = JSONDecoder.selfStore
        var result: [StoredApp] = []
        for appDir in (try? fm.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil)) ?? [] {
            var versions: [StoredVersion] = []
            for vDir in (try? fm.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil)) ?? [] {
                let rec = vDir.appendingPathComponent("record.json")
                if let data = try? Data(contentsOf: rec), let v = try? decoder.decode(StoredVersion.self, from: data),
                   fm.fileExists(atPath: vDir.appendingPathComponent("app.ipa").path) {
                    versions.append(v)
                }
            }
            guard !versions.isEmpty else { continue }
            versions.sort { $0.uploadedAt > $1.uploadedAt }
            result.append(StoredApp(bundleId: versions[0].bundleId, versions: versions))
        }
        apps = result.sorted { $0.latest.uploadedAt > $1.latest.uploadedAt }
    }

    func app(_ bundleId: String) -> StoredApp? { apps.first { $0.bundleId == bundleId } }

    func version(_ bundleId: String, _ versionId: String) -> StoredVersion? {
        app(bundleId)?.versions.first { $0.id == versionId }
    }

    func versionDir(_ bundleId: String, _ versionId: String) -> URL {
        appsDir.appendingPathComponent(bundleId, isDirectory: true).appendingPathComponent(versionId, isDirectory: true)
    }

    func ipaURL(_ v: StoredVersion) -> URL { versionDir(v.bundleId, v.id).appendingPathComponent("app.ipa") }
    func iconURL(_ v: StoredVersion) -> URL { versionDir(v.bundleId, v.id).appendingPathComponent("icon.png") }

    /// A fresh temp path for an upload in progress (same volume, so the final move is cheap).
    nonisolated static func makeIncomingURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SelfStore/incoming/\(UUID().uuidString).ipa")
    }

    /// The library bundle ID an .ipa with `bundleId` gets: moved to the preferred prefix when renaming is on,
    /// plus `suffix` (a branch name) when given. Renaming needs re-signing, so it only applies when signing.
    func targetBundleId(for bundleId: String, rename: Bool?, suffix: String?, signing shouldSign: Bool) -> String {
        guard shouldSign else { return bundleId }
        let settings = Settings.shared
        let prefix = (rename ?? settings.renameImports) ? settings.bundlePrefix : nil
        return BundleRename.target(for: bundleId, prefix: prefix, suffix: suffix) ?? bundleId
    }

    /// Imports an .ipa. `move` = take ownership of the file (used for uploads); otherwise it is copied.
    /// `resign` nil = follow the Settings toggle (when signing is set up).
    /// `rename` nil = follow the Settings toggle for moving bundle IDs to the preferred prefix.
    /// `idSuffix` is appended to the app's bundle ID (non-default git branches), so it installs side by side.
    @discardableResult
    func importIPA(at source: URL, move: Bool, notes: String?, replace: Bool = true, resign: Bool? = nil,
                   rename: Bool? = nil, idSuffix: String? = nil, sourceLabel: String? = nil) async throws -> StoredVersion {
        let info = try await Task.detached(priority: .userInitiated) { try IPAInspector.inspect(source) }.value
        let versionId = Self.safeComponent("\(info.version)-\(info.build.isEmpty ? "0" : info.build)")
        let signing = SigningManager.shared
        let shouldSign = resign ?? (signing.credentials != nil && signing.resignUploads)
        let target = targetBundleId(for: info.bundleId, rename: rename, suffix: idSuffix, signing: shouldSign)
        let bundleId = Self.safeComponent(target)
        let fm = FileManager.default
        let dir = versionDir(bundleId, versionId)
        if fm.fileExists(atPath: dir.path) {
            guard replace else { throw LibraryError.duplicate(versionId) }
            try fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = dir.appendingPathComponent(shouldSign ? "original.ipa" : "app.ipa")
        if move { try fm.moveItem(at: source, to: original) } else { try fm.copyItem(at: source, to: original) }
        if let png = info.iconPNG { try png.write(to: dir.appendingPathComponent("icon.png")) }
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        var record = StoredVersion(
            id: versionId, bundleId: bundleId, name: info.name, version: info.version, build: info.build,
            uploadedAt: Date(), size: 0, notes: (trimmedNotes?.isEmpty ?? true) ? nil : trimmedNotes,
            minimumOSVersion: info.minimumOSVersion, expiresAt: info.expiresAt,
            provisionedDevices: info.provisionedDevices, teamName: info.teamName, hasIcon: info.iconPNG != nil)
        record.originalBundleId = target == info.bundleId ? nil : info.bundleId
        record.source = sourceLabel
        if shouldSign {
            do {
                record = try await signInPlace(record, dir: dir)
            } catch {
                try? fm.removeItem(at: dir)
                reload()
                throw error
            }
        } else {
            record.size = Self.fileSize(original)
            try JSONEncoder.selfStore.encode(record).write(to: dir.appendingPathComponent("record.json"))
        }
        reload()
        return record
    }

    /// Re-signs a stored version from its original upload (or its current .ipa if there is no original).
    @discardableResult
    func resign(_ bundleId: String, _ versionId: String) async throws -> StoredVersion {
        guard let v = version(bundleId, versionId) else { throw LibraryError.notFound }
        let dir = versionDir(bundleId, versionId)
        let original = dir.appendingPathComponent("original.ipa")
        if !FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.copyItem(at: dir.appendingPathComponent("app.ipa"), to: original)
        }
        let updated = try await signInPlace(v, dir: dir)
        reload()
        return updated
    }

    private func signInPlace(_ v: StoredVersion, dir: URL) async throws -> StoredVersion {
        let original = dir.appendingPathComponent("original.ipa")
        let tmp = dir.appendingPathComponent("signing.ipa")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let report = try await SigningManager.shared.resign(input: original, output: tmp, rename: v.renaming)
        let signedInfo = try await Task.detached { try IPAInspector.inspect(tmp) }.value
        let dest = dir.appendingPathComponent("app.ipa")
        _ = try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        var record = v
        record.size = Self.fileSize(dest)
        record.expiresAt = signedInfo.expiresAt
        record.provisionedDevices = signedInfo.provisionedDevices
        record.teamName = signedInfo.teamName
        record.resignedAt = Date()
        record.signingWarnings = report.warnings.isEmpty ? nil : report.warnings
        // A TestFlight upload may have updated its status while this was signing.
        if let current = version(v.bundleId, v.id) { record.testFlight = current.testFlight }
        try JSONEncoder.selfStore.encode(record).write(to: dir.appendingPathComponent("record.json"))
        return record
    }

    nonisolated static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    func updateNotes(_ bundleId: String, _ versionId: String, notes: String?) throws -> StoredVersion {
        guard var v = version(bundleId, versionId) else { throw LibraryError.notFound }
        v.notes = notes
        try JSONEncoder.selfStore.encode(v).write(to: versionDir(bundleId, versionId).appendingPathComponent("record.json"))
        reload()
        return v
    }

    func delete(bundleId: String, versionId: String? = nil) throws {
        guard app(bundleId) != nil else { throw LibraryError.notFound }
        let fm = FileManager.default
        let appDir = appsDir.appendingPathComponent(bundleId, isDirectory: true)
        if let versionId {
            guard version(bundleId, versionId) != nil else { throw LibraryError.notFound }
            try fm.removeItem(at: versionDir(bundleId, versionId))
            if ((try? fm.contentsOfDirectory(atPath: appDir.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty {
                try? fm.removeItem(at: appDir)
            }
        } else {
            try fm.removeItem(at: appDir)
        }
        reload()
    }

    /// Keeps only the newest `keep` versions of an app.
    func prune(bundleId: String, keep: Int) throws -> [String] {
        guard let app = app(bundleId) else { throw LibraryError.notFound }
        let doomed = app.versions.dropFirst(max(keep, 1)).map(\.id)
        for id in doomed { try FileManager.default.removeItem(at: versionDir(bundleId, id)) }
        reload()
        return doomed
    }

    nonisolated static func safeComponent(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let mapped = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return mapped.isEmpty || mapped.hasPrefix(".") ? "_" + mapped : mapped
    }
}
