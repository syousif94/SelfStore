import SwiftUI

/// Identifies an app or project on a particular Mac.
struct SourceRef: Hashable {
    var server: UUID
    var id: String
}

struct StoreView: View {
    @Environment(StoreModel.self) private var store
    @State private var showingMacs = false
    @State private var showingAdd = false
    @State private var showingAddRepo = false
    @State private var pickingIPA = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.servers.isEmpty {
                    WelcomeView(showingAdd: $showingAdd)
                } else {
                    List {
                        ForEach(store.servers) { server in
                            AppsSection(serverID: server.id, showHeader: store.servers.count > 1)
                        }
                        ReposSection()
                    }
                    .refreshable { await store.refreshAll() }
                }
            }
            .navigationTitle("SelfStore")
            .toolbar {
                if !store.servers.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingMacs = true } label: { Image(systemName: "desktopcomputer") }
                            .accessibilityLabel("Macs")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.servers.isEmpty {
                        Button { showingAdd = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Add Mac")
                    } else {
                        Menu {
                            Button("Upload .ipa…", systemImage: "square.and.arrow.up") { pickingIPA = true }
                            Button("Add Git Repo…", systemImage: "arrow.triangle.branch") { showingAddRepo = true }
                            Button("Add Mac…", systemImage: "desktopcomputer") { showingAdd = true }
                        } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Add")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) { AddMacView() }
            .sheet(isPresented: $showingAddRepo) { AddRepoView() }
            .sheet(item: Binding(get: { store.pendingUpload }, set: { store.pendingUpload = $0 })) { f in UploadView(file: f.url) }
            .fileImporter(isPresented: $pickingIPA, allowedContentTypes: [.ipa, .data]) { result in
                if case .success(let url) = result { store.pendingUpload = .init(url: url) }
            }
            .navigationDestination(for: RepoRef.self) { ref in RepoDetailView(ref: ref.ref) }
            .sheet(isPresented: $showingMacs) { MacsView() }
            .navigationDestination(for: SourceRef.self) { ref in AppDetailView(ref: ref) }
            .navigationDestination(for: ProjectRef.self) { ref in ProjectDetailView(ref: ref.ref) }
        }
        .task {
            await store.refreshAll()
            #if DEBUG
            // Screenshots: -debugRepo <id>, -debugApp <bundleId>, -debugUpload <file name>
            let d = UserDefaults.standard
            if let s = store.servers.first {
                if let r = d.string(forKey: "debugRepo") { path.append(RepoRef(ref: SourceRef(server: s.id, id: r))) }
                if let a = d.string(forKey: "debugApp") { path.append(SourceRef(server: s.id, id: a)) }
            }
            if let f = d.string(forKey: "debugUpload") { store.pendingUpload = .init(url: URL(fileURLWithPath: NSTemporaryDirectory() + f)) }
            #endif
        }
    }
}

struct ProjectRef: Hashable { var ref: SourceRef }

// MARK: - Sections

private struct SourceHeader: View {
    @Environment(StoreModel.self) private var store
    let serverID: UUID

    var body: some View {
        let state = store.state(serverID)
        HStack(spacing: 6) {
            Image(systemName: "desktopcomputer")
            Text(store.server(serverID)?.name ?? "Mac")
            if state.loading { ProgressView().controlSize(.mini) }
            else if state.error != nil { Image(systemName: "wifi.exclamationmark").foregroundStyle(.red) }
        }
    }
}

private struct SourceNotices: View {
    @Environment(StoreModel.self) private var store
    let serverID: UUID

    var body: some View {
        let state = store.state(serverID)
        if let err = state.error {
            Label(err, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.red)
        } else if let info = state.info, !info.installsAvailable {
            Label("Installs need Tailscale. Turn on sharing in SelfStore on \(info.name).", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
        }
    }
}

/// One entry in the unified list: an app (with the projects that build it, if any), or a project with nothing installable yet.
enum StoreItem: Identifiable {
    case app(CatalogApp, [CatalogProject])
    case project(CatalogProject)

    var id: String {
        switch self {
        case .app(let a, _): "app:\(a.bundleId)"
        case .project(let p): "project:\(p.id)"
        }
    }

    var date: Date {
        switch self {
        case .app(let a, let ps): ([a.latest?.uploadedAt] + ps.map(\.startedAt)).compactMap { $0 }.max() ?? .distantPast
        case .project(let p): p.startedAt ?? .distantPast
        }
    }

