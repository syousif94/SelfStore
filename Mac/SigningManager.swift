import CryptoKit
import Foundation
import Observation

/// Owns the App Store Connect key, the Apple Distribution identity and the device list, and re-signs builds.
@MainActor @Observable
final class SigningManager {
    static let shared = SigningManager()

    private(set) var credentials: ASCCredentials?
    private(set) var identity: SigningKeychain.Identity?
    private(set) var certificateID: String?
    /// Developer ID Application identity for Mac apps (nil = Mac builds are signed ad hoc and not notarized).
    private(set) var developerID: SigningKeychain.Identity?
    /// The account's certificate resource for `developerID`, when the API key can list it.
    private(set) var developerIDCertificateID: String?
    private(set) var devices: [ASCClient.Device] = []
    private(set) var status = "Not set up"
    private(set) var lastError: String?
    private(set) var busy: String?
    private(set) var resignProgress: String?

    /// Re-sign every upload (default on once signing is ready).
    var resignUploads: Bool { didSet { UserDefaults.standard.set(resignUploads, forKey: "resignUploads") } }

    let keychain = SigningKeychain.standard
    var client: ASCClient? { credentials.map(ASCClient.init) }
    var isReady: Bool { credentials != nil && identity != nil && certificateID != nil }

    private init() {
        UserDefaults.standard.register(defaults: ["resignUploads": true])
        resignUploads = UserDefaults.standard.bool(forKey: "resignUploads")
        // `-noSigning YES` (tests, demo screenshots): never read the stored API key.
        if UserDefaults.standard.bool(forKey: "noSigning") { return }
        if let d = SecretStore.get("asc-credentials") { credentials = try? JSONDecoder().decode(ASCCredentials.self, from: d) }
    }

    // MARK: Setup

    func importKey(p8: String, keyID: String, issuerID: String) async throws {
        let creds = ASCCredentials(keyID: keyID.trimmingCharacters(in: .whitespacesAndNewlines),
                                   issuerID: issuerID.trimmingCharacters(in: .whitespacesAndNewlines),
                                   privateKeyPEM: p8)
        let c = ASCClient(creds: creds)
        _ = try c.token()
        _ = try await c.devices() // proves the key works
        SecretStore.set("asc-credentials", try JSONEncoder().encode(creds))
        credentials = creds
        await refresh()
    }

    func removeKey() {
        SecretStore.set("asc-credentials", nil)
        credentials = nil
        devices = []
        certificateID = nil
        status = "Not set up"
    }

    /// Re-reads devices and matches the keychain identity to a certificate on the account.
    func refresh() async {
        guard let client else { status = "Not set up"; return }
        busy = "Checking…"
        defer { busy = nil }
        do {
            devices = try await client.devices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let kc = keychain
            let ids = try await Task.detached { try kc.identities() }.value
            let certs = try await client.distributionCertificates()
            let match = ids.compactMap { id in
                certs.first { SigningKeychain.normalizeSerial($0.serialNumber) == id.serial }.map { (id, $0) }
            }.max { ($0.0.expires ?? .distantPast) < ($1.0.expires ?? .distantPast) }
            identity = match?.0
            certificateID = match?.1.id
            // Developer ID is optional; some keys can't list those certificates.
            let devCerts = (try? await client.developerIDCertificates()) ?? []
            let team = identity?.commonName.firstMatch(of: /\(([A-Z0-9]{10})\)\s*$/).map { String($0.1) }
            func pick(_ list: [SigningKeychain.Identity]) -> SigningKeychain.Identity? {
                list.filter { id in
                    devCerts.contains { SigningKeychain.normalizeSerial($0.serialNumber) == id.serial }
                        || (devCerts.isEmpty && id.commonName.hasPrefix("Developer ID Application")
                            && (team == nil || id.commonName.hasSuffix("(\(team!))")))
                }.max { ($0.expires ?? .distantPast) < ($1.expires ?? .distantPast) }
            }
            developerID = pick(ids)
            developerIDCertificateID = developerID.flatMap { d in
                devCerts.first { SigningKeychain.normalizeSerial($0.serialNumber) == d.serial }?.id
            }
            lastError = nil
            if identity == nil {
                status = "Needs an Apple Distribution certificate"
            } else if devices.isEmpty {
                status = "Ready, but no devices registered"
            } else {
                status = "Ready · \(devices.count) device\(devices.count == 1 ? "" : "s")"
            }
        } catch {
            lastError = error.localizedDescription
            status = "Error"
        }
    }

    func createCertificate() async throws {
        guard let client else { throw ASCError(status: 0, message: "Import an API key first") }
        busy = "Creating certificate…"
        defer { busy = nil }
        let kc = keychain
        try await Task.detached { try await kc.createDistributionIdentity(using: client) }.value
        await refresh()
    }

    func createDeveloperIDCertificate() async throws {
        guard let client else { throw ASCError(status: 0, message: "Import an API key first") }
        busy = "Creating Developer ID certificate…"
        defer { busy = nil }
        let kc = keychain
        try await Task.detached { try await kc.createDeveloperIDIdentity(using: client) }.value
        await refresh()
    }

