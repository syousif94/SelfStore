import SwiftUI
import UniformTypeIdentifiers

struct RepoRef: Hashable { var ref: SourceRef }

extension UTType {
    static var ipa: UTType { UTType("com.apple.itunes.ipa") ?? UTType(filenameExtension: "ipa") ?? .data }
}

// MARK: - Rows

struct RepoRow: View {
    @Environment(StoreModel.self) private var store
    let repo: CatalogRepo
    let serverID: UUID

    var body: some View {
        HStack(spacing: 14) {
            RepoGlyph(size: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(repo.name).font(.headline).lineLimit(1)
                Text("\(repo.targets.count) app\(repo.targets.count == 1 ? "" : "s") · \(repo.branches.map(\.name).joined(separator: ", "))")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                RepoStatusLine(repo: repo, building: building)
            }
            Spacer(minLength: 8)
            PullButton(repo: repo, serverID: serverID, busy: building)
        }
        .padding(.vertical, 4)
    }

    private var building: Bool {
        let ids = Set(repo.targets.compactMap(\.projectId))
        return store.state(serverID).projects.contains { ids.contains($0.id) && $0.isActive }
    }
}

struct RepoStatusLine: View {
    let repo: CatalogRepo
    var building = false

    var body: some View {
        if repo.isPulling || building {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(repo.isPulling ? (repo.step ?? "Pulling…") : "Building…")
            }
            .font(.caption).foregroundStyle(.tint).lineLimit(1)
        } else if let e = repo.error {
            Text(e).font(.caption).foregroundStyle(.red).lineLimit(2)
        } else if let d = repo.lastPull {
            (Text("Pulled ") + Text(d, format: .relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct PullButton: View {
    @Environment(StoreModel.self) private var store
    let repo: CatalogRepo
    let serverID: UUID
    var busy = false
    @State private var error: String?

    var body: some View {
        Menu {
            Button("Pull & Build", systemImage: "hammer") { run(build: true) }
            Button("Pull Only", systemImage: "arrow.down.circle") { run(build: false) }
        } label: {
            Text("Pull").font(.subheadline.bold())
        } primaryAction: {
            run(build: true)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(repo.isPulling || busy)
        .alert("Couldn't Pull", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func run(build: Bool) {
        Task {
            do { try await store.pull(repo, build: build, on: serverID) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct RepoGlyph: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "arrow.triangle.branch").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
    }
}

// MARK: - Detail

struct RepoDetailView: View {
    @Environment(StoreModel.self) private var store
    let ref: SourceRef

    var body: some View {
        let state = store.state(ref.server)
        if let repo = state.repos.first(where: { $0.id == ref.id }) {
            List {
                Section {
                    HStack(spacing: 16) {
                        RepoGlyph(size: 80)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(repo.name).font(.title2.bold())
                            if let url = URL(string: repo.url) { Link(url.host ?? repo.url, destination: url).font(.subheadline) }
                            RepoStatusLine(repo: repo, building: building(repo))
                            PullButton(repo: repo, serverID: ref.server, busy: building(repo)).padding(.top, 2)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(repo.branches) { b in
                    Section {
                        if let e = b.error {
                            Text(e).font(.footnote).foregroundStyle(.red)
                        }
                        ForEach(repo.targets.filter { $0.branch == b.name }) { t in
                            TargetRow(target: t, serverID: ref.server)
                        }
                    } header: {
                        Text(b.name == repo.defaultBranch ? "\(b.name) (default)" : b.name)
                    } footer: {
                        if b.error == nil { Text("\(String(b.commit.prefix(7))) · \(b.subject)") }
                    }
                }
                Section {
                    LabeledContent("Mac", value: store.server(ref.server)?.name ?? "")
                } footer: {
                    Text("Pull & Build fetches the repo, imports changed .ipa files and builds projects with new commits. Apps on other branches get the branch name added to their bundle ID so they install alongside the default branch.")
                }
            }
            .navigationTitle(repo.name)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh(ref.server) }
        } else {
            ContentUnavailableView("Repo Removed", systemImage: "trash")
        }
    }

    private func building(_ repo: CatalogRepo) -> Bool {
        let ids = Set(repo.targets.compactMap(\.projectId))
        return store.state(ref.server).projects.contains { ids.contains($0.id) && $0.isActive }
    }
}

private struct TargetRow: View {
    @Environment(StoreModel.self) private var store
    let target: CatalogRepoTarget
    let serverID: UUID

    var body: some View {
        let state = store.state(serverID)
        let project = target.projectId.flatMap { id in state.projects.first { $0.id == id } }
        let app = target.bundleId.flatMap { id in state.apps.first { $0.bundleId == id } }
        if let project {
            NavigationLink(value: ProjectRef(ref: SourceRef(server: serverID, id: project.id))) {
                HStack(spacing: 12) {
                    ProjectIcon(url: store.url(project.iconPath, on: serverID), size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name).font(.headline)
                        BuildStatusLine(project: project)
                    }
                    Spacer()
                    if !project.isActive, !project.isMac, project.state == "succeeded", let v = store.builtVersion(for: project, on: serverID) {
                        InstallButton(version: v)
                    } else {
                        BuildButton(project: project, serverID: serverID)
                    }
                }
            }
        } else if let app {
            NavigationLink(value: SourceRef(server: serverID, id: app.bundleId)) {
                HStack(spacing: 12) {
                    AppIcon(url: store.url(app.iconPath, on: serverID), size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name).font(.headline)
                        if let v = app.latest { Text("Version \(v.displayVersion)").font(.caption).foregroundStyle(.secondary) }
                        if let e = target.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                    }
                    Spacer()
                    if let v = app.latest { InstallButton(version: v) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.headline)
                Text(target.path).font(.caption).foregroundStyle(.secondary)
                if let e = target.error { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
    }
}

// MARK: - Add repo

struct AddRepoView: View {
    @Environment(StoreModel.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var build = true
    @State private var server: UUID?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://github.com/owner/repo", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Toggle("Build its projects", isOn: $build)
                } footer: {
                    Text("A public repo with a selfstore.yml at its root listing prebuilt .ipa files and/or Xcode projects. Building runs the repo's build scripts on the Mac, so only add repos you trust.")
                }
                MacPicker(selection: $server)
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Add Git Repo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Add") { add() }.disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || server == nil)
                    }
                }
            }
            .onAppear { server = server ?? store.servers.first(where: { store.canWrite(on: $0.id) })?.id ?? store.servers.first?.id }
        }
    }

    private func add() {
        guard let server else { return }
        busy = true
        error = nil
        Task {
            do { try await store.addRepo(url, build: build, on: server); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// Picks which Mac to send something to (hidden when there's only one).
struct MacPicker: View {
    @Environment(StoreModel.self) private var store
    @Binding var selection: UUID?

    var body: some View {
        if store.servers.count > 1 {
            Section("Mac") {
                Picker("Mac", selection: $selection) {
                    ForEach(store.servers) { s in Text(s.name).tag(Optional(s.id)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        if let id = selection, !store.canWrite(on: id) {
            Section {
                Label("This Mac isn't shared over Tailscale, which is needed to send it repos and .ipa files.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Upload

struct UploadView: View {
    @Environment(StoreModel.self) private var store
    @Environment(\.dismiss) private var dismiss
    let file: URL
    @State private var server: UUID?
    @State private var notes = ""
    @State private var rename = true
    @State private var prefix = ""
    @State private var saveAsDefault = false
    @State private var prefixLoadedFor: UUID?
    @State private var error: String?
    @State private var done: CatalogVersion?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(file.lastPathComponent, systemImage: "doc.zipper")
                    TextField("Release notes (optional)", text: $notes, axis: .vertical)
                }
                MacPicker(selection: $server)
                if let id = server, store.state(id).info?.signingEnabled == true {
                    BundlePrefixSection(server: id, rename: $rename, prefix: $prefix, saveAsDefault: $saveAsDefault)
                }
                if let up = store.upload {
                    Section {
                        ProgressView(value: up.fraction) { Text(up.phase) }
                    }
                }
                if let v = done {
                    Section {
                        Label("Added \(v.name) \(v.displayVersion)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if let original = v.originalBundleId { LabeledContent("Bundle ID", value: "\(original) → \(v.bundleId)").font(.caption) }
                        InstallButton(version: v)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Upload .ipa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done == nil ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if done == nil {
                        Button("Upload") { start() }
                            .disabled(server == nil || store.upload != nil || (rename && !BundlePrefixSection.isValid(prefix)))
                    }
                }
            }
            .interactiveDismissDisabled(store.upload != nil)
            .onAppear { server = server ?? store.servers.first(where: { store.canWrite(on: $0.id) })?.id ?? store.servers.first?.id }
            .onChange(of: server, initial: true) { loadPrefix() }
            .onChange(of: server.flatMap { store.state($0).info }) { loadPrefix() }
        }
    }

    private func start() {
        guard let server else { return }
        error = nil
        let prefix = self.prefix.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        Task {
            do {
                if saveAsDefault { try await store.updateBundlePrefix(prefix, rename: rename, on: server) }
                done = try await store.uploadIPA(file, notes: notes, rename: rename && !prefix.isEmpty, prefix: prefix, on: server)
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Fills the prefix from the Mac once its info arrives (and again when switching Macs), keeping the user's edits.
    private func loadPrefix() {
        guard let server, store.state(server).info != nil, prefixLoadedFor != server else { return }
        prefixLoadedFor = server
        prefix = store.savedPrefix(on: server)
        rename = store.renamesByDefault(on: server) || prefix.isEmpty
        saveAsDefault = false
    }
}

/// Bundle ID prefix for an upload, with the option to save it as the Mac's default.
struct BundlePrefixSection: View {
    @Environment(StoreModel.self) private var store
    let server: UUID
    @Binding var rename: Bool
    @Binding var prefix: String
    @Binding var saveAsDefault: Bool

    static func isValid(_ s: String) -> Bool {
        let clean = s.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return clean.isEmpty || clean.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*/) != nil
    }

    private var saved: String { store.savedPrefix(on: server) }
    private var trimmed: String { prefix.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces)) }

    var body: some View {
        Section {
            Toggle("Move to my bundle ID prefix", isOn: $rename)
            if rename {
                TextField("Prefix", text: $prefix, prompt: Text("com.example"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if trimmed != saved {
                    Toggle("Save as \(store.server(server)?.name ?? "this Mac")'s default", isOn: $saveAsDefault)
                }
            }
        } header: {
            Text("Bundle ID")
        } footer: {
            if rename && !Self.isValid(prefix) {
                Text("Use letters, digits and hyphens, separated by dots.").foregroundStyle(.red)
            } else if rename && !trimmed.isEmpty {
                Text("com.someone.App becomes \(trimmed).App, so apps from other developers can be signed with this Mac's team.")
            } else {
                Text("Apps from other developers need your own prefix (like com.yourname) to be signed with this Mac's team.")
            }
        }
    }
}
