import AppKit
import SwiftUI

/// Where project builds go: the default in Application Support, or a folder of the user's (e.g. on an external drive).
struct BuildsFolderSection: View {
    @State private var settings = Settings.shared
    @State private var projects = ProjectStore.shared
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Folder") {
                HStack {
                    if projects.movingBuilds { ProgressView().controlSize(.small) }
                    Text(settings.usesCustomBuildsFolder ? settings.buildsRoot.path : "Default (Application Support)")
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(settings.buildsRootAvailable ? .primary : Color.red)
                }
            }
            if !settings.buildsRootAvailable {
                Text("This folder isn't available. Connect its drive, or choose another folder.")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Choose…", action: choose)
                Button("Use Default") { change(nil) }.disabled(!settings.usesCustomBuildsFolder)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([settings.buildsRoot])
                }.disabled(!settings.buildsRootAvailable)
            }
            .disabled(projects.movingBuilds || projects.isBusy)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Builds")
        } footer: {
            Text("Project builds (Xcode's DerivedData, logs and Mac .dmg/.zip files) are kept here and can take several GB. Changing the folder moves the existing builds. Published apps stay in Application Support.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose where SelfStore keeps project builds"
        if panel.runModal() == .OK, let url = panel.url { change(url) }
    }

    private func change(_ url: URL?) {
        error = nil
        Task {
            do { try await projects.setBuildsFolder(url) } catch { self.error = error.localizedDescription }
        }
    }
}

struct SettingsView: View {
    @State private var settings = Settings.shared
    @State private var tailscale = TailscaleManager.shared
    @State private var server = ServerController.shared
    @State private var launchAtLogin = Settings.shared.launchAtLogin
    @State private var revealToken = false

    var body: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                Text("When hidden, open SelfStore again from Finder or Spotlight to get back here.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in settings.launchAtLogin = v }
            }
            Section("Sharing") {
                LabeledContent("Local server", value: "\(server.state) · port \(settings.httpPort)")
                LabeledContent("Bonjour", value: "\(server.macName) (\(SelfStoreConstants.bonjourType))")
                Toggle("Share over Tailscale (required for installs)", isOn: $settings.shareOverTailscale)
                    .onChange(of: settings.shareOverTailscale) { Task { await tailscale.sync() } }
                LabeledContent("Tailscale") {
                    HStack {
                        Text(tailscale.baseURL?.absoluteString ?? tailscale.status).textSelection(.enabled)
                        if tailscale.busy { ProgressView().controlSize(.small) }
                    }
                }
                Button("Re-check Tailscale") { Task { await tailscale.sync() } }
            }
            SigningSection()
            BundleIDSection()
            BuildsFolderSection()
            Section("Agent API") {
                LabeledContent("Upload", value: "POST \(server.localhostURL.absoluteString)/api/apps")
                LabeledContent("Token") {
                    HStack {
                        Text(revealToken ? settings.apiToken : String(repeating: "•", count: 16))
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button(revealToken ? "Hide" : "Show") { revealToken.toggle() }
                        Button("Copy") { copyToPasteboard(settings.apiToken) }
                    }
                }
                Text("Requests from this Mac need no token. Other machines on the tailnet send “Authorization: Bearer <token>”.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy Agent Instructions") { copyToPasteboard(AgentDocs.markdown(server)) }
                    Button("Regenerate Token") { settings.apiToken = Settings.newToken() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 480)
    }
}