    /// Imports an Apple Distribution or Developer ID Application identity.
    func importP12(_ url: URL, password: String) async throws {
        let kc = keychain
        let hadDistribution = identity != nil, hadDeveloperID = developerID != nil
        try await Task.detached { try kc.importP12(url, password: password) }.value
        await refresh()
        if (identity != nil) == hadDistribution && (developerID != nil) == hadDeveloperID {
            throw ASCError(status: 0, message: "Imported, but that isn't a new Apple Distribution or Developer ID Application certificate on this API key's team.")
        }
    }

    var hasPendingRequest: Bool { keychain.hasPendingRequest }

    func saveSigningRequest(to url: URL) async throws {
        let kc = keychain
        try await Task.detached { try kc.writeSigningRequest(to: url) }.value
    }

    /// Imports a certificate downloaded from developer.apple.com for a request saved by SelfStore.
    func importCertificate(_ url: URL) async throws -> String {
        let kc = keychain
        let name = try await Task.detached { try kc.importCertificate(url) }.value
        await refresh()
        return name
    }

    /// Team ID, read from a certificate's "Name (TEAMID)" common name.
    var teamID: String? {
        for name in [developerID?.commonName, identity?.commonName].compactMap({ $0 }) {
            if let m = name.firstMatch(of: /\(([A-Z0-9]{10})\)\s*$/) { return String(m.1) }
        }
        return nil
    }

    // MARK: Devices

    func registerDevice(udid: String, name: String) async throws {
        guard let client else { throw ASCError(status: 0, message: "Signing isn't set up on this Mac") }
        let clean = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ASCError(status: 0, message: "Missing UDID") }
        if !devices.contains(where: { $0.udid.caseInsensitiveCompare(clean) == .orderedSame }) {
            do {
                try await client.registerDevice(name: name.isEmpty ? "iPhone" : name, udid: clean)
            } catch let e as ASCError where e.status == 409 {
                // Already registered (maybe disabled); fall through to refresh.
                lastError = e.localizedDescription
            }
        }
        let before = devices.count
        await refresh()
        if devices.count != before, isReady { resignAllInBackground() }
    }

    // MARK: Signing

    /// A Developer ID provisioning profile for a Mac bundle ID, cached until two weeks before it expires.
    /// It carries whatever capabilities (iCloud containers, push…) the App ID has on the account.
    func developerIDProfile(for bundleID: String) async throws -> Data {
        guard let client, let developerID, let certID = developerIDCertificateID else {
            throw ASCError(status: 0, message: "Developer ID signing isn't set up")
        }
        let dir = keychain.dir.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = dir.appendingPathComponent("\(bundleID).developerid.provisionprofile")
        if let data = try? Data(contentsOf: cache), let p = Signer.plist(inProfile: data),
           let exp = p["ExpirationDate"] as? Date, exp > Date().addingTimeInterval(14 * 86400),
           let certs = p["DeveloperCertificates"] as? [Data],
           certs.contains(where: { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() == developerID.sha1 }) {
            return data
        }
        let resource = try await client.bundleIDResource(for: bundleID, platform: "MAC_OS")
        let profile = try await client.createDeveloperIDProfile(
            name: "SelfStore Developer ID \(bundleID)", bundleIDResource: resource, certificateID: certID)
        try profile.content.write(to: cache)
        return profile.content
    }

    func makeSigner(mode: Signer.Mode = .adHoc) async throws -> Signer {
        if !isReady { await refresh() }
        guard let client, let identity, let certificateID else {
            throw ASCError(status: 0, message: credentials == nil ? "Signing isn't set up (no API key)" : status)
        }
        // Always use a fresh device list so new phones are included (App Store profiles have none).
        if mode == .adHoc { devices = try await client.devices() }
        return Signer(context: .init(client: client, keychain: keychain, identity: identity,
                                     certificateID: certificateID, devices: mode == .adHoc ? devices : []),
                      mode: mode)
    }

    func resign(input: URL, output: URL, mode: Signer.Mode = .adHoc, rename: BundleRename? = nil) async throws -> Signer.Report {
        var signer = try await makeSigner(mode: mode)
        signer.rename = rename
        return try await Task.detached { try await signer.resign(input: input, output: output) }.value
    }

    /// Re-signs the newest version of every app (e.g. after a device was added).
    func resignAllInBackground() {
        Task {
            let lib = AppLibrary.shared
            for app in lib.apps {
                resignProgress = "Re-signing \(app.name)…"
                do { _ = try await lib.resign(app.bundleId, app.latest.id) }
                catch { lastError = "\(app.name): \(error.localizedDescription)" }
            }
            resignProgress = nil
        }
    }

    // MARK: Status for the API

    struct Status: Codable {
        var configured: Bool
        var ready: Bool
        var status: String
        var keyID: String?
        var certificate: String?
        var certificateExpires: Date?
        var developerIDCertificate: String?
        var developerIDExpires: Date?
        var devices: [DeviceInfo]
        var resignUploads: Bool
        var lastError: String?
    }
    struct DeviceInfo: Codable { var name: String; var udid: String; var model: String?; var deviceClass: String }

    var apiStatus: Status {
        Status(configured: credentials != nil, ready: isReady, status: status, keyID: credentials?.keyID,
               certificate: identity?.commonName, certificateExpires: identity?.expires,
               developerIDCertificate: developerID?.commonName, developerIDExpires: developerID?.expires,
               devices: devices.map { DeviceInfo(name: $0.name, udid: $0.udid, model: $0.model, deviceClass: $0.deviceClass) },
               resignUploads: resignUploads, lastError: lastError)
    }
}
