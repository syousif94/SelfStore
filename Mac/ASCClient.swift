import CryptoKit
import Foundation

/// App Store Connect API key (.p8). Stored in the login Keychain by `SecretStore`.
struct ASCCredentials: Codable, Equatable, Sendable {
    var keyID: String
    var issuerID: String
    var privateKeyPEM: String
}

struct ASCError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { status > 0 ? "App Store Connect (\(status)): \(message)" : message }
}

/// Minimal App Store Connect API client: devices, bundle IDs, certificates, profiles.
struct ASCClient: Sendable {
    let creds: ASCCredentials
    private let base = URL(string: "https://api.appstoreconnect.apple.com")!

    struct Device: Identifiable, Hashable, Sendable {
        var id: String, name: String, udid: String, deviceClass: String, model: String?, status: String
    }
    struct Certificate: Hashable, Sendable {
        var id: String, name: String, serialNumber: String, expires: Date?, type: String
    }
    struct Profile: Sendable {
        var id: String, content: Data
    }

    // MARK: JWT

    func token() throws -> String {
        let key: P256.Signing.PrivateKey
        do { key = try P256.Signing.PrivateKey(pemRepresentation: creds.privateKeyPEM) }
        catch { throw ASCError(status: 0, message: "The .p8 file isn't a valid App Store Connect private key.") }
        let now = Int(Date().timeIntervalSince1970)
        let header = ["alg": "ES256", "kid": creds.keyID, "typ": "JWT"]
        let payload: [String: Any] = ["iss": creds.issuerID, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"]
        let h = try Self.b64url(JSONSerialization.data(withJSONObject: header, options: .sortedKeys))
        let p = try Self.b64url(JSONSerialization.data(withJSONObject: payload, options: .sortedKeys))
        let sig = try key.signature(for: Data("\(h).\(p)".utf8))
        return "\(h).\(p).\(Self.b64url(sig.rawRepresentation))"
    }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Transport

    @discardableResult
    func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let errs = (json["errors"] as? [[String: Any]]) ?? []
            let msg = errs.map { e in [e["title"] as? String, e["detail"] as? String].compactMap { $0 }.joined(separator: ": ") }
                .joined(separator: "; ")
            throw ASCError(status: status, message: msg.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : msg)
        }
        return json
    }

    /// Follows `links.next` pagination.
    private func list(_ path: String, query: [String: String]) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var json = try await request("GET", path, query: query.merging(["limit": "200"]) { a, _ in a })
        while true {
            items += (json["data"] as? [[String: Any]]) ?? []
            guard let next = (json["links"] as? [String: Any])?["next"] as? String, let url = URL(string: next),
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { break }
            var q: [String: String] = [:]
            for item in comps.queryItems ?? [] { q[item.name] = item.value }
            json = try await request("GET", comps.path, query: q)
        }
        return items
    }

    private static func attrs(_ item: [String: Any]) -> [String: Any] { (item["attributes"] as? [String: Any]) ?? [:] }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: Devices

    /// Enabled iPhones/iPads/iPods.
    func devices() async throws -> [Device] {
        try await list("/v1/devices", query: ["filter[platform]": "IOS", "filter[status]": "ENABLED"]).compactMap { item in
            let a = Self.attrs(item)
            let cls = a["deviceClass"] as? String ?? ""
            guard ["IPHONE", "IPAD", "IPOD"].contains(cls), let id = item["id"] as? String, let udid = a["udid"] as? String else { return nil }
            return Device(id: id, name: a["name"] as? String ?? udid, udid: udid, deviceClass: cls,
                          model: a["model"] as? String, status: a["status"] as? String ?? "")
        }
    }

    func registerDevice(name: String, udid: String) async throws {
        try await request("POST", "/v1/devices", body: [
            "data": ["type": "devices", "attributes": ["name": String(name.prefix(50)), "udid": udid, "platform": "IOS"]],
        ])
    }

    // MARK: Bundle IDs

    /// `platform` is IOS or MAC_OS. Mac lookups take any platform, since Xcode registers Mac apps as universal
    /// IDs too; a missing ID is created for `platform`.
    func bundleIDResource(for identifier: String, platform: String = "IOS") async throws -> String {
        var query = ["filter[identifier]": identifier]
        if platform == "IOS" { query["filter[platform]"] = "IOS" }
        let found = try await list("/v1/bundleIds", query: query)
        if let match = found.first(where: { (Self.attrs($0)["identifier"] as? String) == identifier }), let id = match["id"] as? String {
            return id
        }
        // Names allow letters, numbers and spaces only.
        let name = "SelfStore " + identifier.map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
        let json = try await request("POST", "/v1/bundleIds", body: [
            "data": ["type": "bundleIds", "attributes": ["identifier": identifier, "name": String(name.prefix(60)), "platform": platform]],
        ])
        guard let id = (json["data"] as? [String: Any])?["id"] as? String else { throw ASCError(status: 0, message: "No bundle ID returned") }
        return id
    }

    // MARK: Certificates

    func distributionCertificates() async throws -> [Certificate] {
        try await certificates(types: ["DISTRIBUTION", "IOS_DISTRIBUTION"])
    }

    /// Developer ID Application certificates (signing Mac apps distributed outside the Mac App Store).
    func developerIDCertificates() async throws -> [Certificate] {
        try await certificates(types: ["DEVELOPER_ID_APPLICATION_G2", "DEVELOPER_ID_APPLICATION"])
    }

    func certificates(types: [String]) async throws -> [Certificate] {
        var out: [Certificate] = []
        for type in types {
            out += try await list("/v1/certificates", query: ["filter[certificateType]": type]).compactMap { item in
                let a = Self.attrs(item)
                guard let id = item["id"] as? String else { return nil }
                return Certificate(id: id, name: a["name"] as? String ?? a["displayName"] as? String ?? "Distribution",
                                   serialNumber: a["serialNumber"] as? String ?? "",
                                   expires: Self.date(a["expirationDate"]), type: type)
            }
        }
        return out
    }

    /// Returns (certificate id, DER certificate).
    func createDistributionCertificate(csrPEM: String) async throws -> (String, Data) {
        try await createCertificate(type: "DISTRIBUTION", csrPEM: csrPEM)
    }

    func createCertificate(type: String, csrPEM: String) async throws -> (String, Data) {
        let json = try await request("POST", "/v1/certificates", body: [
            "data": ["type": "certificates", "attributes": ["certificateType": type, "csrContent": csrPEM]],
        ])
        guard let data = json["data"] as? [String: Any], let id = data["id"] as? String,
              let b64 = Self.attrs(data)["certificateContent"] as? String, let der = Data(base64Encoded: b64) else {
            throw ASCError(status: 0, message: "No certificate returned")
        }
        return (id, der)
    }

    // MARK: Profiles

    func createAdHocProfile(name: String, bundleIDResource: String, certificateID: String, deviceIDs: [String]) async throws -> Profile {
        try await createProfile(name: name, type: "IOS_APP_ADHOC", bundleIDResource: bundleIDResource,
                                certificateID: certificateID, deviceIDs: deviceIDs)
    }

    /// App Store profile (used for TestFlight uploads). Has no device list.
    func createAppStoreProfile(name: String, bundleIDResource: String, certificateID: String) async throws -> Profile {
        try await createProfile(name: name, type: "IOS_APP_STORE", bundleIDResource: bundleIDResource,
                                certificateID: certificateID, deviceIDs: [])
    }

    /// Developer ID profile for a Mac app distributed outside the Mac App Store. Mac apps only need one
    /// when they use entitlements that require a profile (iCloud, push, associated domains…).
    func createDeveloperIDProfile(name: String, bundleIDResource: String, certificateID: String) async throws -> Profile {
        try await createProfile(name: name, type: "MAC_APP_DIRECT", bundleIDResource: bundleIDResource,
                                certificateID: certificateID, deviceIDs: [])
    }

    private func createProfile(name: String, type: String, bundleIDResource: String, certificateID: String,
                               deviceIDs: [String]) async throws -> Profile {
        // Replace any older profile with the same name so the portal doesn't fill up.
        let existing = try await list("/v1/profiles", query: ["filter[name]": name])
        for p in existing where (Self.attrs(p)["name"] as? String) == name {
            if let id = p["id"] as? String { try? await request("DELETE", "/v1/profiles/\(id)") }
        }
        var relationships: [String: Any] = [
            "bundleId": ["data": ["type": "bundleIds", "id": bundleIDResource]],
            "certificates": ["data": [["type": "certificates", "id": certificateID]]],
        ]
        if !deviceIDs.isEmpty { relationships["devices"] = ["data": deviceIDs.map { ["type": "devices", "id": $0] }] }
        let json = try await request("POST", "/v1/profiles", body: [
            "data": [
                "type": "profiles",
                "attributes": ["name": name, "profileType": type],
                "relationships": relationships,
            ],
        ])
        guard let data = json["data"] as? [String: Any], let id = data["id"] as? String,
              let b64 = Self.attrs(data)["profileContent"] as? String, let content = Data(base64Encoded: b64) else {
            throw ASCError(status: 0, message: "No profile returned")
        }
        return Profile(id: id, content: content)
    }

    // MARK: Apps

    /// The App Store Connect app record for a bundle ID, if one exists. Apps can't be created through the API.
    func appRecordID(bundleID: String) async throws -> String? {
        let found = try await list("/v1/apps", query: ["filter[bundleId]": bundleID])
        return found.first { (Self.attrs($0)["bundleId"] as? String) == bundleID }?["id"] as? String
    }
}
