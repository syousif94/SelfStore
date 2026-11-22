import CryptoKit
import Foundation
import Observation
import Yams

// MARK: - selfstore.yml

/// The `selfstore.yml` at the root of a repo. Each app is either a prebuilt `.ipa` in the repo or an Xcode
/// project + scheme that SelfStore builds:
///
/// ```yaml
/// version: 1
/// branches: [main]               # default for every app; globs like "release/*" work
/// apps:
///   - name: Notes
///     ipa: selfstore/Notes.ipa
///   - name: Widgets
///     project: Widgets/Widgets.xcodeproj   # or .xcworkspace
///     scheme: Widgets                      # or schemes: [Widgets, WidgetsMac]
///     configuration: Release               # optional
///     platform: ios                        # optional (ios | macos), detected when omitted
///     branches: [main, beta]               # optional, overrides the default
///     notes: Shown with every build        # optional
/// ```
struct RepoConfig: Equatable {
    struct Entry: Equatable {
        var name: String
        var ipa: String?
        var project: String?
        var scheme: String?
        var configuration: String?
        var platform: StoredProject.Platform?
        var branches: [String]?
        var notes: String?
    }

    var branches: [String]?
    var entries: [Entry]

    static let fileName = "selfstore.yml"

    static func parse(_ text: String) throws -> RepoConfig {
        let loaded: Any?
        do { loaded = try Yams.load(yaml: text) } catch { throw ProjectError.message("selfstore.yml isn't valid YAML: \(error)") }
        guard let root = loaded as? [String: Any] else { throw ProjectError.message("selfstore.yml must be a mapping with an `apps` list") }
        let topBranches = strings(root["branches"])
        guard let apps = root["apps"] as? [Any], !apps.isEmpty else { throw ProjectError.message("selfstore.yml has no `apps`") }
        var entries: [Entry] = []
        for (i, raw) in apps.enumerated() {
            guard let a = raw as? [String: Any] else { throw ProjectError.message("apps[\(i)] must be a mapping") }
            let ipa = a["ipa"] as? String
            let project = a["project"] as? String
            guard (ipa == nil) != (project == nil) else {
                throw ProjectError.message("apps[\(i)] needs exactly one of `ipa` or `project`")
            }
            var platform: StoredProject.Platform?
            if let p = a["platform"] as? String {
                guard let parsed = StoredProject.Platform(rawValue: p.lowercased()) else {
                    throw ProjectError.message("apps[\(i)].platform must be ios or macos")
                }
                platform = parsed
            }
            let base = Entry(name: "", ipa: ipa, project: project, scheme: nil, configuration: a["configuration"] as? String,
                             platform: platform, branches: strings(a["branches"]), notes: a["notes"].map { "\($0)" })
            for path in [ipa, project].compactMap({ $0 }) where path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                throw ProjectError.message("apps[\(i)]: paths must be relative to the repo root (\(path))")
            }
            if let ipa {
                var e = base
                e.name = (a["name"] as? String) ?? ((ipa as NSString).lastPathComponent as NSString).deletingPathExtension
                entries.append(e)
            } else if let project {
                let schemes = strings(a["schemes"]) ?? (a["scheme"] as? String).map { [$0] }
                guard let schemes, !schemes.isEmpty else { throw ProjectError.message("apps[\(i)] (\(project)) needs a `scheme`") }
                let explicitName = a["name"] as? String
                for s in schemes {
                    var e = base
                    e.scheme = s
                    e.name = schemes.count == 1 ? (explicitName ?? s) : s
                    entries.append(e)
                }
            }
        }
        let names = entries.map(\.name)
        if let dup = names.first(where: { n in names.filter { $0 == n }.count > 1 }) {
            throw ProjectError.message("selfstore.yml lists \"\(dup)\" twice; give each app a unique `name`")
        }
        return RepoConfig(branches: topBranches, entries: entries)
    }

    private static func strings(_ v: Any?) -> [String]? {
        if let s = v as? String { return [s] }
        if let a = v as? [Any] { return a.map { "\($0)" } }
        return nil
    }

    /// Branch patterns an entry is published from.
    func patterns(for e: Entry, defaultBranch: String) -> [String] { e.branches ?? branches ?? [defaultBranch] }

    static func matches(_ branch: String, _ pattern: String) -> Bool {
        fnmatch(pattern, branch, 0) == 0
    }

    // MARK: Writing (export from SelfStore-built projects)

    /// Adds or updates an `ipa` entry named `name` in the yml at `url`, keeping everything else in the file.
    static func upsertIPAEntry(at url: URL, name: String, ipaPath: String) throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var root: Node.Mapping
        if let node = try Yams.compose(yaml: text), let m = node.mapping { root = m } else { root = Node.Mapping([]) }
        if root["version"] == nil {
            root = Node.Mapping([(Node("version"), Node("1", Tag(.int)))] + Array(root))
        }
        var apps = root["apps"]?.sequence ?? Node.Sequence([])
        if let i = apps.firstIndex(where: { $0.mapping?["name"]?.string == name && $0.mapping?["project"] == nil }) {
            var entry = apps[i].mapping!
            entry["ipa"] = Node(ipaPath)
            apps[i] = .mapping(entry)
        } else {
            apps.append(Node([(Node("name"), Node(name)), (Node("ipa"), Node(ipaPath))]))
        }
        root["apps"] = .sequence(apps)
        // YAML round-trips drop comments; keep the file's leading comment block at least.
        var header = text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { $0.hasPrefix("#") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { $0.hasPrefix("#") }.joined(separator: "\n")
        if header.isEmpty { header = "# SelfStore: apps this repo publishes. Format: \(SelfStoreLinks.ymlDocs)" }
        let out = header + "\n" + (try Yams.serialize(node: .mapping(root)))
        try out.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Stored repos

struct StoredRepo: Codable, Identifiable, Hashable {
    var id: String
    var url: String
    var name: String                 // owner/repo
    var addedAt: Date
    var defaultBranch: String?
    var lastPull: Date?
    var state: State = .idle
    var step: String?
    var error: String?
    var branches: [Branch] = []
    var targets: [Target] = []

    enum State: String, Codable { case idle, pulling, failed }

    struct Branch: Codable, Hashable {
        var name: String
        var commit: String
        var subject: String
        var date: Date?
        var error: String?
    }

    struct Target: Codable, Hashable, Identifiable {
        enum Kind: String, Codable { case ipa, project }
        var id: String                // "<branch>/<name>"
        var name: String
        var branch: String
        var kind: Kind
        var path: String              // relative to the repo root
        var scheme: String?
        var projectId: String?        // .project: the ProjectStore entry that builds it
        var bundleId: String?         // .ipa: the library app it imports into
        var importedHash: String?
        var importedCommit: String?
        var error: String?
    }
}

@MainActor @Observable
final class RepoStore {
    static let shared = RepoStore()

    private(set) var repos: [StoredRepo] = []
    private var running = Set<String>()

    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SelfStore", isDirectory: true)
    private var file: URL { root.appendingPathComponent("repos.json") }
    func repoDir(_ id: String) -> URL { root.appendingPathComponent("repos/\(id)", isDirectory: true) }
    func cloneDir(_ id: String) -> URL { repoDir(id).appendingPathComponent("clone", isDirectory: true) }
    func worktree(_ id: String, branch: String) -> URL {
        repoDir(id).appendingPathComponent("branches/\(AppLibrary.safeComponent(branch.replacingOccurrences(of: "/", with: "-")))",
                                           isDirectory: true)
    }

    private init() {
        if let d = try? Data(contentsOf: file), let r = try? JSONDecoder.selfStore.decode([StoredRepo].self, from: d) {
            repos = r.map { var r = $0; if r.state == .pulling { r.state = .failed; r.error = "Interrupted"; r.step = nil }; return r }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder.selfStore.encode(repos).write(to: file)
    }

    func repo(_ id: String) -> StoredRepo? { repos.first { $0.id == id } }
    func isPulling(_ id: String) -> Bool { running.contains(id) }

    private func update(_ id: String, _ change: (inout StoredRepo) -> Void) {
        guard let i = repos.firstIndex(where: { $0.id == id }) else { return }
        change(&repos[i])
        save()
    }

    // MARK: Adding / removing

    /// Accepts https URLs, `github.com/owner/repo` and `owner/repo` (GitHub).
    nonisolated static func normalize(_ raw: String) throws -> (url: String, name: String, host: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        // Local repos, for testing only.
        if s.hasPrefix("file:///") {
            let parts = s.split(separator: "/")
            return (s, parts.suffix(2).joined(separator: "/"), "local")
        }
        #endif
        if s.hasPrefix("git@") || s.hasPrefix("ssh://") || s.hasPrefix("http://") || s.hasPrefix("file:") {
            throw ProjectError.message("Use the repo's https:// URL")
        }
        if !s.contains("://") {
            s = s.split(separator: "/").count == 2 && !s.contains(".") ? "https://github.com/\(s)" : "https://\(s)"
        }
        guard var comps = URLComponents(string: s), comps.scheme == "https", let host = comps.host, !host.isEmpty else {
            throw ProjectError.message("That doesn't look like a git URL")
        }
        comps.query = nil; comps.fragment = nil; comps.user = nil; comps.password = nil
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        // github.com/owner/repo/tree/branch → github.com/owner/repo
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { throw ProjectError.message("The URL needs an owner and a repo, e.g. https://github.com/owner/repo") }
        let trimmed = ["github.com", "gitlab.com", "codeberg.org"].contains(host) ? Array(parts.prefix(2)) : parts
        comps.path = "/" + trimmed.joined(separator: "/")
        return (comps.string!, trimmed.suffix(2).joined(separator: "/"), host)
    }

    @discardableResult
    func add(url raw: String, build: Bool = false) throws -> StoredRepo {
        let n = try Self.normalize(raw)
        if let existing = repos.first(where: { $0.url.caseInsensitiveCompare(n.url) == .orderedSame }) {
            pull(existing.id, build: build ? .changed : nil)
            return existing
        }
        let base = AppLibrary.safeComponent("\(n.host)-\(n.name)".replacingOccurrences(of: "/", with: "-")).lowercased()
        var id = base, i = 2
        while repo(id) != nil { id = "\(base)-\(i)"; i += 1 }
        let r = StoredRepo(id: id, url: n.url, name: n.name, addedAt: Date())
        repos.append(r)
        save()
        pull(id, build: build ? .changed : nil)
        return r
    }

    func remove(_ id: String) {
        guard let r = repo(id) else { return }
        for t in r.targets { if let p = t.projectId { ProjectStore.shared.remove(p) } }
        repos.removeAll { $0.id == id }
        save()
        let dir = repoDir(id)
        Task.detached { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Pulling

    enum BuildMode: String { case changed, all }

    /// Fetches, checks out every listed branch, imports changed .ipa files and updates build targets.
    /// `build` then queues the repo's project targets: `.changed` = new commits or never built successfully.
    func pull(_ id: String, build: BuildMode? = nil) {
        guard repo(id) != nil, !running.contains(id) else { return }
        if let busy = repo(id)?.targets.compactMap(\.projectId).first(where: { ProjectStore.shared.isActive($0) }) {
            update(id) { $0.error = "Can't pull while \(ProjectStore.shared.project(busy)?.name ?? busy) is building" }
            return
        }
        running.insert(id)
        update(id) { $0.state = .pulling; $0.step = "Fetching…"; $0.error = nil }
        Task {
            do {
                try await performPull(id)
                running.remove(id)
                update(id) { $0.state = .idle; $0.step = nil; $0.lastPull = Date() }
                if let build { queueBuilds(id, mode: build) }
            } catch {
                running.remove(id)
                update(id) { $0.state = .failed; $0.step = nil; $0.error = error.localizedDescription }
            }
        }
    }

    func queueBuilds(_ id: String, mode: BuildMode) {
        guard let r = repo(id) else { return }
        let projects = ProjectStore.shared
        for t in r.targets where t.kind == .project {
            guard let pid = t.projectId, let p = projects.project(pid) else { continue }
            let head = r.branches.first { $0.name == t.branch }?.commit
            let upToDate = p.lastBuild?.state == .succeeded && p.lastBuild?.commit == head
            if mode == .all || !upToDate { try? projects.build(pid) }
        }
    }

    private func setStep(_ id: String, _ step: String) { update(id) { $0.step = step } }

    private func performPull(_ id: String) async throws {
        guard let r = repo(id) else { return }
        let clone = cloneDir(id)
        let url = r.url

        // 1. Clone or fetch.
        if FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git").path)
            || FileManager.default.fileExists(atPath: clone.appendingPathComponent("HEAD").path) {
            setStep(id, "Fetching…")
            try await Git.run(["fetch", "--prune", "--force", "origin"], in: clone)
        } else {
            setStep(id, "Cloning…")
            try? FileManager.default.removeItem(at: clone)
            try FileManager.default.createDirectory(at: repoDir(id), withIntermediateDirectories: true)
            try await Git.run(["clone", "--no-checkout", "--filter=blob:none", url, clone.path], in: repoDir(id))
        }
        _ = try? await Git.run(["remote", "set-head", "origin", "--auto"], in: clone)
        let headRef = (try? await Git.output(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: clone)) ?? "origin/main"
        let defaultBranch = headRef.hasPrefix("origin/") ? String(headRef.dropFirst(7)) : headRef
        let remote = try await Git.output(["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin"], in: clone)
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("origin/") && $0 != "origin/HEAD" }.map { String($0.dropFirst(7)) }

        // 2. selfstore.yml from the default branch decides which branches to check out.
        setStep(id, "Reading \(RepoConfig.fileName)…")
        guard let text = try? await Git.output(["show", "origin/\(defaultBranch):\(RepoConfig.fileName)"], in: clone) else {
            throw ProjectError.message("\(r.name) has no \(RepoConfig.fileName) on \(defaultBranch). Add one at the repo root listing the apps to publish.")
        }
        let config = try RepoConfig.parse(text)
        var patterns = Set(config.entries.flatMap { config.patterns(for: $0, defaultBranch: defaultBranch) })
        if patterns.isEmpty { patterns = [defaultBranch] }
        let wanted = remote.filter { b in patterns.contains { RepoConfig.matches(b, $0) } }.sorted {
            $0 == defaultBranch ? true : $1 == defaultBranch ? false : $0 < $1
        }
        let missing = patterns.filter { p in !p.contains("*") && !p.contains("?") && !remote.contains(p) }

        // 3. One worktree per branch.
        var branches: [StoredRepo.Branch] = []
        var configs: [String: RepoConfig] = [:]
        for b in wanted {
            setStep(id, "Checking out \(b)…")
            let wt = worktree(id, branch: b)
            do {
                if !FileManager.default.fileExists(atPath: wt.appendingPathComponent(".git").path) {
                    try? FileManager.default.removeItem(at: wt)
                    _ = try? await Git.run(["worktree", "prune"], in: clone)
                    try await Git.run(["worktree", "add", "--detach", "--force", wt.path, "origin/\(b)"], in: clone)
                } else {
                    try await Git.run(["checkout", "--detach", "--force", "origin/\(b)"], in: wt)
                }
                try await Git.run(["clean", "-ffd"], in: wt)
                if FileManager.default.fileExists(atPath: wt.appendingPathComponent(".gitmodules").path) {
                    setStep(id, "Updating submodules on \(b)…")
                    try await Git.run(["submodule", "update", "--init", "--recursive", "--force"], in: wt)
                }
                if let attrs = try? String(contentsOf: wt.appendingPathComponent(".gitattributes"), encoding: .utf8),
                   attrs.contains("filter=lfs") {
                    guard Git.lfsAvailable else {
                        throw ProjectError.message("\(b) stores files with Git LFS. Install it on this Mac: brew install git-lfs")
                    }
                    setStep(id, "Downloading LFS files on \(b)…")
                    try await Git.run(["lfs", "pull"], in: wt)
                }
                let info = try await Git.output(["log", "-1", "--format=%H%x00%s%x00%cI"], in: wt).components(separatedBy: "\0")
                branches.append(.init(name: b, commit: info[0], subject: info.count > 1 ? info[1] : "",
                                      date: info.count > 2 ? ISO8601DateFormatter().date(from: info[2]) : nil))
                // Each branch can carry its own selfstore.yml (paths may differ); fall back to the default branch's.
                if let own = try? String(contentsOf: wt.appendingPathComponent(RepoConfig.fileName), encoding: .utf8),
                   let parsed = try? RepoConfig.parse(own) {
                    configs[b] = parsed
                } else {
                    configs[b] = config
                }
            } catch {
                branches.append(.init(name: b, commit: "", subject: "", error: error.localizedDescription))
            }
        }
        for m in missing { branches.append(.init(name: m, commit: "", subject: "", error: "No branch \(m) on the remote")) }

        // Remove worktrees for branches that are no longer listed.
        let keep = Set(wanted.map { worktree(id, branch: $0).lastPathComponent })
        let branchesDir = repoDir(id).appendingPathComponent("branches")
        for dir in (try? FileManager.default.contentsOfDirectory(at: branchesDir, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(dir.lastPathComponent) {
            _ = try? await Git.run(["worktree", "remove", "--force", dir.path], in: clone)
            try? FileManager.default.removeItem(at: dir)
        }

        // 4. Targets.
        let previous = Dictionary(uniqueKeysWithValues: (repo(id)?.targets ?? []).map { ($0.id, $0) })
        var targets: [StoredRepo.Target] = []
        for branch in branches where branch.error == nil {
            let cfg = configs[branch.name] ?? config
            for e in cfg.entries where cfg.patterns(for: e, defaultBranch: defaultBranch).contains(where: { RepoConfig.matches(branch.name, $0) }) {
                let tid = "\(branch.name)/\(e.name)"
                var t = previous[tid] ?? StoredRepo.Target(id: tid, name: e.name, branch: branch.name,
                                                           kind: e.ipa != nil ? .ipa : .project, path: e.ipa ?? e.project ?? "")
                t.kind = e.ipa != nil ? .ipa : .project
                t.path = e.ipa ?? e.project ?? ""
                t.scheme = e.scheme
                t.error = nil
                let suffix = branch.name == defaultBranch ? nil : branch.name
                let wt = worktree(id, branch: branch.name)
                let file = wt.appendingPathComponent(t.path)
                if t.kind == .ipa {
                    if let pid = t.projectId { ProjectStore.shared.remove(pid); t.projectId = nil }
                    do {
                        guard FileManager.default.fileExists(atPath: file.path) else { throw ProjectError.message("\(t.path) isn't in \(branch.name)") }
                        let hash = try await Task.detached { try Self.sha256(file) }.value
                        if hash != t.importedHash || t.bundleId.flatMap({ AppLibrary.shared.app($0) }) == nil {
                            setStep(id, "Importing \(e.name) from \(branch.name)…")
                            let short = String(branch.commit.prefix(7))
                            let notes = [e.notes, "\(branch.name) @ \(short): \(branch.subject)"].compactMap { $0 }.joined(separator: "\n")
                            let v = try await AppLibrary.shared.importIPA(at: file, move: false, notes: notes, replace: true,
                                                                          idSuffix: suffix, sourceLabel: "\(r.name) \(branch.name) @ \(short)")
                            _ = try? AppLibrary.shared.prune(bundleId: v.bundleId, keep: 5)
                            t.bundleId = v.bundleId
                            t.importedHash = hash
                            t.importedCommit = branch.commit
                            ServerController.shared.noteEvent("Imported \(v.name) \(v.displayVersion) from \(r.name)")
                        }
                    } catch {
                        t.error = error.localizedDescription
                    }
                } else {
                    guard FileManager.default.fileExists(atPath: file.path) else {
                        t.error = "\(t.path) isn't in \(branch.name)"
                        targets.append(t)
                        continue
                    }
                    t.projectId = await ProjectStore.shared.upsertRepoProject(
                        existing: t.projectId, repoId: id, targetId: tid, name: e.name, branch: branch.name,
                        path: file.path, scheme: e.scheme ?? e.name, configuration: e.configuration ?? "Release",
                        platform: e.platform, idSuffix: suffix, notes: e.notes)
                }
                targets.append(t)
            }
        }
        // Projects for targets that disappeared.
        let live = Set(targets.compactMap(\.projectId))
        for t in previous.values { if let p = t.projectId, !live.contains(p) { ProjectStore.shared.remove(p) } }

        let branchErrors = branches.compactMap { b in b.error.map { "\(b.name): \($0)" } }
        update(id) {
            $0.defaultBranch = defaultBranch
            $0.branches = branches
            $0.targets = targets
            $0.error = branchErrors.isEmpty ? nil : branchErrors.joined(separator: "\n")
        }
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum SelfStoreLinks {
    static let repo = "https://github.com/syousif94/SelfStore"
    static let ymlDocs = "https://syousif94.github.io/SelfStore/docs.html#selfstore-yml"
}

// MARK: - git

enum Git {
    static let executable = "/usr/bin/git"

    /// Never prompt for credentials (the repo must be public, or the user's git credential helper already knows it).
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GCM_INTERACTIVE"] = "never"
        env["GIT_LFS_SKIP_SMUDGE"] = "1"   // LFS files are fetched explicitly with `git lfs pull`
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [(env["PATH"] ?? "/usr/bin:/bin")]).joined(separator: ":")
        return env
    }

    static var lfsAvailable: Bool {
        ["/opt/homebrew/bin/git-lfs", "/usr/local/bin/git-lfs", "/usr/bin/git-lfs"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ args: [String], in dir: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { try runSync(args, in: dir) }.value
    }

    static func output(_ args: [String], in dir: URL) async throws -> String {
        String(decoding: try await run(args, in: dir), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func runSync(_ args: [String], in dir: URL) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        #if DEBUG
        let fileProtocol = "user"   // lets tests use file:// repos
        #else
        let fileProtocol = "never"  // no local-path submodules from untrusted repos
        #endif
        p.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=\(fileProtocol)"] + args
        p.currentDirectoryURL = dir
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        var errData = Data()
        let errThread = Thread { errData = err.fileHandleForReading.readDataToEndOfFile() }
        errThread.start()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        while errThread.isExecuting { usleep(1000) }
        guard p.terminationStatus == 0 else {
            var msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("could not read Username") || msg.contains("Authentication failed") || msg.contains("Repository not found") {
                msg = "The repo wasn't found or isn't public."
            }
            throw ProjectError.message("git \(args.first ?? "") failed: \(msg.split(separator: "\n").suffix(3).joined(separator: " "))")
        }
        return data
    }
}
