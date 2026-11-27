import AppKit
import Foundation
import Observation
import SystemConfiguration

@MainActor @Observable
final class ServerController {
    static let shared = ServerController()

    private(set) var state = "Starting…"
    private(set) var lastEvent: String?
    private var server: HTTPServer?

    private var library: AppLibrary { .shared }
    private var tailscale: TailscaleManager { .shared }
    private var settings: Settings { .shared }
    private var signing: SigningManager { .shared }
    private var projects: ProjectStore { .shared }
    private var repos: RepoStore { .shared }

    func noteEvent(_ s: String) { lastEvent = s }

    /// The SelfStore iOS app itself, when it's hosted here.
    static let iOSBundleId = "com.sammyyousif.selfstore"
    var iOSApp: StoredApp? { library.app(Self.iOSBundleId) }

    /// Shareable https link that installs the SelfStore iPhone app (Safari page with an Install button).
    var getAppURL: String { "\(installBase ?? lanURL.absoluteString)/get" }

    private func getAppPage(_ req: HTTPRequest) -> String {
        let base = installBase ?? browseBase(for: req)
        guard let app = iOSApp else {
            return DevicePages.simplePage(title: "SelfStore for iPhone",
                body: "<p>The SelfStore iPhone app isn't hosted on \(macName) yet. Build the SelfStoreiOS project in SelfStore's Library, or upload its .ipa.</p>",
                base: base)
        }
        let v = catalogVersion(app.latest, req)
        return DevicePages.getAppPage(version: v, base: base, iconURL: v.iconPath.map { base + $0 },
                                      signingEnabled: signing.credentials != nil, macName: macName)
    }

    func catalogProject(_ p: StoredProject) -> CatalogProject {
        let app = p.bundleId.flatMap { library.app($0) }
        let b = p.lastBuild
        let out = projects.outputDir(p.id)
        let macIcon = p.isMac && FileManager.default.fileExists(atPath: out.appendingPathComponent("icon.png").path)
        let artifacts = p.isMac ? (b?.artifacts ?? []).compactMap { name -> CatalogArtifact? in
            let url = out.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return CatalogArtifact(name: name, path: "/api/projects/\(p.id)/files/\(name)", size: AppLibrary.fileSize(url))
        } : nil
        return CatalogProject(
            id: p.id, name: p.name, fileName: p.fileName, bundleId: p.bundleId,
            iconPath: macIcon ? "/api/projects/\(p.id)/files/icon.png"
                : app.flatMap { $0.versions.contains(where: \.hasIcon) ? "/apps/\($0.bundleId)/icon.png" : nil },
            state: b?.state.rawValue, step: b?.step, startedAt: b?.startedAt, finishedAt: b?.finishedAt,
            error: b?.error, logTail: b?.logTail, versionId: b?.versionId,
            signingReady: p.isMac ? signing.developerID != nil : signing.isReady,
            platform: (p.platform ?? .ios).rawValue, version: b?.version, artifacts: artifacts,
            notarized: b?.notarized, warnings: b?.warnings,
            repoId: p.repoId, branch: p.branch, commit: b?.commit)
    }

    func catalogRepo(_ r: StoredRepo) -> CatalogRepo {
        CatalogRepo(id: r.id, name: r.name, url: r.url, defaultBranch: r.defaultBranch,
                    state: repos.isPulling(r.id) ? "pulling" : r.state.rawValue, step: r.step, error: r.error, lastPull: r.lastPull,
                    branches: r.branches.map { CatalogRepoBranch(name: $0.name, commit: $0.commit, subject: $0.subject, error: $0.error) },
                    targets: r.targets.map {
                        CatalogRepoTarget(id: $0.id, name: $0.name, branch: $0.branch, kind: $0.kind.rawValue, path: $0.path,
                                          projectId: $0.projectId,
                                          bundleId: $0.kind == .project ? $0.projectId.flatMap { projects.project($0)?.bundleId } : $0.bundleId,
                                          error: $0.error)
                    })
    }