    /// Projects whose builds publish to an app are shown with that app; the rest (never built, Mac apps) stand alone.
    static func items(_ state: SourceState) -> [StoreItem] {
        let byBundle = Dictionary(grouping: state.projects.filter { !$0.isMac && $0.bundleId != nil }, by: { $0.bundleId! })
        let appIDs = Set(state.apps.map(\.bundleId))
        let apps = state.apps.map { StoreItem.app($0, byBundle[$0.bundleId] ?? []) }
        let loose = state.projects.filter { p in p.isMac || p.bundleId.map { !appIDs.contains($0) } ?? true }.map(StoreItem.project)
        return (apps + loose).sorted { $0.date > $1.date }
    }
}

private struct AppsSection: View {
    @Environment(StoreModel.self) private var store
    let serverID: UUID
    let showHeader: Bool

    var body: some View {
        let state = store.state(serverID)
        Section {
            SourceNotices(serverID: serverID)
            ForEach(StoreItem.items(state)) { item in
                switch item {
                case .app(let app, let projects):
                    NavigationLink(value: SourceRef(server: serverID, id: app.bundleId)) {
                        AppRow(app: app, projects: projects, serverID: serverID)
                    }
                case .project(let p):
                    NavigationLink(value: ProjectRef(ref: SourceRef(server: serverID, id: p.id))) {
                        ProjectRow(project: p, serverID: serverID)
                    }
                }
            }
            if state.apps.isEmpty && state.projects.isEmpty && state.error == nil && state.loadedOnce {
                Text("No apps on this Mac yet. Upload an .ipa or add a git repo with the + button, or add an Xcode project in SelfStore on the Mac.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            if showHeader { SourceHeader(serverID: serverID) }
        } footer: {
            if let p = state.projects.first(where: { !$0.isMac }), !p.signingReady {
                Text("Signing isn't set up on this Mac, so builds won't install yet.")
            }
        }
    }
}

private struct ReposSection: View {
    @Environment(StoreModel.self) private var store

    var body: some View {
        let repos = store.servers.flatMap { s in store.state(s.id).repos.map { (s.id, $0) } }
        if !repos.isEmpty {
            Section("Repos") {
                ForEach(repos, id: \.1.id) { serverID, r in
                    NavigationLink(value: RepoRef(ref: SourceRef(server: serverID, id: r.id))) {
                        RepoRow(repo: r, serverID: serverID)
                    }
                }
            }
        }
    }
}

// MARK: - Rows

private struct WelcomeView: View {
    @Binding var showingAdd: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Add Your Mac", systemImage: "shippingbox")
        } description: {
            Text("SelfStore installs and builds the apps your Macs host. Find one nearby with Bonjour, or enter its Tailscale address.")
        } actions: {
            Button("Add Mac") { showingAdd = true }.buttonStyle(.borderedProminent)
        }
    }
}

struct AppIcon: View {
    let url: URL?
    var size: CGFloat = 60

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                LinearGradient(colors: [Color(.systemGray3), Color(.systemGray)], startPoint: .top, endPoint: .bottom)
                    .overlay(Image(systemName: "app.dashed").foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

struct ProjectIcon: View {
    let url: URL?
    var size: CGFloat = 60

    var body: some View {
        if let url {
            AppIcon(url: url, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay(Image(systemName: "hammer.fill").font(.system(size: size * 0.42)).foregroundStyle(.white))
        }
    }
}

/// What the button on a row does by default (Macs ▸ Row Button).
enum RowAction: String, CaseIterable { case install, build }

private struct AppRow: View {
    @Environment(StoreModel.self) private var store
    @AppStorage("rowAction") private var rowAction = RowAction.install
    let app: CatalogApp
    let projects: [CatalogProject]
    let serverID: UUID

    private var active: CatalogProject? { projects.first(where: \.isActive) }
    /// The project the Build action uses: the most recently built one.
    private var project: CatalogProject? { projects.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) } }

    var body: some View {
        HStack(spacing: 14) {
            AppIcon(url: store.url(app.iconPath ?? app.latest?.iconPath, on: serverID), size: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.headline).lineLimit(1)
                if let v = app.latest {
                    Text("Version \(v.displayVersion)").font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                if let p = active ?? projects.first(where: { $0.state == "failed" }) {
                    BuildStatusLine(project: p)
                } else if let v = app.latest {
                    Text(v.uploadedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let p = active {
                BuildButton(project: p, serverID: serverID)
            } else if rowAction == .build, let p = project {
                BuildButton(project: p, serverID: serverID)
            } else if let v = app.latest {
                InstallButton(version: v)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let v = app.latest {
                Button("Install \(v.displayVersion)", systemImage: "arrow.down.circle") { store.install(v) }
                    .disabled(v.installURL == nil)
            }
            ForEach(projects) { p in
                if p.isActive {
                    Button("Cancel Build", systemImage: "stop.circle") { Task { try? await store.cancel(p, on: serverID) } }
                } else {
                    Button(projects.count > 1 ? "Build \(p.branch ?? p.name)" : "Build", systemImage: "hammer") {
                        Task { try? await store.build(p, on: serverID) }
                    }
                }
            }
        }
    }
}

private struct ProjectRow: View {
    @Environment(StoreModel.self) private var store
    let project: CatalogProject
    let serverID: UUID

    var body: some View {
        HStack(spacing: 14) {
            ProjectIcon(url: store.url(project.iconPath, on: serverID), size: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.headline).lineLimit(1)
                Text(project.isMac ? "\(project.fileName) · Mac" : project.fileName)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                BuildStatusLine(project: project)
            }
            Spacer(minLength: 8)
            BuildButton(project: project, serverID: serverID)
        }
        .padding(.vertical, 4)
    }
}

struct BuildStatusLine: View {
    let project: CatalogProject

    var body: some View {
        switch project.state {
        case "queued", "building", "signing":
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(project.step ?? "Building…")
            }
            .font(.caption).foregroundStyle(.tint).lineLimit(1)
        case "succeeded":
            if let f = project.finishedAt {
                (Text("Built ") + Text(f, format: .relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
            }
        case "failed":
            Text(project.error ?? "Build failed").font(.caption).foregroundStyle(.red).lineLimit(2)
        case "cancelled":
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        default:
            Text("Never built").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct BuildButton: View {
    @Environment(StoreModel.self) private var store
    let project: CatalogProject
    let serverID: UUID
    @State private var error: String?

    var body: some View {
        Group {
            if project.isActive {
                Button {
                    Task { try? await store.cancel(project, on: serverID) }
                } label: {
                    BuildingRing()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Building. Cancel build")
            } else {
                Button("Build") {
                    Task {
                        do { try await store.build(project, on: serverID) }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .font(.subheadline.bold())
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .alert("Couldn't Start Build", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct InstallButton: View {
    @Environment(StoreModel.self) private var store
    let version: CatalogVersion
    var title = "Install"

    var body: some View {
        Button(title) { store.install(version) }
            .font(.subheadline.bold())
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(version.installURL == nil)
    }
}

// MARK: - Details

struct AppDetailView: View {
    @Environment(StoreModel.self) private var store
    let ref: SourceRef
    @State private var error: String?

    var body: some View {
        if let app = store.state(ref.server).apps.first(where: { $0.bundleId == ref.id }) {
            List {
                Section {
                    HStack(spacing: 16) {
                        AppIcon(url: store.url(app.iconPath ?? app.latest?.iconPath, on: ref.server), size: 96)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.title2.bold())
                            if let v = app.latest {
                                Text("Version \(v.displayVersion)").foregroundStyle(.secondary)
                                InstallButton(version: v).padding(.top, 6)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 4)
                }
                if let v = app.latest, let notes = v.notes {
                    Section("What's New") { Text(notes) }
                }
                let projects = store.state(ref.server).projects.filter { !$0.isMac && $0.bundleId == app.bundleId }
                if !projects.isEmpty {
                    Section {
                        ForEach(projects) { p in
                            HStack(spacing: 12) {
                                NavigationLink(value: ProjectRef(ref: SourceRef(server: ref.server, id: p.id))) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.branch.map { "\(p.name) · \($0)" } ?? p.name).font(.subheadline.weight(.semibold))
                                        BuildStatusLine(project: p)
                                    }
                                }
                                BuildButton(project: p, serverID: ref.server)
                            }
                        }
                    } header: {
                        Text("Build")
                    } footer: {
                        Text("\(store.server(ref.server)?.name ?? "The Mac") builds the project, signs it for your devices and adds it here as a new version.")
                    }
                }
                if let v = app.latest, store.canUploadToTestFlight(on: ref.server) {
                    Section {
                        Button {
                            Task {
                                do { try await store.uploadToTestFlight(v, on: ref.server) }
                                catch { self.error = error.localizedDescription }
                            }
                        } label: {
                            Label("Upload \(v.displayVersion) to TestFlight", systemImage: "airplane")
                        }
                        .disabled(v.testFlight?.isActive == true)
                        if let tf = v.testFlight { TestFlightStatusView(status: tf) }
                    } header: {
                        Text("TestFlight")
                    } footer: {
                        Text("\(store.server(ref.server)?.name ?? "The Mac") signs this build for the App Store and uploads it to App Store Connect.")
                    }
                }
                Section("Versions") {
                    ForEach(app.versions) { v in VersionRow(version: v, serverID: ref.server) }
                }
                Section("Information") {
                    LabeledContent("Bundle ID", value: app.bundleId)
                    if let original = app.latest?.originalBundleId { LabeledContent("Original ID", value: original) }
                    if let source = app.latest?.source { LabeledContent("From", value: source) }
                    LabeledContent("Mac", value: store.server(ref.server)?.name ?? "")
                    if let v = app.latest {
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file))
                        if let os = v.minimumOSVersion { LabeledContent("Requires", value: "iOS \(os)") }
                        if let team = v.teamName { LabeledContent("Developer", value: team) }
                        if let exp = v.expiresAt { LabeledContent("Profile expires", value: exp.formatted(date: .abbreviated, time: .omitted)) }
                    }
                }
            }
            .navigationTitle(app.name)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh(ref.server) }
            .alert("Couldn't Upload", isPresented: .constant(error != nil), actions: { Button("OK") { error = nil } },
                   message: { Text(error ?? "") })
        } else {
            ContentUnavailableView("App Removed", systemImage: "trash")
        }
    }
}

private struct VersionRow: View {
    @Environment(StoreModel.self) private var store
    let version: CatalogVersion
    let serverID: UUID

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(version.displayVersion).font(.body.weight(.semibold))
                Text(version.uploadedAt.formatted(date: .abbreviated, time: .shortened)
                     + " · " + ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                if let exp = version.expiresAt, exp < Date() {
                    Text("Profile expired").font(.caption).foregroundStyle(.red)
                }
                if let notes = version.notes { Text(notes).font(.footnote).padding(.top, 2) }
                if let tf = version.testFlight { TestFlightStatusView(status: tf) }
            }
            Spacer()
            InstallButton(version: version, title: "Get")
        }
        .contextMenu {
            if store.canUploadToTestFlight(on: serverID) {
                Button("Upload to TestFlight", systemImage: "airplane") {
                    Task { try? await store.uploadToTestFlight(version, on: serverID) }
                }
                .disabled(version.testFlight?.isActive == true)
            }
        }
    }
}

struct TestFlightStatusView: View {
    let status: CatalogTestFlight

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if status.isActive { ProgressView().controlSize(.mini) }
                Image(systemName: status.state == "succeeded" ? "airplane.circle.fill"
                      : status.state == "failed" ? "xmark.octagon.fill" : "airplane")
                    .foregroundStyle(status.state == "failed" ? .red : .blue)
                Text(label).font(.caption)
            }
            if let e = status.error {
                Text(e).font(.caption2).foregroundStyle(status.state == "failed" ? .red : .orange)
            }
        }
    }

    private var label: String {
        switch status.state {
        case "succeeded": "Uploaded to TestFlight \((status.finishedAt ?? status.startedAt).formatted(date: .abbreviated, time: .shortened))"
        case "failed": "TestFlight upload failed"
        default: status.step ?? "Uploading to TestFlight…"
        }
    }
}

struct ProjectDetailView: View {
    @Environment(StoreModel.self) private var store
    let ref: SourceRef

    var body: some View {
        if let p = store.state(ref.server).projects.first(where: { $0.id == ref.id }) {
            List {
                Section {
                    HStack(spacing: 16) {
                        ProjectIcon(url: store.url(p.iconPath, on: ref.server), size: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p.name).font(.title2.bold())
                            Text(p.branch.map { "\(p.fileName) · \($0)" } ?? p.fileName).foregroundStyle(.secondary)
                            HStack {
                                BuildButton(project: p, serverID: ref.server)
                                if !p.isMac, p.state == "succeeded", let v = store.builtVersion(for: p, on: ref.server) {
                                    InstallButton(version: v)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Status") {
                    BuildStatusLine(project: p)
                    if let s = p.startedAt {
                        LabeledContent("Started", value: s.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let s = p.startedAt, let f = p.finishedAt {
                        LabeledContent("Took", value: Duration.seconds(f.timeIntervalSince(s))
                            .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                    }
                    if p.isMac && !p.signingReady {
                        Label("No Developer ID certificate on this Mac, so builds are signed ad hoc and not notarized.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    } else if !p.isMac && !p.signingReady {
                        Label("Signing isn't set up on this Mac, so builds won't install yet.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                if p.isMac, p.state == "succeeded", let files = p.artifacts, !files.isEmpty {
                    Section {
                        ForEach(files) { f in
                            if let url = store.url(f.path, on: ref.server) {
                                ShareLink(item: url) {
                                    LabeledContent(f.name, value: ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                                }
                            }
                        }
                        if let v = p.version { LabeledContent("Version", value: v) }
                        LabeledContent("Notarized", value: p.notarized == true ? "Yes" : "No")
                        ForEach(p.warnings ?? [], id: \.self) { w in
                            Text(w).font(.caption).foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Mac App")
                    } footer: {
                        Text("Share a download link to a Mac (AirDrop, Messages…). Links work on your tailnet.")
                    }
                }
                if let tail = p.logTail, !tail.isEmpty {
                    Section("Errors") {
                        Text(tail.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section("Information") {
                    LabeledContent("Mac", value: store.server(ref.server)?.name ?? "")
                    if let b = p.bundleId { LabeledContent("Bundle ID", value: b) }
                }
            }
            .navigationTitle(p.name)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh(ref.server) }
        } else {
            ContentUnavailableView("Project Removed", systemImage: "trash")
        }
    }
}

// MARK: - Macs

struct MacsView: View {
    @Environment(StoreModel.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("rowAction") private var rowAction = RowAction.install
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.servers) { s in
                        let state = store.state(s.id)
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.tint).frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.headline)
                                Text(status(state)).font(.caption).foregroundStyle(state.error == nil ? Color.secondary : Color.red)
                                Text((s.tailscaleURL ?? s.lanURL)?.host ?? "").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if state.info?.signingEnabled == true, s.tailscaleURL != nil {
                                Button("Register") { store.openRegistration(s.id) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .accessibilityHint("Registers this iPhone so the Mac can sign apps for it")
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { store.remove(s.id) }
                        }
                    }
                    .onDelete { idx in idx.map { store.servers[$0].id }.forEach(store.remove) }
                    .onMove { store.move(from: $0, to: $1) }
                } footer: {
                    Text("Apps and projects from every Mac show up together. “Register” adds this iPhone to a Mac's signing so its builds install here.")
                }
                Section {
                    Picker("Row Button", selection: $rowAction) {
                        Text("Install").tag(RowAction.install)
                        Text("Build").tag(RowAction.build)
                    }
                } footer: {
                    Text("What the button next to each app does. Apps that aren't built by a Mac always show Install; touch and hold any app for the other action.")
                }
            }
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .bottomBar) { Button("Add Mac", systemImage: "plus") { showingAdd = true } }
            }
            .sheet(isPresented: $showingAdd) { AddMacView() }
        }
    }

    private func status(_ s: SourceState) -> String {
        if s.error != nil { return "Unreachable" }
        if s.loading && !s.loadedOnce { return "Connecting…" }
        let apps = "\(s.apps.count) app\(s.apps.count == 1 ? "" : "s")"
        return s.projects.isEmpty ? apps : "\(apps) · \(s.projects.count) project\(s.projects.count == 1 ? "" : "s")"
    }
}

struct AddMacView: View {
    @Environment(StoreModel.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var browser = BonjourBrowser()
    @State private var address = ""
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    let added = Set(store.servers.map(\.name))
                    let macs = browser.macs.filter { !added.contains($0.name) }
                    if macs.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(browser.denied ? "Allow Local Network access in Settings to find Macs nearby."
                                                : "Looking for Macs running SelfStore…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(macs) { mac in
                        Button {
                            run(mac.name) { try await store.add(nearby: mac) }
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer").foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(mac.name).foregroundStyle(.primary)
                                    Text(mac.tailscaleURL == nil ? "Local network only" : "Local network + Tailscale")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if busy == mac.name { ProgressView() }
                            }
                        }
                    }
                } header: {
                    Text("Nearby (Bonjour)")
                }

                Section {
                    TextField("my-mac.tailnet.ts.net", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit(addManual)
                    Button("Add") { addManual() }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || busy != nil)
                } header: {
                    Text("Tailscale or Address")
                } footer: {
                    Text("Installing needs the Mac's Tailscale address (https). You can also open the Mac's SelfStore page in Safari and tap “Add this Mac to the SelfStore app”.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
        }
    }

    private func addManual() {
        let text = address
        run(text) { try await store.add(manual: text) }
    }

    private func run(_ label: String, _ work: @escaping () async throws -> Void) {
        busy = label
        error = nil
        Task {
            do { try await work(); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = nil
        }
    }
}
