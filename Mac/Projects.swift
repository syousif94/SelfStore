import Foundation
import Observation

/// An Xcode project/workspace + scheme that SelfStore can build on request (from the iOS app, the API or the Mac UI).
struct StoredProject: Codable, Identifiable, Hashable {
    var id: String
    var path: String                 // .xcodeproj or .xcworkspace
    var scheme: String
    var configuration: String = "Release"
    var autoBuildNumber: Bool = true
    var bundleId: String?            // learned after the first successful build
    var lastBuild: BuildRecord?
    var platform: Platform?          // nil = iOS (projects added before Mac support)
    // Projects that come from a git repo's selfstore.yml (managed by RepoStore; path is inside its worktree).
    var repoId: String?
    var repoTarget: String?          // "<branch>/<name>"
    var branch: String?
    var displayName: String?
    var idSuffix: String?            // appended to the bundle ID (non-default branches)
    var notes: String?
    /// After each iOS build, copy the .ipa to <git root>/selfstore/<scheme>.ipa and list it in selfstore.yml.
    var exportToRepo: Bool?

    enum Platform: String, Codable, CaseIterable { case ios, macos }
    var isMac: Bool { platform == .macos }

    var name: String { displayName ?? scheme }
    var isFromRepo: Bool { repoId != nil }
    var fileName: String { (path as NSString).lastPathComponent }
}

struct BuildRecord: Codable, Hashable {
    enum State: String, Codable { case queued, building, signing, succeeded, failed, cancelled }
    var state: State
    var startedAt: Date
    var finishedAt: Date?
    var step: String?
    var versionId: String?
    var error: String?
    var logTail: [String]?
    // Mac builds: files in builds/<id>/output, and whether they were notarized.
    var artifacts: [String]?
    var notarized: Bool?
    var version: String?
    var warnings: [String]?
    var commit: String?              // repo projects: the commit that was built
    var exportedTo: String?          // export to repo: where the .ipa was written
}

enum ProjectError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

@MainActor @Observable
final class ProjectStore {
    static let shared = ProjectStore()

    private(set) var projects: [StoredProject] = []
    private var queue: [String] = []
    private var running: Process?
    private var runningID: String?
    private var cancelled = Set<String>()

    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SelfStore", isDirectory: true)
    private var file: URL { root.appendingPathComponent("projects.json") }
    func buildDir(_ id: String) -> URL { root.appendingPathComponent("builds/\(id)", isDirectory: true) }
    func logURL(_ id: String) -> URL { buildDir(id).appendingPathComponent("build.log") }

