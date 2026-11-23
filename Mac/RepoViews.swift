import AppKit
import SwiftUI

// MARK: - Repo detail

struct RepoDetailView: View {
    let repo: StoredRepo
    @State private var repos = RepoStore.shared
    @State private var projects = ProjectStore.shared
    @State private var library = AppLibrary.shared
    @State private var confirmRemove = false

    private var pulling: Bool { repos.isPulling(repo.id) }
    private var anyBuilding: Bool { repo.targets.compactMap(\.projectId).contains(where: projects.isActive) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    RepoGlyph(size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.name).font(.title2.bold())
                        Link(repo.url, destination: URL(string: repo.url)!).font(.callout)
                        if let d = repo.lastPull {
                            Text("Pulled \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if pulling {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Pull") { repos.pull(repo.id) }
                            .help("Fetch, import changed .ipa files and update build targets")
                            .disabled(anyBuilding)
                        Button("Pull & Build") { repos.pull(repo.id, build: .changed) }
                            .buttonStyle(.borderedProminent)
                            .help("Pull, then build every project target with new commits")
                            .disabled(anyBuilding)
                    }
                }
                .padding(.vertical, 4)
                if let step = repo.step, pulling { Text(step).font(.callout).foregroundStyle(.secondary) }
                if let e = repo.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            if !repo.branches.isEmpty {
                Section("Branches") {
                    ForEach(repo.branches, id: \.name) { b in
                        LabeledContent {
                            if let e = b.error {
                                Text(e).foregroundStyle(.red).font(.caption)
                            } else {
                                Text("\(String(b.commit.prefix(7))) · \(b.subject)").lineLimit(1).foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(b.name)
                                if b.name == repo.defaultBranch { Text("default").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }

            Section {
                if repo.targets.isEmpty {
                    Text(pulling ? "Reading selfstore.yml…" : "Nothing published yet. Pull to read the repo's selfstore.yml.")
                        .foregroundStyle(.secondary)
                }
                ForEach(repo.targets) { t in TargetRow(target: t) }
            } header: {
                Text("Apps")
            } footer: {
                Text("Prebuilt .ipa files are imported when they change. Projects are built on this Mac with Pull & Build or their Build button. Apps on branches other than the default get the branch name appended to their bundle ID so they install side by side.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Show Checkout in Finder") { NSWorkspace.shared.open(repos.repoDir(repo.id).appendingPathComponent("branches")) }
                Button("Remove Repo", role: .destructive) { confirmRemove = true }
            } footer: {
                Text("Removing the repo deletes its checkout and build targets. Apps already in the library stay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(repo.name)
        .confirmationDialog("Remove \(repo.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                LibrarySelection.shared.selection = nil
                repos.remove(repo.id)
            }
        }
    }
}

private struct TargetRow: View {
    let target: StoredRepo.Target
    @State private var projects = ProjectStore.shared
    @State private var library = AppLibrary.shared

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(target.name).font(.headline)
                    Text(target.branch).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(target.kind == .ipa ? target.path : "\(target.path) · \(target.scheme ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let e = target.error ?? project?.lastBuild?.error {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                } else if let p = project, let b = p.lastBuild, active {
                    Text(b.step ?? "Building…").font(.caption).foregroundStyle(.tint)
                }
            }
            Spacer()
            if target.kind == .project, let p = project {
                BuildControl(project: p)
                Button("Details") { LibrarySelection.shared.selection = "project:\(p.id)" }
            }
            if let id = appID, library.app(id) != nil {
                Button("Show App") { LibrarySelection.shared.selection = "app:\(id)" }
            }
        }
        .padding(.vertical, 2)
    }

    private var project: StoredProject? { target.projectId.flatMap(projects.project) }
    private var active: Bool { target.projectId.map(projects.isActive) ?? false }
    private var appID: String? { target.kind == .ipa ? target.bundleId : project.flatMap { $0.isMac ? nil : $0.bundleId } }

    @ViewBuilder private var icon: some View {
        if let id = appID, let app = library.app(id), let v = app.versions.first(where: \.hasIcon) {
            AppIconView(url: library.iconURL(v), size: 36)
        } else if let p = project {
            ProjectIcon(project: p, size: 36)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary).frame(width: 36, height: 36)
                .overlay(Image(systemName: "shippingbox").foregroundStyle(.secondary))
        }
    }
}

struct RepoGlyph: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "arrow.triangle.branch").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white))
    }
}

// MARK: - Add repo

struct AddRepoSheet: View {
    let done: (String?) -> Void
    @State private var url = ""
    @State private var buildNow = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Git Repo").font(.headline)
            Text("A public repo with a selfstore.yml at its root listing prebuilt .ipa files and/or Xcode projects to build.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://github.com/owner/repo", text: $url)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Toggle("Build its projects after cloning", isOn: $buildNow)
            Text("Building runs the repo's build scripts on this Mac. Only add repos you trust.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func add() {
        do {
            let r = try RepoStore.shared.add(url: url, build: buildNow)
            done(r.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Settings ▸ Bundle IDs

struct BundleIDSection: View {
    @State private var settings = Settings.shared
    @State private var signing = SigningManager.shared

    var body: some View {
        Section {
            TextField("Prefix", text: $settings.bundlePrefix, prompt: Text("com.example"))
            Toggle("Move uploaded and repo .ipa files to this prefix", isOn: $settings.renameImports)
                .disabled(settings.bundlePrefix.trimmingCharacters(in: .whitespaces).isEmpty)
            if let example = BundleRename.target(for: "com.someone.Notes", prefix: settings.bundlePrefix, suffix: nil),
               settings.renameImports {
                LabeledContent("Example", value: "com.someone.Notes → \(example)")
                    .font(.caption)
            }
        } header: {
            Text("Bundle IDs")
        } footer: {
            Text("Apps from other developers use bundle IDs registered to their team, so they can't be signed with yours. SelfStore keeps the last part of the ID and replaces the rest with this prefix (extensions, app groups and iCloud containers follow). It applies when a build is imported and re-signed; existing versions keep their ID. App groups and iCloud containers can't be created with an API key, so those entitlements are dropped unless they already exist on your account.\(signing.credentials == nil ? " Renaming needs signing to be set up." : "")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
