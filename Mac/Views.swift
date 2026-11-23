import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared bits

struct AppIconView: View {
    let url: URL?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url, let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                LinearGradient(colors: [.gray, .gray.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .overlay(Image(systemName: "app.dashed").foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
    }
}

@MainActor
func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Which sidebar item the Library window shows ("app:<bundleId>" or "project:<id>").
@MainActor @Observable
final class LibrarySelection {
    static let shared = LibrarySelection()
    var selection: String?

    func show(_ item: String?) {
        if let item { selection = item }
        dismissMenuPanel()
        WindowManager.shared.show(.library)
    }
}

/// Closes the menu bar panel after a row opens a window.
@MainActor
func dismissMenuPanel() {
    for w in NSApp.windows where w.className.contains("MenuBarExtra") && w.isVisible { w.orderOut(nil) }
}

// MARK: - Library window

struct LibraryView: View {
    @State private var library = AppLibrary.shared
    @State private var projects = ProjectStore.shared
    @State private var repos = RepoStore.shared
    @State private var nav = LibrarySelection.shared
    @State private var addingRepo = false
    @State private var importing = false
    @State private var error: String?
    @State private var dropTargeted = false
    @State private var schemeChoice: SchemeChoice?

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.selection) {
                Section("Apps") {
                    ForEach(sidebarItems) { item in
                        switch item {
                        case .app(let app, let builders):
                            HStack(spacing: 10) {
                                AppIconView(url: app.versions.first(where: \.hasIcon).map(library.iconURL), size: 28)
                                VStack(alignment: .leading) {
                                    Text(app.name).lineLimit(1)
                                    Text(app.latest.displayVersion).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if builders.contains(where: { projects.isActive($0.id) }) { BuildingRing(size: 16, showsStop: false) }
                            }
                            .tag("app:\(app.bundleId)")
                            .contextMenu {
                                ForEach(builders) { p in
                                    if projects.isActive(p.id) {
                                        Button("Cancel Build") { projects.cancel(p.id) }
                                    } else {
                                        Button(builders.count > 1 ? "Build \(p.branch ?? p.name)" : "Build") { try? projects.build(p.id) }
                                    }
                                }
                                if !builders.isEmpty { Divider() }
                                if app.versions.count > 1 {
                                    Button("Delete Older Versions", role: .destructive) { _ = try? library.prune(bundleId: app.bundleId, keep: 1) }
                                }
                                Button("Delete All Versions", role: .destructive) { try? library.delete(bundleId: app.bundleId) }
                            }
                        case .project(let p):
                            HStack(spacing: 10) {
                                ProjectIcon(project: p, size: 28)
                                VStack(alignment: .leading) {
                                    Text(p.name).lineLimit(1)
                                    Text(p.isMac ? "Mac app" : p.lastBuild == nil ? "Not built yet" : p.fileName)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if projects.isActive(p.id) { BuildingRing(size: 16, showsStop: false) }
                            }
                            .tag("project:\(p.id)")
                            .contextMenu {
                                if projects.isActive(p.id) { Button("Cancel Build") { projects.cancel(p.id) } }
                                else { Button("Build") { try? projects.build(p.id) } }
                                if !p.isFromRepo { Button("Remove Project", role: .destructive) { projects.remove(p.id) } }
                            }
                        }
                    }
                    if library.apps.isEmpty && projects.projects.isEmpty {
                        Button("Add .ipa or Xcode Project…") { pickFiles() }.buttonStyle(.link)
                        Button("Add Git Repo…") { addingRepo = true }.buttonStyle(.link)
                    }
                }
                if !repos.repos.isEmpty {
                    Section("Repos") {
                        ForEach(repos.repos) { r in
                            HStack(spacing: 10) {
                                RepoGlyph(size: 28)
                                VStack(alignment: .leading) {
                                    Text(r.name).lineLimit(1)
                                    Text(repoSubtitle(r)).font(.caption).foregroundStyle(r.error == nil ? Color.secondary : Color.red).lineLimit(1)
                                }
                                Spacer()
                                if repos.isPulling(r.id) || r.targets.compactMap(\.projectId).contains(where: projects.isActive) {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .tag("repo:\(r.id)")
                            .contextMenu {
                                Button("Pull") { repos.pull(r.id) }
                                Button("Pull & Build") { repos.pull(r.id, build: .changed) }
                                Button("Remove Repo", role: .destructive) { repos.remove(r.id) }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Add .ipa or Xcode Project…") { pickFiles() }
                    Button("Add Git Repo…") { addingRepo = true }
                } label: { Label("Add", systemImage: "plus") } primaryAction: { pickFiles() }
                    .help("Add an .ipa, an Xcode project or a git repo")
                Button { NSWorkspace.shared.open(library.appsDir) } label: { Label("Show in Finder", systemImage: "folder") }
                    .help("Show the library in Finder")
            }
        }
        .overlay(alignment: .bottom) {
            if importing {
                ProgressView("Importing…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding()
            }
        }
        .overlay {
            if dropTargeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).padding(4) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        switch url.pathExtension.lowercased() {
                        case "ipa": await importFile(url)
                        case "xcodeproj", "xcworkspace": await addProject(at: url)
                        default: break
                        }
                    }
                }
            }
            return true
        }
        .sheet(isPresented: $addingRepo) {
            AddRepoSheet { id in
                addingRepo = false
                if let id { nav.selection = "repo:\(id)" }
            }
        }
        .sheet(item: $schemeChoice) { choice in
            SchemeChoiceSheet(choice: choice) { scheme in
                schemeChoice = nil
                if let scheme { Task { await addProject(at: choice.url, scheme: scheme) } }
            }
        }
        .alert("Couldn't Add", isPresented: .constant(error != nil), actions: { Button("OK") { error = nil } },
               message: { Text(error ?? "") })
        .frame(minWidth: 680, minHeight: 420)
    }

    @ViewBuilder private var detail: some View {
        if let sel = nav.selection, sel.hasPrefix("app:"), let app = library.app(String(sel.dropFirst(4))) {
            AppDetailView(app: app)
        } else if let sel = nav.selection, sel.hasPrefix("project:"), let p = projects.project(String(sel.dropFirst(8))) {
            ProjectDetailView(project: p)
        } else if let sel = nav.selection, sel.hasPrefix("repo:"), let r = repos.repo(String(sel.dropFirst(5))) {
            RepoDetailView(repo: r)
        } else {
            ContentUnavailableView("SelfStore", systemImage: "shippingbox",
                                   description: Text("Drop an .ipa or an Xcode project here, or add a git repo with a selfstore.yml. Agents can also POST builds to /api/apps."))
        }
    }

    private var sidebarItems: [SidebarItem] { SidebarItem.all(library: library, projects: projects) }

    private func repoSubtitle(_ r: StoredRepo) -> String {
        if repos.isPulling(r.id) { return r.step ?? "Pulling…" }
        if r.error != nil { return "Pull failed" }
        let n = r.targets.count
        return "\(n) app\(n == 1 ? "" : "s") · \(r.branches.count) branch\(r.branches.count == 1 ? "" : "es")"
    }

    /// Project types are packages, so they must be looked up as conforming to `.package`, not the default `.data`.
    private static let projectTypes: [UTType] = [
        UTType("com.apple.xcode.project"), UTType("com.apple.dt.document.workspace"),
        UTType(filenameExtension: "xcodeproj", conformingTo: .package),
        UTType(filenameExtension: "xcworkspace", conformingTo: .package),
    ].compactMap { $0 }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.message = "Choose .ipa files or an Xcode project (.xcodeproj / .xcworkspace)"
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data] + Self.projectTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            switch url.pathExtension.lowercased() {
            case "ipa": Task { await importFile(url) }
            case "xcodeproj", "xcworkspace": Task { await addProject(at: url) }
            default: break
            }
        }
    }

