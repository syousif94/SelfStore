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
    @State private var savedRequest: URL?
    @State private var notice: String?
    @State private var showNewCertificate = false

    var body: some View {
        Section {
            if signing.credentials == nil { setup } else { configured }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        } header: {
            Text("Signing")
        } footer: {
            Text("With an App Store Connect API key, SelfStore registers iPhones, creates ad hoc profiles and re-signs every upload so it installs on all registered devices. It can also upload any build to TestFlight, and sign and notarize Mac app projects as .dmg and .zip. The API key and signing certificates are kept in your login keychain.")
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
                Button(showNewCertificate ? "Cancel" : "Get a New Certificate…") { showNewCertificate.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
            if showNewCertificate { newCertificateSteps }
        } else {
            LabeledContent {
                Button("Refresh") { Task { await signing.refresh() } }
            } label: {
                Text("Developer ID")
                Text("Signs and notarizes Mac app builds. Apple only lets the Account Holder create one, so it's made on developer.apple.com.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            newCertificateSteps
        }
        if let notice { Text(notice).font(.caption).foregroundStyle(.green) }

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

    /// Save a CSR → upload on developer.apple.com → drop the .cer back here.
    @ViewBuilder private var newCertificateSteps: some View {
        HStack {
            Text("1. Save a signing request")
            Spacer()
            Button(signing.hasPendingRequest ? "Save Signing Request Again…" : "Save Signing Request…") { saveRequest() }
        }
        HStack {
            Text("2. Upload it as a Developer ID Application certificate")
            Spacer()
            Button("Open developer.apple.com") {
                NSWorkspace.shared.open(URL(string: "https://developer.apple.com/account/resources/certificates/add")!)
            }
        }
        if let savedRequest {
            Text("Saved \(savedRequest.lastPathComponent). On the website choose Developer ID ▸ Developer ID Application ▸ G2 Sub-CA and upload it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        CertificateDropZone(title: "3. Drop the downloaded .cer here",
                            subtitle: "or a .p12 exported from another Mac",
                            choose: { chooseCertificate() },
                            handle: { handleDropped($0) })
    }

    private func saveRequest() {
        let panel = NSSavePanel()
        panel.title = "Save Signing Request"
        panel.message = "Upload this file on developer.apple.com to get a Developer ID Application certificate."
        panel.nameFieldStringValue = "SelfStore.certSigningRequest"
        panel.allowedContentTypes = [UTType(filenameExtension: "certSigningRequest") ?? .data]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run {
            try await signing.saveSigningRequest(to: url)
            savedRequest = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func chooseCertificate() {
        let panel = NSOpenPanel()
        panel.message = "Choose the certificate you downloaded (.cer) or an exported identity (.p12)"
        panel.allowedContentTypes = ["cer", "crt", "pem", "p12"].compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { handleDropped(url) }
    }

    private func handleDropped(_ url: URL) {
        notice = nil
        if url.pathExtension.lowercased() == "p12" {
            p12URL = url // asks for its password below
            return
        }
        run {
            let name = try await signing.importCertificate(url)
            savedRequest = nil
            showNewCertificate = false
            notice = "Added \(name)."
        }
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

/// Dashed drop target for certificate files.
private struct CertificateDropZone: View {
    let title: String
    let subtitle: String
    let choose: () -> Void
    let handle: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.seal").font(.title2).foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text(title).font(.callout.weight(.medium))
            HStack(spacing: 4) {
                Text(subtitle).foregroundStyle(.secondary)
                Button("Choose File…", action: choose).buttonStyle(.link)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(targeted ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(targeted ? Color.accentColor : .secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in handle(url) }
            }
            return true
        }
    }
}
