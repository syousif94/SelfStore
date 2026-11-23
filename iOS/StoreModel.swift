import Foundation
import Network
import Observation
import UIKit

struct SavedServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var tailscaleURL: URL?
    var lanURL: URL?

    /// Tailscale first: it works anywhere on the tailnet and is the install path anyway.
    var candidates: [URL] { [tailscaleURL, lanURL].compactMap { $0 } }
}

/// Live state for one Mac.
struct SourceState {
    var apps: [CatalogApp] = []
    var projects: [CatalogProject] = []
    var repos: [CatalogRepo] = []
    var info: ServerInfo?
    var base: URL?
    var error: String?
    var loading = false
    var loadedOnce = false
}

enum StoreError: LocalizedError {
    case unreachable(String)
    case notSelfStore
    case server(String)
    var errorDescription: String? {
        switch self {
        case .unreachable(let s): return "Can't reach \(s). Check that this device is on the same network or on Tailscale."
        case .notSelfStore: return "That address isn't a SelfStore server."
        case .server(let m): return m
        }
    }
}

/// Every saved Mac is a source; the app shows all of them together.
@MainActor @Observable
final class StoreModel {
    private(set) var servers: [SavedServer] = []
    private(set) var states: [UUID: SourceState] = [:]
    private var pollTask: Task<Void, Never>?

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: "servers"),
           let s = try? JSONDecoder().decode([SavedServer].self, from: data) { servers = s }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: "servers")
    }

    func state(_ id: UUID) -> SourceState { states[id] ?? SourceState() }
    func server(_ id: UUID) -> SavedServer? { servers.first { $0.id == id } }

    func url(_ path: String?, on server: UUID) -> URL? {
        guard let path, let base = states[server]?.base else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    var anyLoading: Bool { states.values.contains { $0.loading } }
    var allApps: [(UUID, CatalogApp)] { servers.flatMap { s in state(s.id).apps.map { (s.id, $0) } } }
    var allProjects: [(UUID, CatalogProject)] { servers.flatMap { s in state(s.id).projects.map { (s.id, $0) } } }

    // MARK: Loading

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for s in servers { group.addTask { await self.refresh(s.id) } }
        }
        updatePolling()
    }

    func refresh(_ id: UUID) async {
        guard let server = server(id) else { return }
        states[id, default: SourceState()].loading = true
        defer { states[id]?.loading = false; states[id]?.loadedOnce = true }
        // Try the last working address first.
        var candidates = server.candidates
        if let last = states[id]?.base, let i = candidates.firstIndex(of: last) { candidates.swapAt(0, i) }
        for base in candidates {
            do {
                let (data, resp) = try await session.data(from: base.appendingPathComponent("api/apps"))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let apps = try JSONDecoder.selfStore.decode([CatalogApp].self, from: data)
                let projects = (try? await fetchProjects(base)) ?? []
                let repos = (try? await fetch([CatalogRepo].self, "api/repos", base)) ?? []
                let info = try? await fetchInfo(base)
                states[id, default: SourceState()].apps = apps
                states[id]?.projects = projects
                states[id]?.repos = repos
                states[id]?.info = info
                states[id]?.base = base
                states[id]?.error = nil
                if let info { updateServer(id, from: info) }
                return
            } catch { continue }
        }
        states[id, default: SourceState()].error = StoreError.unreachable(server.name).localizedDescription
    }

    private func fetchInfo(_ base: URL) async throws -> ServerInfo {
        let (data, _) = try await session.data(from: base.appendingPathComponent("api/info"))
        let info = try JSONDecoder.selfStore.decode(ServerInfo.self, from: data)
        guard info.service == "SelfStore" else { throw StoreError.notSelfStore }
        return info
    }

    private func fetchProjects(_ base: URL) async throws -> [CatalogProject] {
        let (data, resp) = try await session.data(from: base.appendingPathComponent("api/projects"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try JSONDecoder.selfStore.decode([CatalogProject].self, from: data)
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ path: String, _ base: URL) async throws -> T {
        let (data, resp) = try await session.data(from: base.appendingPathComponent(path))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw StoreError.server("HTTP error") }
        return try JSONDecoder.selfStore.decode(T.self, from: data)
    }

    private func updateServer(_ id: UUID, from info: ServerInfo) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        var s = servers[i]
        s.name = info.name
        if let ts = info.tailscaleURL.flatMap(URL.init(string:)) { s.tailscaleURL = ts }
        if let lan = info.lanURL.flatMap(URL.init(string:)) { s.lanURL = lan }
        if s != servers[i] { servers[i] = s; save() }
    }

    // MARK: Builds

    func build(_ project: CatalogProject, on id: UUID) async throws {
        try await post("api/projects/\(project.id)/build", on: id)
        await refresh(id)
        updatePolling()
    }

    func cancel(_ project: CatalogProject, on id: UUID) async throws {
        try await post("api/projects/\(project.id)/cancel", on: id)
        await refresh(id)
    }

    // MARK: Repos

    func pull(_ repo: CatalogRepo, build: Bool, on id: UUID) async throws {
        try await post("api/repos/\(repo.id)/pull\(build ? "?build=changed" : "")", on: id)
        await refresh(id)
        updatePolling()
    }

    /// Adding a repo (and uploading) goes through the Mac's Tailscale address, which the Mac trusts without a token.
    func addRepo(_ url: String, build: Bool, on id: UUID) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["url": url, "build": build])
        try await post("api/repos", on: id, body: body, viaTailscale: true)
        await refresh(id)
        updatePolling()
    }

    func canWrite(on id: UUID) -> Bool { server(id)?.tailscaleURL != nil }

    // MARK: Uploading .ipa files

    private(set) var upload: UploadProgress?
    /// An .ipa opened from Files/Share or picked in the app, waiting for the upload sheet.
    var pendingUpload: PendingFile?

    struct PendingFile: Identifiable { let id = UUID(); let url: URL }

    struct UploadProgress: Equatable {
        var fileName: String
        var server: UUID
        var fraction: Double
        var phase: String
    }

    @ObservationIgnored private let uploadSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()

    /// Streams an .ipa to the Mac, which re-signs it (moving it to its bundle ID prefix when `rename`).
    /// `prefix` moves this upload to a prefix other than the Mac's saved one.
    func uploadIPA(_ file: URL, notes: String, rename: Bool, prefix: String? = nil, on id: UUID) async throws -> CatalogVersion {
        guard let base = server(id)?.tailscaleURL else {
            throw StoreError.server("Uploading needs the Mac's Tailscale address. Turn on Tailscale sharing in SelfStore on the Mac.")
        }
        // Files from other apps are security scoped; copy to our temp folder first so the upload can read it.
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        try FileManager.default.copyItem(at: file, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var comps = URLComponents(url: base.appendingPathComponent("api/apps"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "rename", value: rename ? "true" : "false")]
        if !notes.isEmpty { comps.queryItems?.append(URLQueryItem(name: "notes", value: notes)) }
        if rename, let prefix, !prefix.isEmpty { comps.queryItems?.append(URLQueryItem(name: "prefix", value: prefix)) }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        upload = UploadProgress(fileName: file.lastPathComponent, server: id, fraction: 0, phase: "Uploading…")
        defer { upload = nil }
        let delegate = UploadDelegate { [weak self] fraction in
            Task { @MainActor in
                self?.upload?.fraction = fraction
                if fraction >= 1 { self?.upload?.phase = "Signing on \(self?.server(id)?.name ?? "the Mac")…" }
            }
        }
        let (data, resp) = try await uploadSession.upload(for: req, fromFile: tmp, delegate: delegate)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw StoreError.server(msg ?? "The Mac returned \(status)")
        }
        let v = try JSONDecoder.selfStore.decode(CatalogVersion.self, from: data)
        await refresh(id)
        return v
    }

    // MARK: Mac settings

    /// The prefix saved on the Mac (whether or not renaming is on). Older Macs only report it while renaming is on.
    func savedPrefix(on id: UUID) -> String {
        let info = state(id).info
        return info?.bundlePrefixSetting ?? info?.bundlePrefix ?? ""
    }

    func renamesByDefault(on id: UUID) -> Bool {
        let info = state(id).info
        return info?.renameImports ?? (info?.bundlePrefix != nil)
    }

    /// Saves the bundle ID prefix (and whether uploads use it) on the Mac.
    func updateBundlePrefix(_ prefix: String, rename: Bool, on id: UUID) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["bundlePrefix": prefix, "renameImports": rename])
        try await post("api/settings", on: id, body: body, viaTailscale: true, method: "PATCH")
        await refresh(id)
    }

    // MARK: TestFlight

    func canUploadToTestFlight(on id: UUID) -> Bool { state(id).info?.testFlightEnabled == true }

    func uploadToTestFlight(_ version: CatalogVersion, on id: UUID) async throws {
        try await post("api/apps/\(version.bundleId)/\(version.id)/testflight", on: id)
        await refresh(id)
        updatePolling()
    }

    private func post(_ path: String, on id: UUID, body: Data? = nil, viaTailscale: Bool = false,
                      method: String = "POST") async throws {
        let base = viaTailscale ? server(id)?.tailscaleURL : (states[id]?.base ?? server(id)?.candidates.first)
        guard let base else {
            throw StoreError.unreachable(viaTailscale ? "the Mac over Tailscale (turn on Tailscale sharing on the Mac)" : "the Mac")
        }
        // Paths may carry a query string.
        var req = URLRequest(url: URL(string: path, relativeTo: base.appendingPathComponent("/"))!.absoluteURL)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw StoreError.server(msg ?? "The Mac returned \(status)")
        }
    }

    /// Something on this Mac is building or uploading to TestFlight.
    private func isBusy(_ id: UUID) -> Bool {
        let s = state(id)
        return s.projects.contains(where: \.isActive) || s.repos.contains(where: \.isPulling)
            || s.apps.contains { $0.versions.contains { $0.testFlight?.isActive == true } }
    }

    /// While any build or upload runs, refresh the Macs that are busy every couple of seconds.
    private func updatePolling() {
        let building = servers.map(\.id).filter(isBusy)
        if building.isEmpty { pollTask?.cancel(); pollTask = nil; return }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let ids = self.servers.map(\.id).filter(self.isBusy)
                if ids.isEmpty { self.pollTask = nil; return }
                for id in ids { await self.refresh(id) }
            }
        }
    }

    /// The installable version a finished build produced (or the app's latest).
    func builtVersion(for project: CatalogProject, on id: UUID) -> CatalogVersion? {
        guard let bundleId = project.bundleId, let app = state(id).apps.first(where: { $0.bundleId == bundleId }) else { return nil }
        return app.versions.first { $0.id == project.versionId } ?? app.latest
    }

    // MARK: Adding / removing

    @discardableResult
    func add(urls: [URL], fallbackName: String) async throws -> SavedServer {
        var lastError: Error = StoreError.unreachable(fallbackName)
        for base in urls {
            do {
                let info = try await fetchInfo(base)
                var server = SavedServer(name: info.name,
                                         tailscaleURL: info.tailscaleURL.flatMap(URL.init(string:)),
                                         lanURL: info.lanURL.flatMap(URL.init(string:)))
                if server.tailscaleURL == nil && base.scheme == "https" { server.tailscaleURL = base }
                if server.lanURL == nil && base.scheme == "http" { server.lanURL = base }
                if let existing = servers.firstIndex(where: { $0.name == server.name || ($0.tailscaleURL != nil && $0.tailscaleURL == server.tailscaleURL) }) {
                    server.id = servers[existing].id
                    servers[existing] = server
                } else {
                    servers.append(server)
                }
                save()
                await refresh(server.id)
                updatePolling()
                return server
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func add(manual text: String) async throws {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains("://") { t = (t.contains(".ts.net") ? "https://" : "http://") + t }
        guard var comps = URLComponents(string: t), comps.host != nil else { throw StoreError.notSelfStore }
        comps.path = ""; comps.query = nil
        if comps.port == nil {
            comps.port = Int(comps.scheme == "https" ? SelfStoreConstants.defaultTailscalePort : SelfStoreConstants.defaultHTTPPort)
        }
        guard let url = comps.url else { throw StoreError.notSelfStore }
        try await add(urls: [url], fallbackName: comps.host ?? t)
    }

    func add(nearby: NearbyMac) async throws {
        try await add(urls: nearby.urls, fallbackName: nearby.name)
    }

    /// selfstore://add?url=<base>, or an .ipa file shared to the app.
    func handle(openURL url: URL) async throws {
        if url.isFileURL {
            guard url.pathExtension.lowercased() == "ipa" else { return }
            pendingUpload = PendingFile(url: url)
            return
        }
        guard url.scheme == SelfStoreConstants.urlScheme,
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let base = URL(string: target) else { return }
        try await add(urls: [base], fallbackName: base.host ?? "Mac")
    }

    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        states[id] = nil
        save()
    }

    func move(from: IndexSet, to: Int) {
        servers.move(fromOffsets: from, toOffset: to)
        save()
    }

    func install(_ v: CatalogVersion) {
        guard let s = v.installURL, let url = URL(string: s) else { return }
        UIApplication.shared.open(url)
    }

    func openRegistration(_ id: UUID) {
        guard let ts = server(id)?.tailscaleURL else { return }
        UIApplication.shared.open(ts.appendingPathComponent("register"))
    }
}

/// Reports upload progress (bytes sent / total).
final class UploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: (Double) -> Void
    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

// MARK: - Bonjour discovery

struct NearbyMac: Identifiable, Hashable {
    var name: String
    var host: String?
    var port: Int?
    var tailscaleURL: URL?
    var id: String { name }

    var lanURL: URL? {
        guard let host else { return nil }
        return URL(string: "http://\(host):\(port ?? Int(SelfStoreConstants.defaultHTTPPort))")
    }
    var urls: [URL] { [lanURL, tailscaleURL].compactMap { $0 } }
}

@MainActor @Observable
final class BonjourBrowser {
    private(set) var macs: [NearbyMac] = []
    private(set) var denied = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: SelfStoreConstants.bonjourType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            let found: [NearbyMac] = results.compactMap { r in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var mac = NearbyMac(name: name)
                if case let .bonjour(txt) = r.metadata {
                    let d = txt.dictionary
                    mac.host = d["host"]
                    mac.port = d["port"].flatMap(Int.init)
                    mac.tailscaleURL = d["ts"].flatMap(URL.init(string:))
                }
                return mac
            }
            Task { @MainActor in self.macs = found.sorted { $0.name < $1.name } }
        }
        b.stateUpdateHandler = { state in
            if case .waiting = state { Task { @MainActor in self.denied = true } }
            if case .ready = state { Task { @MainActor in self.denied = false } }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() { browser?.cancel(); browser = nil }
}
