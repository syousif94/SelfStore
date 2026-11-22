import Foundation
import Observation

/// Status of a TestFlight upload, stored in the version's record.json.
struct TestFlightRecord: Codable, Hashable {
    enum State: String, Codable { case queued, signing, uploading, succeeded, failed }
    var state: State
    var startedAt: Date
    var finishedAt: Date?
    var step: String?
    var error: String?

    var isActive: Bool { [.queued, .signing, .uploading].contains(state) }
}

/// Re-signs a stored build with an App Store profile and uploads it to App Store Connect with `altool`,
/// using the same API key as ad hoc signing. One upload runs at a time.
@MainActor @Observable
final class TestFlightUploader {
    static let shared = TestFlightUploader()

    private var queue: [(bundleId: String, versionId: String)] = []
    private var running = false

    private var library: AppLibrary { .shared }
    private var signing: SigningManager { .shared }

    /// Queues an upload. Throws if signing isn't ready or the version is already being uploaded.
    func upload(_ bundleId: String, _ versionId: String) throws {
        guard signing.credentials != nil else { throw ASCError(status: 0, message: "TestFlight needs an App Store Connect API key (Settings ▸ Signing)") }
        guard let v = library.version(bundleId, versionId) else { throw LibraryError.notFound }
        if v.testFlight?.isActive == true { return }
        try library.setTestFlight(bundleId, versionId, TestFlightRecord(state: .queued, startedAt: Date(), step: "Waiting…"))
        queue.append((bundleId, versionId))
        pump()
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        running = true
        Task {
            await run(next.bundleId, next.versionId)
            running = false
            pump()
        }
    }

    private func set(_ bundleId: String, _ versionId: String, _ change: (inout TestFlightRecord) -> Void) {
        guard var r = library.version(bundleId, versionId)?.testFlight else { return }
        change(&r)
        try? library.setTestFlight(bundleId, versionId, r)
    }

    private func run(_ bundleId: String, _ versionId: String) async {
        guard let v = library.version(bundleId, versionId) else { return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("selfstore-testflight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            set(bundleId, versionId) { $0.state = .signing; $0.step = "Checking App Store Connect…" }
            if !signing.isReady { await signing.refresh() }
            guard let client = signing.client, let creds = signing.credentials else {
                throw ASCError(status: 0, message: "Signing isn't set up")
            }
            guard signing.isReady else { throw ASCError(status: 0, message: "Signing isn't ready: \(signing.status)") }

            // Uploads need an app record, which only App Store Connect's website can create.
            if try await client.appRecordID(bundleID: bundleId) == nil {
                _ = try? await client.bundleIDResource(for: bundleId) // so it's offered when creating the app
                throw ASCError(status: 0, message: "There's no app for \(bundleId) in App Store Connect. Create it under Apps ▸ New App (choose bundle ID \(bundleId)), then upload again.")
            }

            set(bundleId, versionId) { $0.step = "Signing for the App Store…" }
            let ipa = work.appendingPathComponent(LibraryFileName.ipa(v))
            let report = try await signing.resign(input: library.sourceIPA(v), output: ipa, mode: .appStore, rename: v.renaming)

            set(bundleId, versionId) { $0.state = .uploading; $0.step = "Uploading to App Store Connect…" }
            try await Task.detached { try Self.altoolUpload(ipa: ipa, creds: creds, work: work) }.value

            set(bundleId, versionId) {
                $0.state = .succeeded
                $0.step = "Uploaded. App Store Connect is processing it."
                $0.error = report.warnings.isEmpty ? nil : report.warnings.joined(separator: "\n")
                $0.finishedAt = Date()
            }
            ServerController.shared.noteEvent("Uploaded \(v.name) \(v.displayVersion) to TestFlight")
        } catch {
            set(bundleId, versionId) {
                $0.state = .failed
                $0.step = nil
                $0.error = error.localizedDescription
                $0.finishedAt = Date()
            }
        }
    }

    /// Runs `xcrun altool --upload-package`. The key is written to a private temp folder only for the upload.
    nonisolated private static func altoolUpload(ipa: URL, creds: ASCCredentials, work: URL) throws {
        let fm = FileManager.default
        let keys = work.appendingPathComponent("private_keys", isDirectory: true)
        try fm.createDirectory(at: keys, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keyFile = keys.appendingPathComponent("AuthKey_\(creds.keyID).p8")
        try Data(creds.privateKeyPEM.utf8).write(to: keyFile)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        defer { try? fm.removeItem(at: keys) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["altool", "--upload-package", ipa.path, "--api-key", creds.keyID, "--api-issuer", creds.issuerID,
                       "--output-format", "json"]
        var env = ProcessInfo.processInfo.environment
        env["API_PRIVATE_KEYS_DIR"] = keys.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Shell.Failure(message: "Upload failed: " + errorMessage(out))
        }
    }

    /// Pulls readable messages out of altool's JSON output, falling back to its last lines.
    nonisolated static func errorMessage(_ out: Data) -> String {
        if let start = out.firstIndex(of: UInt8(ascii: "{")),
           let json = try? JSONSerialization.jsonObject(with: out[start...]) as? [String: Any],
           let errors = json["product-errors"] as? [[String: Any]], !errors.isEmpty {
            return errors.map { e in
                let info = e["userInfo"] as? [String: Any]
                let parts = [e["message"] as? String, info?["NSLocalizedFailureReason"] as? String]
                return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            }.joined(separator: "\n")
        }
        let lines = String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("Running altool at path") }
        return lines.suffix(8).joined(separator: "\n")
    }
}
