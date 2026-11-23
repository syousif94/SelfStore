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
                        AppsSection()
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

private struct SourceNotices: View {
    @Environment(StoreModel.self) private var store
    let serverID: UUID
    var showName = false

    var body: some View {
        let state = store.state(serverID)
        let name = store.server(serverID)?.name ?? "the Mac"
        if let err = state.error {
            Label(err, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.red)
        } else if let info = state.info, !info.installsAvailable {
            Label("Installs need Tailscale. Turn on sharing in SelfStore on \(info.name).", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
        } else if let p = state.projects.first(where: { !$0.isMac }), !p.signingReady {
            Label(showName ? "Signing isn't set up on \(name), so its builds won't install yet."
                           : "Signing isn't set up on this Mac, so builds won't install yet.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
        }
    }
}

/// One entry in the unified list: an app (with every project that builds it, iOS and Mac), or a project with nothing installable yet.
enum StoreItem: Identifiable {
    case app(CatalogApp, [CatalogProject], server: UUID)
    case project(CatalogProject, server: UUID)

    var id: String {
        switch self {
        case .app(let a, _, let s): "\(s):app:\(a.bundleId)"
        case .project(let p, let s): "\(s):project:\(p.id)"
        }
    }

    var date: Date {
        switch self {
        case .app(let a, let ps, _): ([a.latest?.uploadedAt] + ps.map(\.startedAt)).compactMap { $0 }.max() ?? .distantPast
        case .project(let p, _): p.startedAt ?? .distantPast
        }
    }

    /// The projects that build `app`: iOS projects publishing to it, plus Mac projects from the same
    /// Xcode project or repo branch, or whose bundle ID matches or extends the app's (com.x.App.mac).
    static func projects(for app: CatalogApp, in state: SourceState) -> [CatalogProject] {
        let ios = state.projects.filter { !$0.isMac && $0.bundleId == app.bundleId }
        let mac = state.projects.filter { p in
            guard p.isMac else { return false }
            if let b = p.bundleId, b == app.bundleId || b.hasPrefix(app.bundleId + ".") { return true }
            return ios.contains { i in
                if let r = i.repoId { return r == p.repoId && i.branch == p.branch && i.fileName == p.fileName }
                return p.repoId == nil && i.fileName == p.fileName
            }
        }
        return ios + mac
    }

    /// Apps carry the iOS projects that publish to them (for the row's build ring and hold-to-build).
    /// Every other project (Mac apps, projects never built) is listed on its own under Projects.
    static func items(_ state: SourceState, server: UUID) -> (apps: [StoreItem], projects: [StoreItem]) {
        var claimed = Set<String>()
        let apps = state.apps.map { app in
            let ps = state.projects.filter { !$0.isMac && $0.bundleId == app.bundleId }
            claimed.formUnion(ps.map(\.id))
            return StoreItem.app(app, ps, server: server)
        }
        let loose = state.projects.filter { !claimed.contains($0.id) }.map { StoreItem.project($0, server: server) }
        return (apps, loose)
    }
}

/// Every Mac's apps in one section and the projects that aren't an installable app (Mac apps, never built) in another,
/// each newest activity first.
private struct AppsSection: View {
    @Environment(StoreModel.self) private var store

    var body: some View {
        let all = store.servers.map { StoreItem.items(store.state($0.id), server: $0.id) }
        let apps = all.flatMap(\.apps).sorted { $0.date > $1.date }
        let projects = all.flatMap(\.projects).sorted { $0.date > $1.date }
        let multipleMacs = store.servers.count > 1
        Section {
            ForEach(store.servers) { SourceNotices(serverID: $0.id, showName: multipleMacs) }
            ForEach(apps) { row($0, multipleMacs) }
            if apps.isEmpty && projects.isEmpty && store.servers.allSatisfy({ store.state($0.id).loadedOnce && store.state($0.id).error == nil }) {
                Text("No apps yet. Upload an .ipa or add a git repo with the + button, or add an Xcode project in SelfStore on the Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        if !projects.isEmpty {
            Section {
                ForEach(projects) { row($0, multipleMacs) }
            } header: {
                Text("Projects")
            } footer: {
                Text("Mac apps and projects that haven't been built yet. iPhone projects move up to Apps after their first build.")
            }
        }
    }

    @ViewBuilder private func row(_ item: StoreItem, _ multipleMacs: Bool) -> some View {
        switch item {
        case .app(let app, let projects, let serverID):
            NavigationLink(value: SourceRef(server: serverID, id: app.bundleId)) {
                AppRow(app: app, projects: projects, serverID: serverID, showMac: multipleMacs)
            }
        case .project(let p, let serverID):
            NavigationLink(value: ProjectRef(ref: SourceRef(server: serverID, id: p.id))) {
                ProjectRow(project: p, serverID: serverID, showMac: multipleMacs)
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

private struct AppRow: View {
    @Environment(StoreModel.self) private var store
    let app: CatalogApp
    let projects: [CatalogProject]
    let serverID: UUID
    var showMac = false

    @State private var error: String?

    private var active: CatalogProject? { projects.first(where: \.isActive) }
    /// The project holding Install builds: the most recently built one.
    private var project: CatalogProject? { projects.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) } }

    var body: some View {
        HStack(spacing: 14) {
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
                    (Text(v.uploadedAt, format: .relative(presentation: .named))
                     + Text(showMac ? " · \(store.server(serverID)?.name ?? "")" : ""))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .contextMenu { menu }
            // Install by default; hold it to build. While a build runs, a spinning ring around a stop button cancels it.
            if let p = active {
                BuildButton(project: p, serverID: serverID)
            } else if let v = app.latest {
                InstallButton(version: v, onHold: project.map { p in
                    { Task {
                        do { try await store.build(p, on: serverID) }
                        catch { self.error = error.localizedDescription }
                    } }
                })
            }
        }
        .padding(.vertical, 4)
        .alert("Couldn't Start Build", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var menu: some View {
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

private struct ProjectRow: View {
    @Environment(StoreModel.self) private var store
    let project: CatalogProject
    let serverID: UUID
    var showMac = false

    var body: some View {
        HStack(spacing: 14) {
            ProjectIcon(url: store.url(project.iconPath, on: serverID), size: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.headline).lineLimit(1)
                Text([project.fileName, project.isMac ? "Mac app" : nil, showMac ? store.server(serverID)?.name : nil]
                        .compactMap { $0 }.joined(separator: " · "))
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
    /// Holding the button runs this instead of installing (the list uses it to start a build).
    var onHold: (() -> Void)? = nil
    @State private var held = false
    @State private var holds = 0

    var body: some View {
        Button(title) {
            // The release that ends a hold also "taps"; swallow it.
            if held { held = false; return }
            store.install(version)
        }
        .font(.subheadline.bold())
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(version.installURL == nil && onHold == nil)
        .opacity(version.installURL == nil && onHold != nil ? 0.5 : 1)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onChanged { _ in held = false }
                .onEnded { _ in held = true; holds += 1; onHold?() },
            isEnabled: onHold != nil)
        .sensoryFeedback(.impact(weight: .medium), trigger: holds)
        .accessibilityAction(named: "Build") { onHold?() }
    }
}

// MARK: - Details

struct AppDetailView: View {
    @Environment(StoreModel.self) private var store
    let ref: SourceRef
    @State private var error: String?

    var body: some View {
        if let app = store.state(ref.server).apps.first(where: { $0.bundleId == ref.id }) {
            let projects = StoreItem.projects(for: app, in: store.state(ref.server))
            // The header's Build button: the running build, else the most recently built iOS project.
            let primary = projects.first(where: \.isActive)
                ?? projects.filter { !$0.isMac }.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            List {
                Section {
                    HStack(spacing: 16) {
                        AppIcon(url: store.url(app.iconPath ?? app.latest?.iconPath, on: ref.server), size: 96)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.title2.bold())
                            if let v = app.latest {
                                Text("Version \(v.displayVersion)").foregroundStyle(.secondary)
                            }
                            HStack(spacing: 10) {
                                if let v = app.latest { InstallButton(version: v) }
                                if let p = primary { BuildButton(project: p, serverID: ref.server) }
                            }
                            .padding(.top, 6)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 4)
                }
                if let v = app.latest, let notes = v.notes {
                    Section("What's New") { Text(notes) }
                }
                if !projects.isEmpty {
                    Section {
                        ForEach(projects) { p in
                            HStack(spacing: 12) {
                                NavigationLink(value: ProjectRef(ref: SourceRef(server: ref.server, id: p.id))) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(([p.name] + [p.branch, p.isMac ? "Mac" : nil].compactMap { $0 }).joined(separator: " · "))
                                            .font(.subheadline.weight(.semibold))
                                        BuildStatusLine(project: p)
                                    }
                                }
                                BuildButton(project: p, serverID: ref.server)
                            }
                        }
                    } header: {
                        Text("Build")
                    } footer: {
                        Text(projects.contains(where: \.isMac)
                             ? "\(store.server(ref.server)?.name ?? "The Mac") builds each project. iPhone builds are signed for your devices and added here as new versions; Mac builds are downloads on their project page."
                             : "\(store.server(ref.server)?.name ?? "The Mac") builds the project, signs it for your devices and adds it here as a new version.")
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

/// Settings of one Mac that can be changed from the phone.
struct MacSettingsView: View {
    @Environment(StoreModel.self) private var store
    let server: UUID
    @State private var prefix = ""
    @State private var rename = true
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false

    private var trimmed: String { prefix.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces)) }
    private var changed: Bool { trimmed != store.savedPrefix(on: server) || rename != store.renamesByDefault(on: server) }

    var body: some View {
        Form {
            if !store.canWrite(on: server) {
                Section {
                    Label("Changing settings needs the Mac's Tailscale address. Turn on Tailscale sharing in SelfStore on the Mac.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            Section {
                TextField("Prefix", text: $prefix, prompt: Text("com.example"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Toggle("Move uploads, repo apps and builds to this prefix", isOn: $rename)
            } header: {
                Text("Bundle ID Prefix")
            } footer: {
                if !BundlePrefixSection.isValid(prefix) {
                    Text("Use letters, digits and hyphens, separated by dots.").foregroundStyle(.red)
                } else {
                    Text("Apps from other developers carry bundle IDs registered to their team. With a prefix, com.someone.App becomes \(trimmed.isEmpty ? "com.example" : trimmed).App so it can be signed with this Mac's team.")
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(store.server(server)?.name ?? "Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button(saved && !changed ? "Saved" : "Save") { save() }
                        .disabled(!changed || !BundlePrefixSection.isValid(prefix) || !store.canWrite(on: server))
                }
            }
        }
        .onChange(of: store.state(server).info, initial: true) { load() }
        .onChange(of: prefix) { saved = false }
        .onChange(of: rename) { saved = false }
    }

    private func load() {
        guard !loaded, store.state(server).info != nil else { return }
        loaded = true
        prefix = store.savedPrefix(on: server)
        rename = store.renamesByDefault(on: server)
    }

    private func save() {
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                try await store.updateBundlePrefix(trimmed, rename: rename, on: server)
                prefix = store.savedPrefix(on: server)
                saved = true
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MacsView: View {
    @Environment(StoreModel.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.servers) { s in
                        let state = store.state(s.id)
                        NavigationLink { MacSettingsView(server: s.id) } label: {
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
