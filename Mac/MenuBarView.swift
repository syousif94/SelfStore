import AppKit
import SwiftUI

/// Menu bar panel styled after the system Wi‑Fi / Bluetooth menus: a header with a switch,
/// small section titles, rows with circular glyphs and a rounded hover highlight.
struct MenuBarView: View {
    @State private var library = AppLibrary.shared
    @State private var projects = ProjectStore.shared
    @State private var repos = RepoStore.shared
    @State private var server = ServerController.shared
    @State private var tailscale = TailscaleManager.shared
    @State private var settings = Settings.shared
    @State private var signing = SigningManager.shared

    private let maxApps = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MenuDivider()

            let items = SidebarItem.all(library: library, projects: projects)
            MenuSectionTitle("Apps")
            if items.isEmpty {
                MenuNote("No apps yet. Agents upload with POST /api/apps.")
            }
            ForEach(items.prefix(maxApps)) { item in
                switch item {
                case .app(let app, let builders): AppMenuRow(app: app, builders: builders)
                case .project(let p): ProjectMenuRow(project: p)
                }
            }

            if !repos.repos.isEmpty {
                MenuSectionTitle("Repos")
                ForEach(repos.repos) { r in RepoMenuRow(repo: r) }
            }

            MenuSectionTitle("Signing")
            MenuRow(action: { WindowManager.shared.show(.settings) }) {
                MenuGlyph(symbol: signing.isReady ? "checkmark.seal.fill" : "seal", active: signing.isReady)
            } title: {
                signing.isReady ? "Ad Hoc Signing" : "Signing Not Set Up"
            } subtitle: {
                signing.credentials == nil ? "Add an App Store Connect key" : (signing.resignProgress ?? signing.status)
            }

            MenuDivider()
            MenuRow(action: { NSWorkspace.shared.open(tailscale.baseURL ?? server.localhostURL) }) { EmptyView() } title: { "Open Store Page" }
            MenuRow(action: {
                copyToPasteboard(server.getAppURL)
                server.noteEvent("Copied the SelfStore iPhone app link")
                dismissMenuPanel()
            }) { EmptyView() } title: {
                "Copy iPhone App Install Link"
            } subtitle: {
                server.iOSApp == nil ? "Build or upload SelfStore for iPhone first" : ""
            }
            .disabled(server.iOSApp == nil)
            .opacity(server.iOSApp == nil ? 0.5 : 1)
            MenuRow(action: { LibrarySelection.shared.show(nil) }) { EmptyView() } title: { "App Library" }
            MenuRow(action: { WindowManager.shared.show(.settings) }) { EmptyView() } title: { "Settings" }
            MenuRow(action: { NSApp.terminate(nil) }) { EmptyView() } title: { "Quit" }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
        .frame(width: 300)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("SelfStore").font(.system(size: 13, weight: .bold))
                Spacer()
                Toggle("", isOn: $settings.shareOverTailscale)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .onChange(of: settings.shareOverTailscale) { Task { await tailscale.sync() } }
                    .help("Share over Tailscale (needed for installs)")
            }
            Text(statusLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .padding(.top, 3)
        .padding(.bottom, 6)
    }

    private var statusLine: String {
        if server.state != "Running" { return server.state }
        if let ts = tailscale.baseURL { return ts.host ?? ts.absoluteString }
        return settings.shareOverTailscale ? tailscale.status : "Installs off · local network only"
    }
}

private struct AppMenuRow: View {
    let app: StoredApp
    let builders: [StoredProject]
    @State private var library = AppLibrary.shared
    @State private var projects = ProjectStore.shared

    private var building: StoredProject? { builders.first { projects.isActive($0.id) } }

