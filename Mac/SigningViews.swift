import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Signing: App Store Connect API key, distribution certificate, devices.
struct SigningSection: View {
    @State private var signing = SigningManager.shared
    @State private var tailscale = TailscaleManager.shared
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var p8: String?
    @State private var p8Name: String?
    @State private var error: String?
    @State private var working = false
    @State private var p12URL: URL?
    @State private var p12Password = ""
    @State private var manualUDID = ""
    @State private var manualName = ""

    var body: some View {
        Section {
            if signing.credentials == nil { setup } else { configured }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        } header: {
            Text("Signing")
        } footer: {
            Text("With an App Store Connect API key, SelfStore registers iPhones, creates ad hoc profiles and re-signs every upload so it installs on all registered devices. It can also upload any build to TestFlight, and sign and notarize Mac app projects as .dmg and .zip. The key is kept in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Not configured

    @ViewBuilder private var setup: some View {
        HStack {
            Text("1. Create a key with the App Manager role")
            Spacer()
            Button("Open App Store Connect") {
                NSWorkspace.shared.open(URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)
            }
        }
        HStack {
            Text("2. Choose the downloaded .p8")
            Spacer()
            if let p8Name { Text(p8Name).foregroundStyle(.secondary).lineLimit(1) }
            Button("Choose…") { chooseP8() }
        }
        TextField("Key ID", text: $keyID)
        TextField("Issuer ID", text: $issuerID, prompt: Text("Shown above the keys list"))
        HStack {
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button("Connect") { connect() }
                .disabled(p8 == nil || keyID.isEmpty || issuerID.isEmpty || working)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func chooseP8() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        p8 = text
        p8Name = url.lastPathComponent
        // AuthKey_ABC123DEFG.p8 → key ID
        if let m = url.lastPathComponent.firstMatch(of: /AuthKey_([A-Z0-9]+)\.p8/) { keyID = String(m.1) }
    }

    private func connect() {
        guard let p8 else { return }
        run { try await signing.importKey(p8: p8, keyID: keyID, issuerID: issuerID) }
    }

    // MARK: Configured

    @ViewBuilder private var configured: some View {
        LabeledContent("API key") {
            HStack {
                Text(signing.credentials?.keyID ?? "").font(.system(.body, design: .monospaced))
                Button("Remove", role: .destructive) { signing.removeKey() }
            }
        }
        LabeledContent("Status") {
            HStack {
                if signing.busy != nil || working { ProgressView().controlSize(.small) }
                Text(signing.busy ?? signing.status)
            }
        }
        if let e = signing.lastError { Text(e).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }

        if let id = signing.identity {
            LabeledContent("Certificate", value: "\(id.commonName)\(id.expires.map { " · expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
        } else {
            LabeledContent("Certificate") {
                HStack {
                    Button("Create Distribution Certificate") { run { try await signing.createCertificate() } }
                    Button("Import .p12…") { chooseP12() }
                }
            }
        }

        if let dev = signing.developerID {
            LabeledContent {
                Text("\(dev.commonName)\(dev.expires.map { " · expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
            } label: {
                Text("Developer ID")
                if dev.inLoginKeychain { Text("From your login keychain").font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            LabeledContent {
                HStack {
                    Button("Refresh") { Task { await signing.refresh() } }
                    Button("Import .p12…") { chooseP12() }
                }
            } label: {
                Text("Developer ID")
                Text("Signs and notarizes Mac app builds. Apple only lets the Account Holder create one: Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application, then click Refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        if let p12URL {
            HStack {
                SecureField("Password for \(p12URL.lastPathComponent)", text: $p12Password)
                Button("Import") {
                    let url = p12URL, pw = p12Password
                    run { try await signing.importP12(url, password: pw); self.p12URL = nil; p12Password = "" }
                }
            }
        }

        Toggle("Re-sign uploads for all registered devices", isOn: $signing.resignUploads)

        DisclosureGroup("Devices (\(signing.devices.count))") {
            ForEach(signing.devices) { d in
                LabeledContent(d.name, value: d.model ?? d.deviceClass.capitalized)
            }
            HStack {
                TextField("UDID", text: $manualUDID)
                TextField("Name", text: $manualName).frame(width: 120)
                Button("Register") {
                    let u = manualUDID, n = manualName
                    run { try await signing.registerDevice(udid: u, name: n); manualUDID = ""; manualName = "" }
                }.disabled(manualUDID.isEmpty)
            }
        }

        if let base = tailscale.baseURL {
            LabeledContent("iPhone registration") {
                HStack {
                    Text("\(base.absoluteString)/register").textSelection(.enabled).lineLimit(1)
                    Button("Copy") { copyToPasteboard("\(base.absoluteString)/register") }
                }
            }
        }
        if let progress = signing.resignProgress {
            HStack { ProgressView().controlSize(.small); Text(progress) }
        }
        HStack {
            Button("Refresh") { Task { await signing.refresh() } }
            Button("Re-sign Latest Versions") { signing.resignAllInBackground() }
                .disabled(!signing.isReady || signing.resignProgress != nil)
        }
        .task { if signing.identity == nil && signing.busy == nil { await signing.refresh() } }
    }

    private func chooseP12() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "p12") ?? .data]
        if panel.runModal() == .OK { p12URL = panel.url }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
