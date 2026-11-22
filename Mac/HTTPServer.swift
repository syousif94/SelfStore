import Foundation
import Network

struct HTTPRequest {
    enum Body {
        case none
        case data(Data)
        case file(URL)
    }

    var method: String
    var path: String                 // percent-decoded, no query
    var query: [String: String]
    var headers: [String: String]    // lowercased keys
    var body: Body
    var remoteIsLoopback: Bool

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// True when the request came straight from this Mac (not proxied through `tailscale serve`).
    var isLocalDirect: Bool {
        remoteIsLoopback && header("x-forwarded-for") == nil && header("tailscale-user-login") == nil
    }

    var isViaTailscale: Bool { header("tailscale-user-login") != nil || (header("x-forwarded-for") != nil && remoteIsLoopback) }

    var bodyData: Data? {
        switch body {
        case .none: return nil
        case .data(let d): return d
        case .file(let u): return try? Data(contentsOf: u, options: .alwaysMapped)
        }
    }
}

struct HTTPResponse {
    enum Body {
        case data(Data)
        case file(URL)
    }

    var status: Int
    var headers: [String: String]
    var body: Body

    init(status: Int = 200, headers: [String: String] = [:], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONEncoder.selfStore.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: .data(data))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    static func text(_ s: String, type: String = "text/plain; charset=utf-8", status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": type], body: .data(Data(s.utf8)))
    }

    static func file(_ url: URL, type: String) -> HTTPResponse {
        guard FileManager.default.fileExists(atPath: url.path) else { return .error(404, "Not found") }
        return HTTPResponse(headers: ["Content-Type": type], body: .file(url))
    }
}

/// Minimal HTTP/1.1 server on Network.framework. One request per connection (Connection: close),
/// bodies over 1 MB stream to a temp file, file responses stream in chunks and support single byte ranges.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let port: NWEndpoint.Port
    private let handler: Handler
    private let queue = DispatchQueue(label: "selfstore.http")
    private var listener: NWListener?
    var onStateChange: (@Sendable (String) -> Void)?
    var bonjour: (name: String, txt: [String: String])? {
        didSet { queue.async { self.applyService() } }
    }

    init(port: UInt16, handler: @escaping Handler) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: port)
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStateChange?("ready")
            case .failed(let e): self?.onStateChange?("failed: \(e.localizedDescription)")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Connection(conn, queue: self.queue, handler: self.handler).start()
        }
        listener = l
        applyService()
        l.start(queue: queue)
    }

    private func applyService() {
        guard let listener, let bonjour else { return }
        listener.service = NWListener.Service(name: bonjour.name, type: SelfStoreConstants.bonjourType,
                                              domain: nil, txtRecord: NWTXTRecord(bonjour.txt))
    }

    func stop() { listener?.cancel(); listener = nil }
}

