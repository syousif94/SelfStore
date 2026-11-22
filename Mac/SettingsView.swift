import AppKit
import SwiftUI

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