    private init() {
        if let d = try? Data(contentsOf: file), let p = try? JSONDecoder.selfStore.decode([StoredProject].self, from: d) {
            // Builds interrupted by a quit are reported as failed.
            projects = p.map { proj in
                var proj = proj
                if let b = proj.lastBuild, [.queued, .building, .signing].contains(b.state) {
                    proj.lastBuild?.state = .failed
                    proj.lastBuild?.error = "Interrupted"
                    proj.lastBuild?.finishedAt = Date()
                }
                return proj
            }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder.selfStore.encode(projects).write(to: file)
    }

    func project(_ id: String) -> StoredProject? { projects.first { $0.id == id } }

    private func update(_ id: String, _ change: (inout StoredProject) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
        save()
    }

    // MARK: Adding

    /// Lists the schemes of a project or workspace.
    nonisolated static func schemes(at path: String) throws -> [String] {
        let flag = path.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        let data = try Shell.run("/usr/bin/xcodebuild", ["-list", "-json", flag, path])
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let json = try JSONSerialization.jsonObject(with: data[start...]) as? [String: Any],
              let container = (json["project"] ?? json["workspace"]) as? [String: Any] else { return [] }
        return (container["schemes"] as? [String]) ?? []
    }

    /// Prefer a scheme named like the project, else one mentioning iOS, else the first one.
    nonisolated static func defaultScheme(_ schemes: [String], path: String) -> String {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return schemes.first { $0 == base } ?? schemes.first { $0.localizedCaseInsensitiveContains("ios") } ?? schemes[0]
    }

    @discardableResult
    func add(path rawPath: String, scheme: String?) async throws -> StoredProject {
        let path = (rawPath as NSString).expandingTildeInPath
        guard path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace"),
              FileManager.default.fileExists(atPath: path) else {
            throw ProjectError.message("Expected an existing .xcodeproj or .xcworkspace path")
        }
        let schemes = try await Task.detached { try Self.schemes(at: path) }.value
        guard !schemes.isEmpty else { throw ProjectError.message("No schemes found. Open the project in Xcode once, or share its schemes.") }
        let chosen: String
        if let scheme {
            guard schemes.contains(scheme) else { throw ProjectError.message("No scheme \"\(scheme)\". Schemes: \(schemes.joined(separator: ", "))") }
            chosen = scheme
        } else {
            chosen = Self.defaultScheme(schemes, path: path)
        }
        if let existing = projects.first(where: { $0.path == path && $0.scheme == chosen }) { return existing }
        let id = AppLibrary.safeComponent("\(base(path))-\(chosen)").lowercased()
        var unique = id, n = 2
        while project(unique) != nil { unique = "\(id)-\(n)"; n += 1 }
        let platform = (try? await Task.detached { try Self.detectPlatform(path: path, scheme: chosen) }.value) ?? .ios
        let p = StoredProject(id: unique, path: path, scheme: chosen, platform: platform)
        projects.append(p)
        save()
        return p
    }

    private func base(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    /// macOS when the scheme's app target only builds for the Mac; iOS otherwise (including multiplatform apps).
    nonisolated static func detectPlatform(path: String, scheme: String) throws -> StoredProject.Platform {
        let flag = path.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        let settings = try buildSettings([flag, path, "-scheme", scheme])
        let app = settings.first { $0["PRODUCT_TYPE"] == "com.apple.product-type.application" }
        let platforms = (app?["SUPPORTED_PLATFORMS"] ?? app?["PLATFORM_NAME"] ?? "").split(separator: " ").map(String.init)
        return platforms.contains("macosx") && !platforms.contains("iphoneos") ? .macos : .ios
    }

    func setScheme(_ id: String, _ scheme: String) {
        update(id) { $0.scheme = scheme }
        guard let path = project(id)?.path else { return }
        Task {
            if let platform = try? await Task.detached(operation: { try Self.detectPlatform(path: path, scheme: scheme) }).value {
                update(id) { $0.platform = platform }
            }
        }
    }
    func setPlatform(_ id: String, _ platform: StoredProject.Platform) { update(id) { $0.platform = platform } }
    func outputDir(_ id: String) -> URL { buildDir(id).appendingPathComponent("output", isDirectory: true) }
    func setAutoBuildNumber(_ id: String, _ on: Bool) { update(id) { $0.autoBuildNumber = on } }
    func setExportToRepo(_ id: String, _ on: Bool) { update(id) { $0.exportToRepo = on } }

    func isActive(_ id: String) -> Bool {
        guard let s = project(id)?.lastBuild?.state else { return false }
        return [.queued, .building, .signing].contains(s)
    }

    /// Creates or updates the project that builds one app of a repo's selfstore.yml.
    func upsertRepoProject(existing: String?, repoId: String, targetId: String, name: String, branch: String, path: String,
                           scheme: String, configuration: String, platform: StoredProject.Platform?, idSuffix: String?,
                           notes: String?) async -> String {
        let id = existing.flatMap { project($0) != nil ? $0 : nil }
            ?? AppLibrary.safeComponent("\(repoId)-\(branch)-\(name)".replacingOccurrences(of: "/", with: "-")).lowercased()
        var detected = platform ?? project(id)?.platform
        if detected == nil {
            detected = (try? await Task.detached { try Self.detectPlatform(path: path, scheme: scheme) }.value) ?? .ios
        }
        if project(id) == nil {
            projects.append(StoredProject(id: id, path: path, scheme: scheme))
        }
        update(id) {
            $0.path = path; $0.scheme = scheme; $0.configuration = configuration; $0.platform = detected
            $0.repoId = repoId; $0.repoTarget = targetId; $0.branch = branch; $0.displayName = name
            $0.idSuffix = idSuffix; $0.notes = notes
        }
        return id
    }

    func remove(_ id: String) {
        cancel(id)
        projects.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: buildDir(id))
        save()
    }

    // MARK: Building

    var isBusy: Bool { runningID != nil }

    func build(_ id: String) throws {
        guard let p = project(id) else { throw ProjectError.message("Unknown project") }
        if let s = p.lastBuild?.state, [.queued, .building, .signing].contains(s) { return }
        if let repo = p.repoId, RepoStore.shared.isPulling(repo) {
            throw ProjectError.message("The repo is being pulled; build again when it finishes")
        }
        update(id) { $0.lastBuild = BuildRecord(state: .queued, startedAt: Date(), step: "Waiting…") }
        queue.append(id)
        pump()
    }

    func cancel(_ id: String) {
        if let i = queue.firstIndex(of: id) {
            queue.remove(at: i)
            update(id) { $0.lastBuild?.state = .cancelled; $0.lastBuild?.finishedAt = Date() }
        }
        if runningID == id { cancelled.insert(id); running?.terminate() }
    }

    private func pump() {
        guard runningID == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        runningID = id
        Task {
            await run(id)
            runningID = nil
            running = nil
            pump()
        }
    }

    private func setStep(_ id: String, _ state: BuildRecord.State, _ step: String) {
        update(id) { $0.lastBuild?.state = state; $0.lastBuild?.step = step }
    }

    private func run(_ id: String) async {
        guard let p = project(id) else { return }
        setStep(id, .building, "Starting xcodebuild…")
        let dir = buildDir(id)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = logURL(id)
        fm.createFile(atPath: log.path, contents: nil)

        let flag = p.path.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        var common = [flag, p.path, "-scheme", p.scheme, "-configuration", p.configuration,
                      "-destination", p.isMac ? "generic/platform=macOS" : "generic/platform=iOS",
                      "-derivedDataPath", dir.appendingPathComponent("dd").path,
                      "CODE_SIGNING_ALLOWED=NO"]
        if p.autoBuildNumber {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMddHHmm"
            f.timeZone = TimeZone(identifier: "UTC")
            common.append("CURRENT_PROJECT_VERSION=\(f.string(from: Date()))")
        }

        var commit: (sha: String, subject: String)?
        if p.isFromRepo {
            let dir = URL(fileURLWithPath: (p.path as NSString).deletingLastPathComponent)
            if let line = try? await Git.output(["log", "-1", "--format=%H%x00%s"], in: dir) {
                let parts = line.components(separatedBy: "\0")
                commit = (parts[0], parts.count > 1 ? parts[1] : "")
                update(id) { $0.lastBuild?.commit = parts[0] }
            }
        }

        do {
            // 1. Build
            try await xcodebuild(id, args: common + ["build"], log: log)
            if cancelled.remove(id) != nil { throw ProjectError.message("Cancelled") }

            // 2. Package with local signatures that carry each target's entitlements
            setStep(id, .signing, "Packaging…")
            var settings = try await Task.detached { try Self.buildSettings(common) }.value
            if !p.path.hasSuffix(".xcworkspace") {
                let allTargets = [flag, p.path, "-alltargets", "-configuration", p.configuration,
                                  "-sdk", p.isMac ? "macosx" : "iphoneos", "CODE_SIGNING_ALLOWED=NO"]
                settings += (try? await Task.detached { try Self.buildSettings(allTargets) }.value) ?? []
            }
            if p.isMac {
                try await packageMac(id, settings: settings)
                return
            }
            let ipa = dir.appendingPathComponent("build.ipa")
            try await Task.detached { try Self.package(settings: settings, into: ipa, work: dir) }.value

            if p.exportToRepo == true && !p.isFromRepo {
                setStep(id, .signing, "Exporting to the repo…")
                let dest = try await Task.detached { try Self.exportToRepo(ipa: ipa, project: p) }.value
                update(id) { $0.lastBuild?.exportedTo = dest }
            }

            // 3. Import (re-signs with the distribution identity when signing is set up)
            setStep(id, .signing, SigningManager.shared.credentials != nil ? "Signing for registered devices…" : "Importing…")
            var notes = "Built from \(p.scheme) on \(Date().formatted(date: .abbreviated, time: .shortened))"
            var sourceLabel = "Build of \(p.scheme)"
            if let commit, let branch = p.branch {
                let short = String(commit.sha.prefix(7))
                notes = [p.notes, "\(branch) @ \(short): \(commit.subject)"].compactMap { $0 }.joined(separator: "\n")
                sourceLabel = "\(RepoStore.shared.repo(p.repoId ?? "")?.name ?? "repo") \(branch) @ \(short)"
            }
            let v = try await AppLibrary.shared.importIPA(at: ipa, move: true, notes: notes, replace: true,
                                                          idSuffix: p.idSuffix, sourceLabel: sourceLabel)
            // On-demand builds pile up quickly; keep the newest few.
            _ = try? AppLibrary.shared.prune(bundleId: v.bundleId, keep: 5)
            update(id) {
                $0.bundleId = v.bundleId
                $0.lastBuild?.state = .succeeded
                $0.lastBuild?.step = "Built \(v.displayVersion)"
                $0.lastBuild?.versionId = v.id
                $0.lastBuild?.finishedAt = Date()
                $0.lastBuild?.logTail = nil
            }
            ServerController.shared.noteEvent("Built \(v.name) \(v.displayVersion)")
        } catch {
            let wasCancelled = cancelled.remove(id) != nil
            let tail = Self.errorLines(log)
            update(id) {
                $0.lastBuild?.state = wasCancelled ? .cancelled : .failed
                $0.lastBuild?.error = wasCancelled ? nil : error.localizedDescription
                $0.lastBuild?.step = wasCancelled ? "Cancelled" : "Failed"
                $0.lastBuild?.finishedAt = Date()
                $0.lastBuild?.logTail = tail
            }
        }
    }

    /// Signs (Developer ID when available), notarizes and writes a .dmg and .zip to the output folder.
    private func packageMac(_ id: String, settings: [[String: String]]) async throws {
        let signing = SigningManager.shared
        if signing.credentials != nil && signing.developerID == nil { await signing.refresh() }
        let devID = signing.developerID
        let config = MacPackager.Signing(identity: devID?.sha1 ?? "-", keychain: devID == nil ? nil : signing.keychain.path,
                                         teamID: signing.teamID, notarize: devID == nil ? nil : signing.credentials)
        let out = outputDir(id)
        let result = try await Task.detached {
            try MacPackager.package(settings: settings, signing: config, out: out) { step in
                Task { @MainActor in ProjectStore.shared.setStep(id, .signing, step) }
            }
        }.value
        update(id) {
            $0.bundleId = result.bundleId
            $0.lastBuild?.state = .succeeded
            $0.lastBuild?.step = "Built \(result.version)\(result.build.isEmpty || result.build == result.version ? "" : " (\(result.build))")\(result.notarized ? ", notarized" : "")"
            $0.lastBuild?.version = result.version
            $0.lastBuild?.artifacts = result.artifacts
            $0.lastBuild?.notarized = result.notarized
            $0.lastBuild?.warnings = result.warnings.isEmpty ? nil : result.warnings
            $0.lastBuild?.finishedAt = Date()
            $0.lastBuild?.logTail = nil
        }
        ServerController.shared.noteEvent("Built \(result.name) \(result.version) for Mac")
    }

    /// Runs xcodebuild, appending output to the log and surfacing a short progress step.
    private func xcodebuild(_ id: String, args: [String], log: URL) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let handle = try FileHandle(forWritingTo: log)
        var lastStep = Date.distantPast
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            handle.write(data)
            let text = String(decoding: data, as: UTF8.self)
            guard Date().timeIntervalSince(lastStep) > 0.7, let step = Self.step(from: text) else { return }
            lastStep = Date()
            Task { @MainActor in ProjectStore.shared.setStep(id, .building, step) }
        }
        running = p
        try p.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in c.resume() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        try? handle.close()
        guard p.terminationStatus == 0 else {
            throw ProjectError.message(Self.errorLines(log)?.first ?? "xcodebuild failed (\(p.terminationStatus))")
        }
    }

    nonisolated private static func step(from text: String) -> String? {
        for line in text.split(separator: "\n").reversed() {
            let l = line.trimmingCharacters(in: .whitespaces)
            for (prefix, label) in [("CompileSwift", "Compiling Swift"), ("SwiftCompile", "Compiling Swift"), ("SwiftDriver", "Compiling Swift"),
                                    ("CompileC", "Compiling"), ("Ld ", "Linking"), ("CompileAssetCatalog", "Compiling assets"),
                                    ("CompileStoryboard", "Compiling storyboards"), ("ProcessInfoPlistFile", "Processing Info.plist"),
                                    ("Resolve Package Graph", "Resolving packages"), ("Fetching", "Fetching packages"),
                                    ("CopySwiftLibs", "Copying Swift libraries"), ("PhaseScriptExecution", "Running scripts")] {
                if l.hasPrefix(prefix) {
                    if let file = l.split(separator: " ").last(where: { $0.hasSuffix(".swift") || $0.hasSuffix(".m") || $0.hasSuffix(".mm") }) {
                        return "\(label): \((String(file) as NSString).lastPathComponent)"
                    }
                    return label + "…"
                }
            }
        }
        return nil
    }

    nonisolated static func errorLines(_ log: URL) -> [String]? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        let errors = lines.filter { $0.contains(": error:") || $0.hasPrefix("error:") || $0.contains("** BUILD FAILED") }
        let picked = errors.isEmpty ? Array(lines.suffix(12)) : Array(errors.prefix(12))
        return picked.isEmpty ? nil : picked.map { String($0.prefix(400)) }
    }

    // MARK: Export to repo

    /// Copies a built .ipa to `<git root>/selfstore/<scheme>.ipa` and lists it in `<git root>/selfstore.yml`,
    /// so the repo can be added to another SelfStore without building. Nothing is committed.
    nonisolated static func exportToRepo(ipa: URL, project p: StoredProject) throws -> String {
        let projectDir = URL(fileURLWithPath: (p.path as NSString).deletingLastPathComponent)
        let rootPath = (try? String(decoding: Git.runSync(["rev-parse", "--show-toplevel"], in: projectDir), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? projectDir.path
        let root = URL(fileURLWithPath: rootPath.isEmpty ? projectDir.path : rootPath)
        let rel = "selfstore/\(AppLibrary.safeComponent(p.scheme)).ipa"
        let dest = root.appendingPathComponent(rel)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: ipa, to: dest)
        try RepoConfig.upsertIPAEntry(at: root.appendingPathComponent(RepoConfig.fileName), name: p.name, ipaPath: rel)
        return dest.path
    }

    // MARK: Packaging

    nonisolated static func buildSettings(_ common: [String]) throws -> [[String: String]] {
        let data = try Shell.run("/usr/bin/xcodebuild", ["-showBuildSettings", "-json"] + common)
        guard let start = data.firstIndex(of: UInt8(ascii: "[")),
              let arr = try JSONSerialization.jsonObject(with: data[start...]) as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["buildSettings"] as? [String: String] }
    }

    /// Copies the built .app into Payload/, locally signs every nested bundle inside-out with its own
    /// entitlements (so SelfStore's re-signer keeps them), and zips an .ipa.
    nonisolated private static func package(settings: [[String: String]], into ipa: URL, work: URL) throws {
        let fm = FileManager.default
        guard let app = settings.first(where: { $0["PRODUCT_TYPE"] == "com.apple.product-type.application" && $0["PLATFORM_NAME"] == "iphoneos" }),
              let dir = app["TARGET_BUILD_DIR"], let wrapper = app["WRAPPER_NAME"] else {
            throw ProjectError.message("The scheme doesn't build an iOS app")
        }
        let built = URL(fileURLWithPath: dir).appendingPathComponent(wrapper)
        guard fm.fileExists(atPath: built.path) else { throw ProjectError.message("Built app not found at \(built.path)") }

        let staging = work.appendingPathComponent("package", isDirectory: true)
        try? fm.removeItem(at: staging)
        let payload = staging.appendingPathComponent("Payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        let appCopy = payload.appendingPathComponent(wrapper)
        try Shell.run("/usr/bin/ditto", [built.path, appCopy.path])

        // Entitlements per bundle wrapper name (App.app, Share.appex, …), with build variables expanded.
        var entitlementsByWrapper: [String: URL] = [:]
        for s in settings where entitlementsByWrapper[s["WRAPPER_NAME"] ?? ""] == nil {
            guard let w = s["WRAPPER_NAME"], let rel = s["CODE_SIGN_ENTITLEMENTS"], !rel.isEmpty, let srcRoot = s["SRCROOT"] else { continue }
            let path = rel.hasPrefix("/") ? rel : (srcRoot as NSString).appendingPathComponent(rel)
            guard var plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            plist = expand(plist, settings: s) as? [String: Any] ?? plist
            // With signing off, $(AppIdentifierPrefix) resolves to "", leaving keychain groups without a team prefix.
            if let groups = plist["keychain-access-groups"] as? [String] {
                plist["keychain-access-groups"] = groups.map { g in
                    g.firstMatch(of: /^[A-Z0-9]{10}\./) != nil || g.hasPrefix("SELFSTORE.") ? g : "SELFSTORE." + g
                }
            }
            let bundleID = s["PRODUCT_BUNDLE_IDENTIFIER"] ?? ""
            // Placeholder team; the re-signer retargets SELFSTORE.* to the real team.
            plist["application-identifier"] = "SELFSTORE.\(bundleID)"
            plist["com.apple.developer.team-identifier"] = "SELFSTORE"
            let out = staging.appendingPathComponent("\(w).entitlements")
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: out)
            entitlementsByWrapper[w] = out
        }

        var nested: [URL] = []
        if let e = fm.enumerator(at: appCopy, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in e where ["framework", "appex", "app", "xpc", "dylib"].contains(url.pathExtension) {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                nested.append(url)
            }
        }
        nested.sort { $0.pathComponents.count > $1.pathComponents.count }
        for url in nested + [appCopy] {
            var args = ["-f", "-s", "-", "--timestamp=none"]
            if let ent = entitlementsByWrapper[url.lastPathComponent] { args += ["--entitlements", ent.path] }
            try Shell.run("/usr/bin/codesign", args + [url.path])
        }

        try? fm.removeItem(at: ipa)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-qry", ipa.path, "Payload"]
        try zip.run(); zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw ProjectError.message("zip failed") }
    }

    /// Expands $(VAR) / ${VAR} in entitlement values using build settings.
    nonisolated private static func expand(_ value: Any, settings: [String: String]) -> Any {
        if let s = value as? String {
            var out = s
            for prefixVar in ["AppIdentifierPrefix", "TeamIdentifierPrefix"] {
                out = out.replacingOccurrences(of: "$(\(prefixVar))", with: "SELFSTORE.")
                    .replacingOccurrences(of: "${\(prefixVar)}", with: "SELFSTORE.")
            }
            while let r = out.firstRange(of: /\$[({]([A-Za-z0-9_]+)(?::[^)}]*)?[)}]/) {
                let name = String(out[r].dropFirst(2).dropLast()).split(separator: ":").first.map(String.init) ?? ""
                out.replaceSubrange(r, with: settings[name] ?? "")
            }
            return out
        }
        if let a = value as? [Any] { return a.map { expand($0, settings: settings) } }
        if let d = value as? [String: Any] { return d.mapValues { expand($0, settings: settings) } }
        return value
    }
}
