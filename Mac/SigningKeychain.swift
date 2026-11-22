import CryptoKit
import Foundation
import Security

/// Small wrapper over generic-password items in the login Keychain.
enum SecretStore {
    private static let service = "com.sammyyousif.selfstore"

    static func get(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func set(_ account: String, _ data: Data?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let data else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "SelfStore \(account)"
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Signing identities live in the user's login keychain, next to the ones Xcode makes, so they show up in
/// Keychain Access and Xcode. The first time codesign uses a key, macOS asks for permission: "Always Allow"
/// makes later builds silent. `dir` holds SelfStore's own files: backups, profiles and pending requests.
struct SigningKeychain: Sendable {
    struct Identity: Sendable, Hashable {
        var sha1: String          // codesign -s value
        var serial: String        // uppercase hex, no leading zeros
        var commonName: String
        var expires: Date?
    }

    let dir: URL
    /// The login keychain (what `codesign --keychain` and `security` get).
    var path: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path
    }
    var backupP12: URL { dir.appendingPathComponent("distribution.p12") }
    /// Where earlier versions kept identities in a private keychain (migrated on first use).
    private var legacyKeychain: String { dir.appendingPathComponent("signing.keychain-db").path }

    static let standard = SigningKeychain(dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SelfStore/signing", isDirectory: true))

    func prepare() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try migrateLegacyKeychain()
    }

    /// Imports a PKCS#12 identity into the login keychain, letting codesign use its key.
    func importP12(_ p12: URL, password p12pw: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try Shell.run("/usr/bin/security", ["import", p12.path, "-k", path, "-P", p12pw, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
        } catch let e as Shell.Failure where e.message.contains("already exists") {
            // Same identity is already there; nothing to do.
        }
    }

    /// Code signing identities in the login keychain (certificates that have their private key).
    func identities() throws -> [Identity] {
        try prepare()
        return try Self.identities(in: path)
    }

    private static func identities(in keychain: String) throws -> [Identity] {
        let out = String(decoding: try Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning", keychain]), as: UTF8.self)
        var shas = Set<String>()
        for line in out.split(separator: "\n") {
            if let m = line.firstMatch(of: /\d+\)\s+([0-9A-F]{40})\s/) { shas.insert(String(m.1)) }
        }
        guard !shas.isEmpty else { return [] }
        let pems = String(decoding: try Shell.run("/usr/bin/security", ["find-certificate", "-a", "-p", keychain]), as: UTF8.self)
        return parse(pems: pems, shas: shas)
    }

    /// Moves identities from the private keychain earlier versions used into the login keychain, using the
    /// .p12 backups SelfStore kept (or an export when there's no backup). The old file is kept, renamed.
    private func migrateLegacyKeychain() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyKeychain) else { return }
        if let d = SecretStore.get("signing-keychain-password"), let pw = String(data: d, encoding: .utf8) {
            _ = try? Shell.run("/usr/bin/security", ["unlock-keychain", "-p", pw, legacyKeychain])
        }
        let old = (try? Self.identities(in: legacyKeychain)) ?? []
        var have = Set(try Self.identities(in: path).map(\.sha1))
        for id in old where !have.contains(id.sha1) {
            // 1. A backup SelfStore made when it created the certificate.
            for (file, account) in [(backupP12, "distribution-p12-password"), (developerIDBackupP12, "developer-id-p12-password"),
                                    (dir.appendingPathComponent("distribution-imported.p12"), "distribution-imported-p12-password")] {
                guard fm.fileExists(atPath: file.path), let d = SecretStore.get(account), let pw = String(data: d, encoding: .utf8) else { continue }
                try? importP12(file, password: pw)
            }
            have = Set(try Self.identities(in: path).map(\.sha1))
            if have.contains(id.sha1) { continue }
            // 2. Export straight from the old keychain.
            let tmp = fm.temporaryDirectory.appendingPathComponent("selfstore-migrate-\(UUID().uuidString).p12")
            defer { try? fm.removeItem(at: tmp) }
            let pw = Settings.newToken()
            try Shell.run("/usr/bin/security", ["export", "-k", legacyKeychain, "-t", "identities", "-f", "pkcs12", "-P", pw, "-o", tmp.path])
            try importP12(tmp, password: pw)
            have = Set(try Self.identities(in: path).map(\.sha1))
            guard have.contains(id.sha1) else {
                throw Shell.Failure(message: "Couldn't move \(id.commonName) into your login keychain. Import \(backupP12.path) in Keychain Access.")
            }
        }
        try fm.moveItem(atPath: legacyKeychain, toPath: legacyKeychain + ".migrated")
    }

    private static func parse(pems: String, shas: Set<String>) -> [Identity] {
        var result: [Identity] = []
        for block in pems.components(separatedBy: "-----END CERTIFICATE-----") {
            guard let start = block.range(of: "-----BEGIN CERTIFICATE-----") else { continue }
            let b64 = block[start.upperBound...].components(separatedBy: .whitespacesAndNewlines).joined()
            guard let der = Data(base64Encoded: b64) else { continue }
            let sha = Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
            guard shas.contains(sha), let cert = SecCertificateCreateWithData(nil, der as CFData) else { continue }
            let serialData = SecCertificateCopySerialNumberData(cert, nil) as Data? ?? Data()
            let serial = Self.normalizeSerial(serialData.map { String(format: "%02X", $0) }.joined())
            var cn: CFString?
            SecCertificateCopyCommonName(cert, &cn)
            guard !result.contains(where: { $0.sha1 == sha }) else { continue }
            result.append(Identity(sha1: sha, serial: serial, commonName: (cn as String?) ?? "Certificate",
                                   expires: Self.notAfter(der)))
        }
        return result
    }

    static func normalizeSerial(_ s: String) -> String {
        let up = s.uppercased().filter { $0.isHexDigit }
        let trimmed = up.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func notAfter(_ der: Data) -> Date? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cer")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? der.write(to: tmp)) != nil,
              let out = try? Shell.run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", tmp.path, "-noout", "-enddate"]) else { return nil }
        let s = String(decoding: out, as: UTF8.self).replacingOccurrences(of: "notAfter=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        return f.date(from: s.replacingOccurrences(of: "  ", with: " "))
    }

    /// Generates a key + CSR, has App Store Connect issue an Apple Distribution certificate, and imports it.
    func createDistributionIdentity(using client: ASCClient) async throws {
        try await createIdentity(type: "DISTRIBUTION", name: "SelfStore Distribution", backup: backupP12,
                                 passwordAccount: "distribution-p12-password", using: client)
    }

    var developerIDBackupP12: URL { dir.appendingPathComponent("developer-id.p12") }

    // MARK: Certificate requests (for certificates made on developer.apple.com)

    /// Private key waiting for the certificate Apple issues for its signing request.
    var pendingKey: URL { dir.appendingPathComponent("requests/pending.key") }
    var hasPendingRequest: Bool { FileManager.default.fileExists(atPath: pendingKey.path) }

    /// Writes a certificate signing request to `url`. Reuses the pending key if there is one, so a
    /// request saved twice still matches the certificate Apple issues for either copy.
    func writeSigningRequest(to url: URL) throws {
        let fm = FileManager.default
        let requests = pendingKey.deletingLastPathComponent()
        try fm.createDirectory(at: requests, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !hasPendingRequest {
            try Shell.run("/usr/bin/openssl", ["genrsa", "-out", pendingKey.path, "2048"])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingKey.path)
        }
        try Shell.run("/usr/bin/openssl", ["req", "-new", "-key", pendingKey.path, "-out", url.path,
                                           "-subj", "/CN=SelfStore/O=SelfStore/C=US"])
    }

    struct CertificateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Pairs a certificate downloaded from developer.apple.com (.cer, DER or PEM) with the pending key and imports
    /// the identity into this keychain. Returns the certificate's name.
    @discardableResult
    func importCertificate(_ cer: URL) throws -> String {
        guard hasPendingRequest else {
            throw CertificateError(message: "There's no signing request from this Mac waiting for a certificate. Click Save Signing Request…, upload it on developer.apple.com, then drop the certificate you download.")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("selfstore-cer-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let pem = work.appendingPathComponent("cert.pem")
        if (try? Shell.run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", cer.path, "-out", pem.path])) == nil {
            do { try Shell.run("/usr/bin/openssl", ["x509", "-inform", "PEM", "-in", cer.path, "-out", pem.path]) }
            catch { throw CertificateError(message: "\(cer.lastPathComponent) isn't a certificate.") }
        }
        let certKey = try Shell.run("/usr/bin/openssl", ["x509", "-in", pem.path, "-noout", "-pubkey"])
        let ourKey = try Shell.run("/usr/bin/openssl", ["pkey", "-in", pendingKey.path, "-pubout"])
        guard certKey == ourKey else {
            throw CertificateError(message: "\(cer.lastPathComponent) wasn't issued for this Mac's latest signing request. Upload the request SelfStore saved and drop the certificate Apple gives you for it.")
        }
        let subject = String(decoding: try Shell.run("/usr/bin/openssl", ["x509", "-in", pem.path, "-noout", "-subject"]), as: UTF8.self)
        let name = subject.firstMatch(of: /CN\s*=\s*([^\/,\n]+)/).map { String($0.1).trimmingCharacters(in: .whitespaces) } ?? "Certificate"

        let pw = Settings.newToken()
        let p12 = work.appendingPathComponent("id.p12")
        try Shell.run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", pendingKey.path, "-in", pem.path, "-out", p12.path,
                                           "-passout", "pass:\(pw)", "-name", name])
        try importP12(p12, password: pw)
        // Keep a backup next to the others so it can be moved to Xcode or another Mac.
        let isDeveloperID = name.hasPrefix("Developer ID")
        let backup = isDeveloperID ? developerIDBackupP12 : dir.appendingPathComponent("distribution-imported.p12")
        try? fm.removeItem(at: backup)
        try fm.copyItem(at: p12, to: backup)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        SecretStore.set(isDeveloperID ? "developer-id-p12-password" : "distribution-imported-p12-password", Data(pw.utf8))
        try fm.removeItem(at: pendingKey)
        return name
    }

    /// Same, for a Developer ID Application certificate (Mac apps outside the Mac App Store).
    func createDeveloperIDIdentity(using client: ASCClient) async throws {
        func create(_ type: String) async throws {
            try await createIdentity(type: type, name: "SelfStore Developer ID", backup: developerIDBackupP12,
                                     passwordAccount: "developer-id-p12-password", using: client)
        }
        do {
            do { try await create("DEVELOPER_ID_APPLICATION_G2") }
            // Older accounts/API versions only accept the original type.
            catch let e as ASCError where [400, 409, 422].contains(e.status) { try await create("DEVELOPER_ID_APPLICATION") }
        } catch let e as ASCError where e.status == 403 {
            throw ASCError(status: 403, message: "Apple only lets the Account Holder create Developer ID certificates, not API keys. Create one in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application, then click Refresh in SelfStore.")
        }
    }

    private func createIdentity(type: String, name: String, backup: URL, passwordAccount: String, using client: ASCClient) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("selfstore-cert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let key = work.appendingPathComponent("key.pem"), csr = work.appendingPathComponent("csr.pem")
        try Shell.run("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", csr.path,
                                           "-subj", "/CN=SelfStore/O=SelfStore/C=US"])
        let (_, der) = try await client.createCertificate(type: type, csrPEM: try String(contentsOf: csr, encoding: .utf8))
        let cer = work.appendingPathComponent("cert.cer"), pem = work.appendingPathComponent("cert.pem")
        try der.write(to: cer)
        try Shell.run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", cer.path, "-out", pem.path])
        let p12pw = Settings.newToken()
        let p12 = work.appendingPathComponent("id.p12")
        try Shell.run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key.path, "-in", pem.path, "-out", p12.path,
                                           "-passout", "pass:\(p12pw)", "-name", name])
        try importP12(p12, password: p12pw)
        // Keep a backup so the identity can be exported to Xcode or another Mac.
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: p12, to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        SecretStore.set(passwordAccount, Data(p12pw.utf8))
    }
}