private final class Connection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var buffer = Data()
    private var headerParsed = false
    private var request: HTTPRequest?
    private var expected = 0
    private var received = 0
    private var bodyFile: FileHandle?
    private var bodyURL: URL?
    private var bodyData = Data()

    static let maxHeader = 64 * 1024
    static let memoryBodyLimit = 1 << 20
    static let maxBody = 8 << 30

    init(_ conn: NWConnection, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.conn = conn
        self.queue = queue
        self.handler = handler
    }

    /// Keeps connections alive until Network.framework reports them cancelled. Touched only on `queue`.
    nonisolated(unsafe) private static var live: [ObjectIdentifier: Connection] = [:]

    func start() {
        let key = ObjectIdentifier(self)
        Self.live[key] = self
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: self?.cleanup(); self?.conn.cancel()
            case .cancelled: Connection.live[key] = nil
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    private var isLoopback: Bool {
        if case .hostPort(let host, _) = conn.endpoint {
            switch host {
            case .ipv4(let a): return a.isLoopback
            case .ipv6(let a):
                if a.isLoopback { return true }
                // IPv4-mapped loopback (::ffff:127.0.0.1)
                return "\(a)".hasPrefix("::ffff:127.")
            case .name(let n, _): return n == "localhost"
            @unknown default: return false
            }
        }
        return false
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if error != nil || (isComplete && self.request == nil) || (isComplete && self.received < self.expected) {
                self.cleanup()
                self.conn.cancel()
                return
            }
            if self.request == nil || self.received < self.expected { self.receive() }
        }
    }

    private func consume(_ data: Data) {
        if !headerParsed {
            buffer.append(data)
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.maxHeader { respond(.error(431, "Header too large")) }
                return
            }
            headerParsed = true
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            let rest = buffer[end.upperBound...]
            buffer = Data()
            guard var req = parseHead(head) else { respond(.error(400, "Bad request")); return }
            if req.header("transfer-encoding")?.lowercased().contains("chunked") == true {
                respond(.error(411, "Chunked bodies are not supported; send Content-Length (curl --data-binary @file)"))
                return
            }
            expected = Int(req.header("content-length") ?? "0") ?? 0
            guard expected >= 0, expected <= Self.maxBody else { respond(.error(413, "Body too large")); return }
            if expected > Self.memoryBodyLimit {
                let url = AppLibrary.makeIncomingURL()
                FileManager.default.createFile(atPath: url.path, contents: nil)
                bodyURL = url
                bodyFile = try? FileHandle(forWritingTo: url)
                req.body = .file(url)
            }
            request = req
            appendBody(Data(rest))
        } else {
            appendBody(data)
        }
        if let req = request, received >= expected { dispatch(req) }
    }

    private func appendBody(_ d: Data) {
        guard !d.isEmpty else { return }
        let slice = d.prefix(expected - received)
        received += slice.count
        if let bodyFile { bodyFile.write(slice) } else { bodyData.append(slice) }
    }

    private var dispatched = false
    private func dispatch(_ req: HTTPRequest) {
        guard !dispatched else { return }
        dispatched = true
        var req = req
        try? bodyFile?.close()
        bodyFile = nil
        if bodyURL == nil { req.body = bodyData.isEmpty ? .none : .data(bodyData) }
        let handler = self.handler
        Task {
            let resp = await handler(req)
            self.queue.async { self.send(resp, head: req.method == "HEAD", range: req.header("range")) }
        }
    }

    private func respond(_ r: HTTPResponse) {
        dispatched = true
        send(r, head: false, range: nil)
    }

    private func parseHead(_ head: String) -> HTTPRequest? {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let path = comps?.percentEncodedPath.removingPercentEncoding ?? target
        return HTTPRequest(method: String(parts[0]).uppercased(), path: path, query: query,
                           headers: headers, body: .none, remoteIsLoopback: isLoopback)
    }

    // MARK: Response

    private func send(_ r: HTTPResponse, head: Bool, range: String?) {
        var status = r.status
        var headers = r.headers
        headers["Connection"] = "close"
        headers["Server"] = "SelfStore"
        headers["Access-Control-Allow-Origin"] = "*"

        switch r.body {
        case .data(let d):
            headers["Content-Length"] = "\(d.count)"
            let out = headerBlock(status, headers) + (head ? Data() : d)
            conn.send(content: out, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.finish() })
        case .file(let url):
            guard let fh = try? FileHandle(forReadingFrom: url) else {
                send(.error(404, "Not found"), head: head, range: nil); return
            }
            let total = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
            var start: Int64 = 0, end: Int64 = max(total - 1, 0)
            headers["Accept-Ranges"] = "bytes"
            if let range, status == 200, let (s, e) = Self.parseRange(range, total: total) {
                start = s; end = e; status = 206
                headers["Content-Range"] = "bytes \(s)-\(e)/\(total)"
            }
            let length = total == 0 ? 0 : end - start + 1
            headers["Content-Length"] = "\(length)"
            conn.send(content: headerBlock(status, headers), completion: .contentProcessed { _ in })
            if head || length == 0 { try? fh.close(); finishSending(); return }
            try? fh.seek(toOffset: UInt64(start))
            pump(fh, remaining: length)
        }
    }

    private func pump(_ fh: FileHandle, remaining: Int64) {
        let chunk = Int(min(remaining, 512 * 1024))
        let data = (try? fh.read(upToCount: chunk)) ?? Data()
        if data.isEmpty { try? fh.close(); finishSending(); return }
        let left = remaining - Int64(data.count)
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil || left <= 0 { try? fh.close(); self.finishSending(); return }
            self.pump(fh, remaining: left)
        })
    }

    private func finishSending() {
        conn.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    private func finish() {
        cleanup()
        conn.cancel()
    }

    private func cleanup() {
        try? bodyFile?.close()
        bodyFile = nil
        // Upload handlers move the temp file away on success; delete leftovers.
        if let bodyURL { try? FileManager.default.removeItem(at: bodyURL); self.bodyURL = nil }
    }

    private func headerBlock(_ status: Int, _ headers: [String: String]) -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        return Data(s.utf8)
    }

    static func parseRange(_ header: String, total: Int64) -> (Int64, Int64)? {
        guard total > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard spec.count == 2 else { return nil }
        if spec[0].isEmpty, let suffix = Int64(spec[1]), suffix > 0 {
            return (max(total - suffix, 0), total - 1)
        }
        guard let s = Int64(spec[0]), s < total else { return nil }
        let e = spec[1].isEmpty ? total - 1 : min(Int64(spec[1]) ?? total - 1, total - 1)
        return e >= s ? (s, e) : nil
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: "OK"; case 201: "Created"; case 204: "No Content"; case 206: "Partial Content"
        case 301: "Moved Permanently"; case 302: "Found"; case 202: "Accepted"; case 403: "Forbidden"; case 502: "Bad Gateway"; case 400: "Bad Request"; case 401: "Unauthorized"; case 404: "Not Found"
        case 405: "Method Not Allowed"; case 409: "Conflict"; case 411: "Length Required"
        case 413: "Payload Too Large"; case 422: "Unprocessable Entity"; case 431: "Request Header Fields Too Large"
        default: "Status"
        }
    }
}