    var body: some View {
        MenuRow(action: { LibrarySelection.shared.show("app:\(app.bundleId)") }) {
            AppIconView(url: app.versions.first(where: \.hasIcon).map(library.iconURL), size: 26)
        } title: {
            app.name
        } subtitle: {
            if let b = building { b.lastBuild?.step ?? "Building…" }
            else if let e = builders.compactMap({ $0.lastBuild?.state == .failed ? $0.lastBuild?.error : nil }).first { e }
            else { app.latest.displayVersion }
        } trailing: {
            if building != nil {
                BuildingRing(size: 16, showsStop: false)
            } else if builders.contains(where: { $0.lastBuild?.state == .failed }) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            } else if app.versions.count > 1 {
                Text("\(app.versions.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .help(building != nil ? "Building…" : "Show in the Library")
    }
}

private struct RepoMenuRow: View {
    let repo: StoredRepo
    @State private var repos = RepoStore.shared
    @State private var projects = ProjectStore.shared

    private var busy: Bool {
        repos.isPulling(repo.id) || repo.targets.compactMap(\.projectId).contains(where: projects.isActive)
    }

    var body: some View {
        MenuRow(action: {
            if busy { LibrarySelection.shared.show("repo:\(repo.id)") } else { repos.pull(repo.id, build: .changed) }
        }) {
            MenuGlyph(symbol: "arrow.triangle.branch", active: busy)
        } title: {
            repo.name
        } subtitle: {
            if repos.isPulling(repo.id) { repo.step ?? "Pulling…" }
            else if let e = repo.error { e }
            else if busy { "Building…" }
            else { repo.lastPull.map { "Pulled \($0.formatted(.relative(presentation: .named)))" } ?? "Click to pull and build" }
        } trailing: {
            if busy { BuildingRing(size: 16, showsStop: false) }
            else if repo.error != nil { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
        }
        .help(busy ? "Working…" : "Click to pull and build what changed")
    }
}

private struct ProjectMenuRow: View {
    let project: StoredProject
    @State private var projects = ProjectStore.shared

    private var state: BuildRecord.State? { project.lastBuild?.state }
    private var active: Bool { [.queued, .building, .signing].contains(state) }

    var body: some View {
        MenuRow(action: {
            if active { LibrarySelection.shared.show("project:\(project.id)") } else { try? projects.build(project.id) }
        }) {
            MenuGlyph(symbol: "hammer.fill", active: active)
        } title: {
            project.name
        } subtitle: {
            subtitle
        } trailing: {
            if active {
                BuildingRing(size: 16, showsStop: false)
            } else if state == .succeeded {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if state == .failed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        }
        .help(active ? "Building…" : "Click to build and publish")
    }

    private var subtitle: String {
        guard let b = project.lastBuild else { return "Click to build" }
        switch b.state {
        case .queued, .building, .signing: return b.step ?? "Building…"
        case .succeeded: return "Built \(b.finishedAt?.formatted(.relative(presentation: .named)) ?? "")"
        case .failed: return b.error ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Menu primitives

struct MenuRow<Leading: View, Trailing: View>: View {
    let action: () -> Void
    @ViewBuilder let leading: Leading
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    init(action: @escaping () -> Void, @ViewBuilder leading: () -> Leading,
         title: () -> String, subtitle: (() -> String)? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.action = action
        self.leading = leading()
        self.title = title()
        self.subtitle = subtitle?()
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                leading
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 13)).lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 9)
            .padding(.vertical, Leading.self == EmptyView.self ? 4 : 3)
            .frame(maxWidth: .infinity, minHeight: Leading.self == EmptyView.self ? 22 : 32, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.1) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The circular glyph used by Wi‑Fi/Bluetooth rows: tinted when active, gray otherwise.
struct MenuGlyph: View {
    let symbol: String
    var active: Bool

    var body: some View {
        Circle()
            .fill(active ? Color.accentColor : Color.primary.opacity(0.1))
            .frame(width: 26, height: 26)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary.opacity(0.75)))
    }
}

struct MenuSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }
}

struct MenuNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 3)
    }
}

struct MenuDivider: View {
    var body: some View { Divider().padding(.horizontal, 9).padding(.vertical, 5) }
}
