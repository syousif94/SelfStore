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

/// A keychain file owned by SelfStore that holds the Apple Distribution identity, so `codesign`
/// can use it without touching (or prompting about) the login keychain.
struct SigningKeychain: Sendable {
    struct Identity: Sendable, Hashable {
        var sha1: String          // codesign -s value
        var serial: String        // uppercase hex, no leading zeros
        var commonName: String
        var expires: Date?
        /// In the user's login keychain (e.g. a Developer ID made in Xcode) rather than SelfStore's own.
        var inLoginKeychain = false
    }

    let dir: URL
    var path: String { dir.appendingPathComponent("signing.keychain-db").path }
    var backupP12: URL { dir.appendingPathComponent("distribution.p12") }

    static let standard = SigningKeychain(dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SelfStore/signing", isDirectory: true))

    private var password: String {
        if let d = SecretStore.get("signing-keychain-password"), let s = String(data: d, encoding: .utf8) { return s }
        let s = Settings.newToken()
        SecretStore.set("signing-keychain-password", Data(s.utf8))
        return s
    }

    /// Creates (first time) and unlocks the keychain. Also copies Apple's WWDR intermediates in so
    /// signatures carry a complete chain.
    func prepare() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pw = password
        if !FileManager.default.fileExists(atPath: path) {
            try Shell.run("/usr/bin/security", ["create-keychain", "-p", pw, path])
            try Shell.run("/usr/bin/security", ["set-keychain-settings", path]) // never auto-lock
            try Shell.run("/usr/bin/security", ["unlock-keychain", "-p", pw, path])
            if let wwdr = try? Shell.run("/usr/bin/security", ["find-certificate", "-a", "-c", "Apple Worldwide Developer Relations", "-p"]),
               !wwdr.isEmpty {
                let tmp = dir.appendingPathComponent("wwdr.pem")
                try wwdr.write(to: tmp)
                _ = try? Shell.run("/usr/bin/security", ["import", tmp.path, "-k", path])
                try? FileManager.default.removeItem(at: tmp)
            }
        }
        try Shell.run("/usr/bin/security", ["unlock-keychain", "-p", pw, path])
    }

    /// Imports a PKCS#12 identity and allows codesign to use its key without prompting.
    func importP12(_ p12: URL, password p12pw: String) throws {
        try prepare()
        try Shell.run("/usr/bin/security", ["import", p12.path, "-k", path, "-P", p12pw, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
        try Shell.run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, path])
    }

    /// Certificates in this keychain that have a private key (i.e. usable identities).
    func identities() throws -> [Identity] {
        try prepare()
        let out = String(decoding: try Shell.run("/usr/bin/security", ["find-identity", path]), as: UTF8.self)
        var shas = Set<String>()
        for line in out.split(separator: "\n") {
            if let m = line.firstMatch(of: /\d+\)\s+([0-9A-F]{40})\s/) { shas.insert(String(m.1)) }
        }
        let pems = String(decoding: try Shell.run("/usr/bin/security", ["find-certificate", "-a", "-p", path]), as: UTF8.self)
        return Self.parse(pems: pems, shas: shas)
    }

    /// Developer ID Application identities in the user's keychains (where Xcode puts certificates it creates).
    /// codesign asks once for permission to use the key; "Always Allow" makes later builds silent.
    static func loginDeveloperIDs() throws -> [Identity] {
        let out = String(decoding: try Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]), as: UTF8.self)
        var shas = Set<String>()
        for line in out.split(separator: "\n") where line.contains("Developer ID Application") {
            if let m = line.firstMatch(of: /\d+\)\s+([0-9A-F]{40})\s/) { shas.insert(String(m.1)) }
        }
        guard !shas.isEmpty else { return [] }
        let pems = String(decoding: try Shell.run("/usr/bin/security", ["find-certificate", "-a", "-p", "-c", "Developer ID Application"]),
                          as: UTF8.self)
        return parse(pems: pems, shas: shas).map { var id = $0; id.inLoginKeychain = true; return id }
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