    /// Shared secret baked into the registration profile, so random POSTs can't register devices.
    var enrollSecret: String {
        if let s = UserDefaults.standard.string(forKey: "enrollSecret") { return s }
        let s = Settings.newToken()
        UserDefaults.standard.set(s, forKey: "enrollSecret")
        return s
    }

    /// iOS posts the signed device attributes here after the registration profile is installed.
    private func enroll(_ req: HTTPRequest) async -> HTTPResponse {
        let back = installBase ?? browseBase(for: req)
        func redirect(_ query: String) -> HTTPResponse {
            HTTPResponse(status: 301, headers: ["Location": "\(back)/registered?\(query)"])
        }
        guard req.query["c"] == enrollSecret else { return .error(403, "Bad registration link") }
        guard let body = req.bodyData, let attrs = Signer.plist(inProfile: body),
              let udid = attrs["UDID"] as? String else {
            return redirect("error=" + "Couldn't read the device details".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        }
        let product = attrs["PRODUCT"] as? String ?? "iPhone"
        let name = (attrs["DEVICE_NAME"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? product
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        do {
            try await signing.registerDevice(udid: udid, name: name)
            note("Registered \(name)")
            return redirect("name=\(enc(name))")
        } catch {
            return redirect("name=\(enc(name))&error=\(enc(error.localizedDescription))")
        }
    }

    var macName: String {
        #if DEBUG
        if let demo = UserDefaults.standard.string(forKey: "demoMacName") { return demo }
        #endif
        return Host.current().localizedName ?? "Mac"
    }
    var localHostName: String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" } ?? ProcessInfo.processInfo.hostName
    }
    var lanURL: URL { URL(string: "http://\(localHostName):\(settings.httpPort)")! }
    var localhostURL: URL { URL(string: "http://localhost:\(settings.httpPort)")! }

    func start() {
        guard server == nil else { return }
        let s = HTTPServer(port: settings.httpPort) { req in await ServerController.shared.handle(req) }
        s.onStateChange = { st in Task { @MainActor in ServerController.shared.state = st == "ready" ? "Running" : st } }
        do {
            try s.start()
            server = s
            updateBonjour()
        } catch {
            state = "Could not listen on port \(settings.httpPort): \(error.localizedDescription)"
        }
    }

    func updateBonjour() {
        var txt = ["v": "1", "host": localHostName, "port": "\(settings.httpPort)"]
        if let ts = tailscale.baseURL { txt["ts"] = ts.absoluteString }
        server?.bonjour = (name: macName, txt: txt)
    }

    // MARK: - Routing

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let parts = req.path.split(separator: "/").map(String.init)
        let m = req.method == "HEAD" ? "GET" : req.method
        do {
            switch (m, parts.first) {
            case ("OPTIONS", _):
                return HTTPResponse(status: 204, headers: [
                    "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
                    "Access-Control-Allow-Headers": "Authorization, Content-Type",
                ])
            case ("GET", nil):
                return .text(WebPage.render(apps: catalog(for: req), info: info(for: req), base: browseBase(for: req)),
                             type: "text/html; charset=utf-8")
            case (_, "api"):
                return try await api(req, method: m, Array(parts.dropFirst()))
            case ("GET", "get"):
                return .text(getAppPage(req), type: "text/html; charset=utf-8")
            case ("GET", "register"):
                return .text(DevicePages.registerPage(base: installBase ?? browseBase(for: req), ready: signing.credentials != nil),
                             type: "text/html; charset=utf-8")
            case ("GET", "register.mobileconfig"):
                return HTTPResponse(headers: ["Content-Type": "application/x-apple-aspen-config",
                                              "Content-Disposition": "attachment; filename=\"SelfStore.mobileconfig\""],
                                    body: .data(DevicePages.enrollProfile(base: installBase ?? browseBase(for: req),
                                                                          secret: enrollSecret, macName: macName)))
            case ("GET", "registered"):
                return .text(DevicePages.registeredPage(name: req.query["name"] ?? "Your device", error: req.query["error"],
                                                        base: browseBase(for: req)),
                             type: "text/html; charset=utf-8")
            case ("GET", "agents.md"):
                return .text(AgentDocs.markdown(self), type: "text/markdown; charset=utf-8")
            case ("GET", "apps"):
                return files(req, Array(parts.dropFirst()))
            default:
                return .error(404, "Not found")
            }
        } catch let e as LibraryError {
            if case .duplicate = e { return .error(409, e.localizedDescription) }
            return .error(404, e.localizedDescription)
        } catch let e as ProjectError {
            return .error(422, e.localizedDescription)
        } catch let e as ASCError {
            return .error(502, e.localizedDescription)
        } catch let e as Signer.SignError {
            return .error(422, e.localizedDescription)
        } catch let e as Shell.Failure {
            return .error(422, e.localizedDescription)
        } catch let e as IPAInspector.InspectError {
            return .error(422, e.localizedDescription)
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    private func api(_ req: HTTPRequest, method: String, _ p: [String]) async throws -> HTTPResponse {
        switch (method, p.count) {
        case ("GET", 0):
            return .text(AgentDocs.markdown(self), type: "text/markdown; charset=utf-8")
        case ("GET", 1) where p[0] == "docs":
            return .text(AgentDocs.markdown(self), type: "text/markdown; charset=utf-8")
        case ("GET", 1) where p[0] == "info":
            return .json(info(for: req))
        case ("GET", 1) where p[0] == "apps":
            return .json(catalog(for: req))
        case ("GET", 2) where p[0] == "apps":
            guard let app = library.app(p[1]) else { throw LibraryError.notFound }
            return .json(catalogApp(app, req))
        case ("GET", 3) where p[0] == "apps":
            guard let app = library.app(p[1]), let v = resolve(app, p[2]) else { throw LibraryError.notFound }
            return .json(catalogVersion(v, req))
        case ("GET", 1) where p[0] == "projects":
            return .json(projects.projects.map(catalogProject))
        case ("GET", 2) where p[0] == "projects":
            guard let proj = projects.project(p[1]) else { throw LibraryError.notFound }
            return .json(catalogProject(proj))
        case ("GET", 3) where p[0] == "projects" && p[2] == "log":
            return .file(projects.logURL(p[1]), type: "text/plain; charset=utf-8")
        case ("GET", 4) where p[0] == "projects" && p[2] == "files":
            // Only the files the last Mac build produced (plus its icon).
            guard let proj = projects.project(p[1]),
                  p[3] == "icon.png" || (proj.lastBuild?.artifacts ?? []).contains(p[3]) else { throw LibraryError.notFound }
            let url = projects.outputDir(proj.id).appendingPathComponent(p[3])
            guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.notFound }
            if p[3] == "icon.png" { return .file(url, type: "image/png") }
            var r = HTTPResponse.file(url, type: p[3].hasSuffix(".dmg") ? "application/x-apple-diskimage" : "application/zip")
            r.headers["Content-Disposition"] = "attachment; filename=\"\(p[3])\""
            return r
        // Starting/cancelling a build of an already-added project is allowed from any tailnet device (the iOS app).
        case ("POST", 3) where p[0] == "projects" && p[2] == "build":
            try projects.build(p[1])
            return .json(projects.project(p[1]).map(catalogProject), status: 202)
        case ("POST", 3) where p[0] == "projects" && p[2] == "cancel":
            projects.cancel(p[1])
            return .json(projects.project(p[1]).map(catalogProject))
        // Like builds, TestFlight uploads can be started from any tailnet device (the iOS app).
        case ("POST", 4) where p[0] == "apps" && p[3] == "testflight":
            guard let app = library.app(p[1]), let v = resolve(app, p[2]) else { throw LibraryError.notFound }
            guard signing.credentials != nil else { return .error(409, "TestFlight needs an App Store Connect API key on this Mac") }
            try TestFlightUploader.shared.upload(app.bundleId, v.id)
            note("Uploading \(app.name) \(v.displayVersion) to TestFlight")
            return .json(library.version(app.bundleId, v.id).map { catalogVersion($0, req) }, status: 202)
        case ("GET", 1) where p[0] == "repos":
            return .json(repos.repos.map(catalogRepo))
        case ("GET", 2) where p[0] == "repos":
            guard let r = repos.repo(p[1]) else { throw LibraryError.notFound }
            return .json(catalogRepo(r))
        // Pulling (and building) an added repo is allowed from any tailnet device, like builds.
        case ("POST", 3) where p[0] == "repos" && p[2] == "pull":
            guard repos.repo(p[1]) != nil else { throw LibraryError.notFound }
            let mode: RepoStore.BuildMode? = switch req.query["build"] {
                case "all": .all
                case "true", "changed": .changed
                default: nil
            }
            repos.pull(p[1], build: mode)
            return .json(repos.repo(p[1]).map(catalogRepo), status: 202)
        case ("POST", 3) where p[0] == "repos" && p[2] == "build":
            guard repos.repo(p[1]) != nil else { throw LibraryError.notFound }
            repos.queueBuilds(p[1], mode: req.query["all"] == "true" ? .all : .changed)
            return .json(repos.repo(p[1]).map(catalogRepo), status: 202)
        // The iOS app uploads .ipa files and adds repos over Tailscale without the API token.
        case ("POST", 1) where p[0] == "apps" && req.isViaTailscale:
            return try await upload(req)
        case ("POST", 1) where p[0] == "repos" && (req.isViaTailscale || authorized(req)):
            return try addRepo(req)
        // The bundle ID prefix can be changed from the iOS app (over Tailscale), like uploads.
        case ("PATCH", 1) where p[0] == "settings" && (req.isViaTailscale || authorized(req)):
            return try updateSettings(req)
        case ("GET", 1) where p[0] == "signing":
            return .json(signing.apiStatus)
        case ("GET", 1) where p[0] == "devices":
            return .json(signing.apiStatus.devices)
        case ("POST", 2) where p[0] == "devices" && p[1] == "enroll":
            return await enroll(req)
        default: break
        }

        // Everything below changes the library. The iOS app may delete apps, versions, projects and repos
        // (and prune old versions) over Tailscale without the token, like uploads.
        let phoneCleanup = req.isViaTailscale
            && (method == "DELETE" && ["apps", "projects", "repos"].contains(p.first ?? "")
                || method == "POST" && p.count == 3 && p[0] == "apps" && p[2] == "prune")
        guard phoneCleanup || authorized(req) else {
            return .error(401, "Uploads from other machines need 'Authorization: Bearer <token>' (token is in SelfStore Settings).")
        }
        switch (method, p.count) {
        case ("POST", 1) where p[0] == "apps":
            return try await upload(req)
        case ("POST", 3) where p[0] == "apps" && p[2] == "prune":
            let keep = Int(req.query["keep"] ?? "") ?? 3
            let removed = try library.prune(bundleId: p[1], keep: keep)
            note("Pruned \(removed.count) old version(s) of \(p[1])")
            return .json(["removed": removed])
        case ("PATCH", 3) where p[0] == "apps":
            let body = (req.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            guard let app = library.app(p[1]), let v = resolve(app, p[2]) else { throw LibraryError.notFound }
            let notes = (body["notes"] as? String) ?? req.query["notes"]
            let updated = try library.updateNotes(app.bundleId, v.id, notes: notes)
            return .json(catalogVersion(updated, req))
        case ("POST", 1) where p[0] == "projects":
            let body = (req.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            guard let path = (body["path"] as? String) ?? req.query["path"] else {
                return .error(400, "Send {\"path\": \"/abs/App.xcodeproj\", \"scheme\": \"App\"}")
            }
            var proj = try await projects.add(path: path, scheme: (body["scheme"] as? String) ?? req.query["scheme"])
            if let raw = (body["platform"] as? String) ?? req.query["platform"] {
                guard let platform = StoredProject.Platform(rawValue: raw) else { return .error(400, "platform must be ios or macos") }
                projects.setPlatform(proj.id, platform)
                proj.platform = platform
            }
            if (body["build"] as? Bool) == true || req.query["build"] == "true" { try projects.build(proj.id) }
            return .json(catalogProject(projects.project(proj.id) ?? proj), status: 201)
        case ("DELETE", 2) where p[0] == "projects":
            guard let proj = projects.project(p[1]) else { throw LibraryError.notFound }
            guard !proj.isFromRepo else { return .error(409, "This project comes from a repo; remove the repo or edit its selfstore.yml") }
            projects.remove(p[1])
            return HTTPResponse(status: 204)
        case ("PATCH", 2) where p[0] == "projects":
            guard projects.project(p[1]) != nil else { throw LibraryError.notFound }
            let body = (req.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            if let on = body["exportToRepo"] as? Bool { projects.setExportToRepo(p[1], on) }
            if let on = body["autoBuildNumber"] as? Bool { projects.setAutoBuildNumber(p[1], on) }
            return .json(projects.project(p[1]).map(catalogProject))
        case ("DELETE", 2) where p[0] == "repos":
            guard repos.repo(p[1]) != nil else { throw LibraryError.notFound }
            repos.remove(p[1])
            return HTTPResponse(status: 204)
        case ("POST", 4) where p[0] == "apps" && p[3] == "resign":
            guard let app = library.app(p[1]), let v = resolve(app, p[2]) else { throw LibraryError.notFound }
            let updated = try await library.resign(app.bundleId, v.id)
            note("Re-signed \(app.name) \(updated.displayVersion)")
            return .json(catalogVersion(updated, req))
        case ("POST", 1) where p[0] == "resign-all":
            guard signing.credentials != nil else { return .error(409, "Signing isn't set up") }
            signing.resignAllInBackground()
            return .json(["status": "started"], status: 202)
        case ("POST", 2) where p[0] == "signing" && p[1] == "refresh":
            await signing.refresh()
            return .json(signing.apiStatus)
        case ("GET", 2) where p[0] == "settings" && p[1] == "builds-folder":
            return .json(buildsFolderStatus())
        case ("PUT", 2) where p[0] == "settings" && p[1] == "builds-folder":
            // Local only: moves every project's build folder on this Mac, like the Settings button.
            guard req.isLocalDirect else { return .error(403, "Change the builds folder from this Mac") }
            let body = (req.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            let raw = (body["path"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard raw.isEmpty || raw.hasPrefix("/") else { return .error(400, "path must be absolute, or empty/null for the default") }
            do {
                try await projects.setBuildsFolder(raw.isEmpty ? nil : URL(fileURLWithPath: raw, isDirectory: true))
            } catch let e as ProjectError {
                return .error(409, e.localizedDescription)
            }
            note("Builds folder set to \(settings.buildsRoot.path)")
            return .json(buildsFolderStatus())
        case ("POST", 2) where p[0] == "signing" && p[1] == "developer-id":
            // Local only: creates a Developer ID Application certificate with the API key, like the Settings button.
            guard req.isLocalDirect else { return .error(403, "Create the certificate from this Mac") }
            if signing.developerID == nil { try await signing.createDeveloperIDCertificate() }
            return .json(signing.apiStatus, status: 201)
        case ("POST", 2) where p[0] == "signing" && p[1] == "key":
            // Local only: lets a setup script hand over a .p8 without the UI.
            guard req.isLocalDirect else { return .error(403, "Import the API key from this Mac") }
            guard let keyID = req.query["keyId"], let issuer = req.query["issuerId"],
                  let pem = req.bodyData.map({ String(decoding: $0, as: UTF8.self) }) else {
                return .error(400, "POST the .p8 contents with ?keyId=…&issuerId=…")
            }
            try await signing.importKey(p8: pem, keyID: keyID, issuerID: issuer)
            return .json(signing.apiStatus)
        case ("POST", 1) where p[0] == "devices":
            let body = (req.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            guard let udid = (body["udid"] as? String) ?? req.query["udid"] else { return .error(400, "Send {\"udid\": …, \"name\": …}") }
            try await signing.registerDevice(udid: udid, name: (body["name"] as? String) ?? req.query["name"] ?? "iPhone")
            return .json(signing.apiStatus.devices, status: 201)
        case ("DELETE", 2) where p[0] == "apps":
            try library.delete(bundleId: p[1])
            note("Deleted \(p[1])")
            return HTTPResponse(status: 204)
        case ("DELETE", 3) where p[0] == "apps":
            guard let app = library.app(p[1]), let v = resolve(app, p[2]) else { throw LibraryError.notFound }
            try library.delete(bundleId: app.bundleId, versionId: v.id)
            note("Deleted \(app.name) \(v.displayVersion)")
            return HTTPResponse(status: 204)
        default:
            return .error(404, "Unknown API route \(method) /api/\(p.joined(separator: "/")). See GET /api/docs")
        }
    }

    private func authorized(_ req: HTTPRequest) -> Bool {
        if req.isLocalDirect { return true }
        let token = settings.apiToken
        if let auth = req.header("authorization"), auth == "Bearer \(token)" { return true }
        return req.query["token"] == token
    }

    private func addRepo(_ req: HTTPRequest) throws -> HTTPResponse {
        let body = (req.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        guard let url = (body["url"] as? String) ?? req.query["url"] else {
            return .error(400, "Send {\"url\": \"https://github.com/owner/repo\"}")
        }
        let build = (body["build"] as? Bool) == true || req.query["build"] == "true"
        let r = try repos.add(url: url, build: build)
        note("Added repo \(r.name)")
        return .json(catalogRepo(repos.repo(r.id) ?? r), status: 202)
    }

    private func upload(_ req: HTTPRequest) async throws -> HTTPResponse {
        var notes = req.query["notes"]
        let replace = (req.query["replace"] ?? "true") != "false"
        let resign: Bool? = req.query["resign"].map { $0 != "false" }
        var rename: Bool? = req.query["rename"].map { $0 != "false" }
        // `prefix=` moves this upload to a prefix other than the saved one (and implies rename unless rename=false).
        var prefix: String?
        if let raw = req.query["prefix"] {
            guard let clean = BundleRename.validPrefix(raw) else {
                return .error(400, "prefix must look like com.example (letters, digits, hyphens and dots)")
            }
            prefix = clean
            if rename == nil { rename = true }
        }
        let file: URL
        if let ct = req.header("content-type"), ct.lowercased().hasPrefix("multipart/form-data") {
            let form = try Multipart.parse(req, contentType: ct)
            guard let f = form.file else { return .error(400, "multipart upload needs a file field (e.g. -F ipa=@App.ipa)") }
            file = f
            if notes == nil { notes = form.fields["notes"] }
        } else {
            switch req.body {
            case .file(let u):
                // Take ownership so the connection cleanup doesn't delete it mid-import.
                let owned = AppLibrary.makeIncomingURL()
                try FileManager.default.moveItem(at: u, to: owned)
                file = owned
            case .data(let d):
                file = AppLibrary.makeIncomingURL()
                try d.write(to: file)
            case .none:
                return .error(400, "Send the .ipa as the request body: curl --data-binary @App.ipa \(localhostURL)/api/apps")
            }
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let label = req.isLocalDirect ? "Upload" : req.isViaTailscale ? "Upload from \(req.header("tailscale-user-name") ?? "the tailnet")" : "Upload"
        let v = try await library.importIPA(at: file, move: true, notes: notes, replace: replace, resign: resign,
                                            rename: rename, prefix: prefix, sourceLabel: label)
        if let keep = req.query["keep"].flatMap(Int.init) { _ = try? library.prune(bundleId: v.bundleId, keep: keep) }
        note("Added \(v.name) \(v.displayVersion)")
        return .json(catalogVersion(v, req), status: 201)
    }

    /// `PATCH /api/settings` with `{"bundlePrefix": "com.example", "renameImports": true}` (either key optional).
    private func buildsFolderStatus() -> [String: String] {
        ["path": settings.buildsRoot.path, "default": Settings.defaultBuildsRoot.path,
         "custom": settings.usesCustomBuildsFolder ? "true" : "false",
         "available": settings.buildsRootAvailable ? "true" : "false"]
    }

    private func updateSettings(_ req: HTTPRequest) throws -> HTTPResponse {
        let body = (req.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        if let raw = body["bundlePrefix"] as? String {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                settings.bundlePrefix = ""
            } else {
                guard let clean = BundleRename.validPrefix(raw) else {
                    return .error(400, "bundlePrefix must look like com.example (letters, digits, hyphens and dots)")
                }
                settings.bundlePrefix = clean
            }
        }
        if let on = body["renameImports"] as? Bool { settings.renameImports = on }
        note(settings.bundlePrefix.isEmpty ? "Cleared the bundle ID prefix" : "Bundle ID prefix set to \(settings.bundlePrefix)")
        return .json(info(for: req))
    }

    private func files(_ req: HTTPRequest, _ p: [String]) -> HTTPResponse {
        guard let first = p.first, let app = library.app(first) else { return .error(404, "Not found") }
        if p.count == 2, p[1] == "icon.png" {
            guard let v = app.versions.first(where: \.hasIcon) else { return .error(404, "No icon") }
            return .file(library.iconURL(v), type: "image/png")
        }
        guard p.count == 3, let v = resolve(app, p[1]) else { return .error(404, "Not found") }
        switch p[2] {
        case "icon.png": return .file(library.iconURL(v), type: "image/png")
        case "app.ipa":
            var r = HTTPResponse.file(library.ipaURL(v), type: "application/octet-stream")
            r.headers["Content-Disposition"] = "attachment; filename=\"\(LibraryFileName.ipa(v))\""
            return r
        case "manifest.plist":
            return .text(manifest(v), type: "text/xml; charset=utf-8")
        default: return .error(404, "Not found")
        }
    }

    private func resolve(_ app: StoredApp, _ id: String) -> StoredVersion? {
        id == "latest" ? app.latest : app.versions.first { $0.id == id }
    }

    private func note(_ s: String) {
        lastEvent = s
    }

    // MARK: - URLs and catalog

    /// Base URL for links a browser/client should follow (same origin it used).
    func browseBase(for req: HTTPRequest) -> String {
        if req.isViaTailscale, let ts = tailscale.baseURL { return ts.absoluteString }
        if let host = req.header("host"), !host.isEmpty { return "http://\(host)" }
        return lanURL.absoluteString
    }

    /// HTTPS base used for manifests/IPAs. iOS will only install from HTTPS with a trusted cert.
    var installBase: String? { tailscale.baseURL?.absoluteString }

    func installURL(_ v: StoredVersion) -> String? {
        guard let base = installBase else { return nil }
        let manifest = "\(base)/apps/\(v.bundleId)/\(v.id)/manifest.plist"
        let encoded = manifest.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? manifest
        return "itms-services://?action=download-manifest&url=\(encoded)"
    }

    func catalogVersion(_ v: StoredVersion, _ req: HTTPRequest?) -> CatalogVersion {
        let path = "/apps/\(v.bundleId)/\(v.id)"
        return CatalogVersion(
            id: v.id, bundleId: v.bundleId, name: v.name, version: v.version, build: v.build,
            uploadedAt: v.uploadedAt, size: v.size, notes: v.notes, minimumOSVersion: v.minimumOSVersion,
            expiresAt: v.expiresAt, provisionedDevices: v.provisionedDevices, teamName: v.teamName,
            iconPath: v.hasIcon ? "\(path)/icon.png" : nil, ipaPath: "\(path)/app.ipa",
            manifestPath: "\(path)/manifest.plist", installURL: installURL(v),
            testFlight: v.testFlight.map {
                CatalogTestFlight(state: $0.state.rawValue, step: $0.step, error: $0.error, startedAt: $0.startedAt, finishedAt: $0.finishedAt)
            },
            originalBundleId: v.originalBundleId, source: v.source)
    }

    func catalogApp(_ a: StoredApp, _ req: HTTPRequest?) -> CatalogApp {
        CatalogApp(bundleId: a.bundleId, name: a.name,
                   iconPath: a.versions.contains(where: \.hasIcon) ? "/apps/\(a.bundleId)/icon.png" : nil,
                   versions: a.versions.map { catalogVersion($0, req) })
    }

    func catalog(for req: HTTPRequest?) -> [CatalogApp] { library.apps.map { catalogApp($0, req) } }

    func info(for req: HTTPRequest?) -> ServerInfo {
        ServerInfo(service: "SelfStore", apiVersion: 1, name: macName, lanURL: lanURL.absoluteString,
                   tailscaleURL: tailscale.baseURL?.absoluteString, installsAvailable: tailscale.baseURL != nil,
                   appCount: library.apps.count, signingEnabled: signing.credentials != nil,
                   testFlightEnabled: signing.credentials != nil,
                   bundlePrefix: settings.renameImports && !settings.bundlePrefix.isEmpty ? settings.bundlePrefix : nil,
                   bundlePrefixSetting: settings.bundlePrefix, renameImports: settings.renameImports,
                   reposEnabled: true)
    }

    private func manifest(_ v: StoredVersion) -> String {
        let base = installBase ?? lanURL.absoluteString
        let path = "\(base)/apps/\(v.bundleId)/\(v.id)"
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let images = v.hasIcon ? """
                <dict><key>kind</key><string>display-image</string><key>needs-shine</key><false/><key>url</key><string>\(esc(path))/icon.png</string></dict>
                <dict><key>kind</key><string>full-size-image</string><key>needs-shine</key><false/><key>url</key><string>\(esc(path))/icon.png</string></dict>
        """ : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>items</key><array><dict>
            <key>assets</key><array>
              <dict><key>kind</key><string>software-package</string><key>url</key><string>\(esc(path))/app.ipa</string></dict>
        \(images)
            </array>
            <key>metadata</key><dict>
              <key>bundle-identifier</key><string>\(esc(v.bundleId))</string>
              <key>bundle-version</key><string>\(esc(v.version))</string>
              <key>kind</key><string>software</string>
              <key>subtitle</key><string>\(esc(v.displayVersion))</string>
              <key>title</key><string>\(esc(v.name))</string>
            </dict>
          </dict></array>
        </dict></plist>
        """
    }
}

enum LibraryFileName {
    static func ipa(_ v: StoredVersion) -> String {
        AppLibrary.safeComponent("\(v.name)-\(v.id)") + ".ipa"
    }
}

/// Just enough multipart/form-data parsing for `curl -F ipa=@App.ipa -F notes=...`.
enum Multipart {
    struct Form { var file: URL?; var fields: [String: String] = [:] }

    static func parse(_ req: HTTPRequest, contentType: String) throws -> Form {
        guard let bRange = contentType.range(of: "boundary=") else { throw Shell.Failure(message: "multipart boundary missing") }
        var boundary = String(contentType[bRange.upperBound...])
        if let semi = boundary.firstIndex(of: ";") { boundary = String(boundary[..<semi]) }
        boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard let data = req.bodyData else { throw Shell.Failure(message: "empty body") }
        let delimiter = Data("--\(boundary)".utf8)
        let crlf2 = Data("\r\n\r\n".utf8)
        var form = Form()
        var cursor = data.startIndex
        guard let first = data.range(of: delimiter, in: cursor..<data.endIndex) else { return form }
        cursor = first.upperBound
        while cursor < data.endIndex {
            // "--" after delimiter = end
            if data[cursor...].starts(with: Data("--".utf8)) { break }
            guard let headEnd = data.range(of: crlf2, in: cursor..<data.endIndex) else { break }
            let head = String(decoding: data[cursor..<headEnd.lowerBound], as: UTF8.self)
            guard let next = data.range(of: Data("\r\n".utf8) + delimiter, in: headEnd.upperBound..<data.endIndex) else { break }
            let content = data[headEnd.upperBound..<next.lowerBound]
            let name = head.firstMatch(of: /name="([^"]*)"/).map { String($0.1) } ?? ""
            if head.contains("filename=") {
                if form.file == nil {
                    let url = AppLibrary.makeIncomingURL()
                    try Data(content).write(to: url)
                    form.file = url
                }
            } else {
                form.fields[name] = String(decoding: content, as: UTF8.self)
            }
            cursor = next.upperBound
        }
        return form
    }
}