    /// Lists the schemes first; asks which one to use when there's more than one.
    private func addProject(at url: URL) async {
        let path = url.path
        do {
            let schemes = try await Task.detached { try ProjectStore.schemes(at: path) }.value
            if schemes.count > 1 {
                schemeChoice = SchemeChoice(url: url, schemes: schemes, selected: ProjectStore.defaultScheme(schemes, path: path))
            } else {
                await addProject(at: url, scheme: schemes.first)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func addProject(at url: URL, scheme: String?) async {
        do {
            let p = try await projects.add(path: url.path, scheme: scheme)
            nav.selection = "project:\(p.id)"
        } catch { self.error = error.localizedDescription }
    }

    private func importFile(_ url: URL) async {
        importing = true
        defer { importing = false }
        do {
            let v = try await library.importIPA(at: url, move: false, notes: nil)
            nav.selection = "app:\(v.bundleId)"
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// An entry in the Library sidebar and the menu bar: an app with the projects that publish to it,
/// or a project with nothing in the library yet (never built, or a Mac app).
enum SidebarItem: Identifiable {
    case app(StoredApp, [StoredProject])
    case project(StoredProject)

    /// Every app and loose project, newest first.
    @MainActor static func all(library: AppLibrary, projects: ProjectStore) -> [SidebarItem] {
        let builders = Dictionary(grouping: projects.projects.filter { !$0.isMac && $0.bundleId != nil }, by: { $0.bundleId! })
        let appIDs = Set(library.apps.map(\.bundleId))
        let apps = library.apps.map { SidebarItem.app($0, builders[$0.bundleId] ?? []) }
        let loose = projects.projects.filter { p in p.isMac || p.bundleId.map { !appIDs.contains($0) } ?? true }.map(SidebarItem.project)
        return (apps + loose).sorted { $0.date > $1.date }
    }

    var id: String {
        switch self {
        case .app(let a, _): "app:\(a.bundleId)"
        case .project(let p): "project:\(p.id)"
        }
    }

    var date: Date {
        switch self {
        case .app(let a, let ps): ([a.latest.uploadedAt] + ps.map { $0.lastBuild?.startedAt }).compactMap { $0 }.max() ?? .distantPast
        case .project(let p): p.lastBuild?.startedAt ?? .distantPast
        }
    }
}

struct SchemeChoice: Identifiable {
    let id = UUID()
    let url: URL
    let schemes: [String]
    var selected: String
}

struct SchemeChoiceSheet: View {
    @State var choice: SchemeChoice
    let done: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a Scheme").font(.headline)
            Text(choice.url.lastPathComponent).font(.callout).foregroundStyle(.secondary)
            Picker("Scheme", selection: $choice.selected) {
                ForEach(choice.schemes, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Add") { done(choice.selected) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct ProjectIcon: View {
    let project: StoredProject
    var size: CGFloat
    @State private var library = AppLibrary.shared

    var body: some View {
        let macIcon = ProjectStore.shared.outputDir(project.id).appendingPathComponent("icon.png")
        if project.isMac, FileManager.default.fileExists(atPath: macIcon.path) {
            AppIconView(url: macIcon, size: size)
        } else if !project.isMac, let id = project.bundleId, let app = library.app(id), let v = app.versions.first(where: \.hasIcon) {
            AppIconView(url: library.iconURL(v), size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay(Image(systemName: "hammer.fill").font(.system(size: size * 0.45)).foregroundStyle(.white))
        }
    }
}

struct AppDetailView: View {
    let app: StoredApp
    @State private var library = AppLibrary.shared
    @State private var signing = SigningManager.shared
    @State private var error: String?
    @State private var confirmDeleteApp = false
    @State private var confirmPrune = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppIconView(url: app.versions.first(where: \.hasIcon).map(library.iconURL), size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title2.bold())
                        Text(app.bundleId).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if let original = app.latest.originalBundleId {
                            Text("Originally \(original)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let team = app.latest.teamName { Text(team).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if signing.credentials != nil {
                        Button("Upload to TestFlight") {
                            do { try TestFlightUploader.shared.upload(app.bundleId, app.latest.id) }
                            catch { self.error = error.localizedDescription }
                        }
                        .disabled(app.latest.testFlight?.isActive == true)
                        .help("Sign \(app.latest.displayVersion) for the App Store and upload it to App Store Connect")
                    }
                }
                .padding(.vertical, 4)
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            let builders = ProjectStore.shared.projects.filter { !$0.isMac && $0.bundleId == app.bundleId }
            if !builders.isEmpty {
                Section {
                    ForEach(builders) { p in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.branch.map { "\(p.name) · \($0)" } ?? p.name).font(.headline)
                                Text(buildStatus(p)).font(.caption)
                                    .foregroundStyle(p.lastBuild?.state == .failed ? Color.red : Color.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Details") { LibrarySelection.shared.selection = "project:\(p.id)" }
                            BuildControl(project: p)
                        }
                    }
                } header: {
                    Text("Build")
                } footer: {
                    Text("Each build is signed for your devices and added here as a new version.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(app.versions) { v in VersionRow(v: v) }
            } header: {
                HStack {
                    Text("Versions")
                    Spacer()
                    if app.versions.count > 1 {
                        Button("Delete Older Versions") { confirmPrune = true }
                            .buttonStyle(.link).font(.caption)
                    }
                    Button("Delete App") { confirmDeleteApp = true }
                        .buttonStyle(.link).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(app.name)
        .confirmationDialog("Delete \(app.versions.count - 1) older version\(app.versions.count == 2 ? "" : "s") of \(app.name)?",
                            isPresented: $confirmPrune) {
            Button("Delete Older Versions", role: .destructive) {
                do { _ = try library.prune(bundleId: app.bundleId, keep: 1) } catch { self.error = error.localizedDescription }
            }
        } message: { Text("Keeps only \(app.latest.displayVersion).") }
        .confirmationDialog("Delete \(app.name)?", isPresented: $confirmDeleteApp) {
            Button("Delete App", role: .destructive) {
                do { try library.delete(bundleId: app.bundleId) } catch { self.error = error.localizedDescription }
            }
        } message: { Text("Deletes all \(app.versions.count) version\(app.versions.count == 1 ? "" : "s"). Projects and repos that build it stay.") }
    }
}

private func buildStatus(_ p: StoredProject) -> String {
    guard let b = p.lastBuild else { return "Not built yet" }
    switch b.state {
    case .queued, .building, .signing: return b.step ?? "Building…"
    case .failed: return b.error ?? "Build failed"
    case .cancelled: return "Cancelled"
    case .succeeded: return "Built \((b.finishedAt ?? b.startedAt).formatted(.relative(presentation: .named)))"
    }
}

/// Build, or a spinning ring that cancels while the project builds.
struct BuildControl: View {
    let project: StoredProject
    var prominent = false
    @State private var projects = ProjectStore.shared

    var body: some View {
        if projects.isActive(project.id) {
            Button { projects.cancel(project.id) } label: { BuildingRing(size: 22) }
                .buttonStyle(.plain)
                .help("Building. Click to cancel.")
        } else if prominent {
            Button("Build") { try? projects.build(project.id) }.buttonStyle(.borderedProminent)
        } else {
            Button("Build") { try? projects.build(project.id) }
        }
    }
}

private struct VersionRow: View {
    let v: StoredVersion
    @State private var library = AppLibrary.shared
    @State private var signing = SigningManager.shared
    @State private var working = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(v.displayVersion).font(.headline)
                    if v.resignedAt != nil {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint).help("Re-signed by SelfStore")
                    }
                }
                Text("\(v.uploadedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file))\(v.provisionedDevices.map { " · \($0) devices" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                if let exp = v.expiresAt {
                    Text(exp < Date() ? "Profile expired \(exp.formatted(date: .abbreviated, time: .omitted))"
                                      : "Profile expires \(exp.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(exp < Date() ? .red : .secondary)
                }
                if let source = v.source { Text(source).font(.caption).foregroundStyle(.secondary) }
                if let notes = v.notes { Text(notes).font(.callout).padding(.top, 2) }
                ForEach(v.signingWarnings ?? [], id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let tf = v.testFlight { TestFlightStatus(record: tf) }
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Menu {
                if let link = ServerController.shared.installURL(v) {
                    Button("Copy Install Link") { copyToPasteboard(link) }
                }
                if signing.credentials != nil {
                    Button("Upload to TestFlight") { try? TestFlightUploader.shared.upload(v.bundleId, v.id) }
                        .disabled(v.testFlight?.isActive == true)
                }
                if signing.isReady {
                    Button("Re-sign for Registered Devices") {
                        working = true
                        Task { _ = try? await library.resign(v.bundleId, v.id); working = false }
                    }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.ipaURL(v)]) }
                Divider()
                Button("Delete Version", role: .destructive) { try? library.delete(bundleId: v.bundleId, versionId: v.id) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

private struct TestFlightStatus: View {
    let record: TestFlightRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if record.isActive { ProgressView().controlSize(.mini) }
                Image(systemName: record.state == .succeeded ? "airplane.circle.fill"
                      : record.state == .failed ? "xmark.octagon.fill" : "airplane")
                    .foregroundStyle(record.state == .failed ? .red : .blue)
                Text(label).font(.caption)
            }
            if let e = record.error {
                Text(e).font(.caption).foregroundStyle(record.state == .failed ? .red : .orange).textSelection(.enabled)
            }
        }
    }

    private var label: String {
        switch record.state {
        case .succeeded: "TestFlight: uploaded \((record.finishedAt ?? record.startedAt).formatted(date: .abbreviated, time: .shortened))"
        case .failed: "TestFlight upload failed"
        default: "TestFlight: \(record.step ?? record.state.rawValue)"
        }
    }
}

struct ProjectDetailView: View {
    let project: StoredProject
    @State private var projects = ProjectStore.shared
    @State private var signing = SigningManager.shared
    @State private var schemes: [String] = []

    private var build: BuildRecord? { project.lastBuild }
    private var active: Bool { [.queued, .building, .signing].contains(build?.state) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ProjectIcon(project: project, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.title2.bold())
                        if let repoId = project.repoId, let repo = RepoStore.shared.repo(repoId) {
                            Button("\(repo.name) · \(project.branch ?? "")") { LibrarySelection.shared.selection = "repo:\(repoId)" }
                                .buttonStyle(.link).font(.callout)
                        }
                        Text(project.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                    }
                    Spacer()
                    BuildControl(project: project, prominent: true)
                }
                .padding(.vertical, 4)
                if project.isMac && signing.developerID == nil {
                    Label("Mac builds are signed ad hoc and not notarized until you add a Developer ID certificate in Settings ▸ Signing.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                } else if !project.isMac && !signing.isReady {
                    Label("Set up signing in Settings so builds install on your devices.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Section("Build") {
                Picker("Platform", selection: Binding(get: { project.platform ?? .ios }, set: { projects.setPlatform(project.id, $0) })) {
                    Text("iOS").tag(StoredProject.Platform.ios)
                    Text("macOS").tag(StoredProject.Platform.macos)
                }
                .disabled(active || project.isFromRepo)
                Picker("Scheme", selection: Binding(get: { project.scheme }, set: { projects.setScheme(project.id, $0) })) {
                    ForEach(schemes.isEmpty ? [project.scheme] : schemes, id: \.self) { Text($0).tag($0) }
                }
                .disabled(active || project.isFromRepo)
                Toggle("Use a timestamp as the build number", isOn: Binding(get: { project.autoBuildNumber },
                                                                         set: { projects.setAutoBuildNumber(project.id, $0) }))
                LabeledContent("Configuration", value: project.configuration)
                if !project.isFromRepo && !project.isMac {
                    Toggle("Export the .ipa to the repo after each build",
                           isOn: Binding(get: { project.exportToRepo == true }, set: { projects.setExportToRepo(project.id, $0) }))
                    Text("Writes selfstore/\(AppLibrary.safeComponent(project.scheme)).ipa and lists it in selfstore.yml at the git root, so the repo can be added to any SelfStore without building. Nothing is committed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if project.isFromRepo {
                    Text("Platform and scheme come from the repo's selfstore.yml.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let build {
                Section("Last Build") {
                    LabeledContent("Status") {
                        HStack {
                            if active { ProgressView().controlSize(.small) }
                            Text(build.step ?? build.state.rawValue.capitalized)
                        }
                    }
                    LabeledContent("Started", value: build.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let f = build.finishedAt {
                        LabeledContent("Duration", value: Duration.seconds(f.timeIntervalSince(build.startedAt))
                            .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                    }
                    if let c = build.commit { LabeledContent("Commit", value: String(c.prefix(7))) }
                    if let e = build.error { Text(e).foregroundStyle(.red).textSelection(.enabled) }
                    if let path = build.exportedTo {
                        LabeledContent("Exported") {
                            Button((path as NSString).lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                .buttonStyle(.link)
                        }
                    }
                    if let tail = build.logTail, !tail.isEmpty {
                        Text(tail.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if project.isMac, build.state == .succeeded {
                        ForEach(build.artifacts ?? [], id: \.self) { name in
                            let url = projects.outputDir(project.id).appendingPathComponent(name)
                            LabeledContent(name) {
                                HStack {
                                    if name.hasSuffix(".dmg") { Button("Open") { NSWorkspace.shared.open(url) } }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                            }
                        }
                        LabeledContent("Notarized", value: build.notarized == true ? "Yes" : "No")
                        ForEach(build.warnings ?? [], id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    HStack {
                        Button("Open Full Log") { NSWorkspace.shared.open(projects.logURL(project.id)) }
                        if !project.isMac, let id = project.bundleId, build.state == .succeeded {
                            Button("Show App") { LibrarySelection.shared.selection = "app:\(id)" }
                        }
                    }
                }
            }
            if !project.isFromRepo {
            Section {
                Button("Remove Project", role: .destructive) {
                    LibrarySelection.shared.selection = nil
                    projects.remove(project.id)
                }
            } footer: {
                Text("Removing the project doesn't delete its source or any builds already in the library.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
        .task(id: project.path) {
            let path = project.path
            schemes = (try? await Task.detached { try ProjectStore.schemes(at: path) }.value) ?? []
        }
    }
}
