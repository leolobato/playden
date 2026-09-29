import Foundation
import Network
import Darwin

/// A one-page web server on the local network for stores whose login can't finish on the TV
/// (PRD 10 AR-MULTI-11). The phone opens the page from a QR code, signs in to the store in a new tab,
/// and pastes back the address the login ends on. The page lives under a random token, serves only
/// that page and its form, never logs what is pasted, and stops on success, on `stop()` or after
/// `timeout`.
public final class SignInRelay: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable { case signedIn, failed(String) }

    public let storeName: String
    public let loginURL: URL
    private let host: String?
    private let timeout: TimeInterval
    private let submit: @Sendable (String) async -> Outcome
    private let queue = DispatchQueue(label: "SignInRelay")
    private let token: String
    private var listener: NWListener?
    private var stopped = false
    private var timer: DispatchWorkItem?
    public var onStop: @Sendable () -> Void = {}

    /// `host` pins the address (tests use `127.0.0.1`); by default it is the Mac's LAN address.
    public init(storeName: String, loginURL: URL, host: String? = nil, timeout: TimeInterval = 600,
                submit: @escaping @Sendable (String) async -> Outcome) {
        self.storeName = storeName; self.loginURL = loginURL; self.host = host; self.timeout = timeout; self.submit = submit
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Starts listening and returns the page's address for the QR code.
    public func start() async throws -> URL {
        guard let address = host ?? Self.lanAddress() else { throw RelayError.noNetwork }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            // State updates arrive on `queue`, one at a time.
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready: once.done = true; continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): once.done = true; continuation.resume(throwing: error)
                case .cancelled: once.done = true; continuation.resume(throwing: RelayError.stopped)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let item = DispatchWorkItem { [weak self] in self?.stop() }
        timer = item
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
        return URL(string: "http://\(address):\(port)/\(token)")!
    }

    public func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            listener?.cancel()
            onStop()
        }
    }

    public enum RelayError: Error, LocalizedError {
        case noNetwork, stopped
        public var errorDescription: String? {
            switch self {
            case .noNetwork: "This Mac isn't on a network your phone can reach."
            case .stopped: "The sign-in page stopped."
            }
        }
    }

    private final class Once: @unchecked Sendable { var done = false }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) { self.respond(to: request, on: connection); return }
            if complete || error != nil || buffer.count > 65536 { connection.cancel(); return }
            self.receive(connection, buffer: buffer)
        }
    }

    struct Request: Equatable { var method: String; var path: String; var body: Data }

    /// A full request once the headers and the `Content-Length` body have arrived.
    static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return Request(method: "", path: "", body: Data()) }
        let length = lines.dropFirst().compactMap { line -> Int? in
            let pair = line.split(separator: ":", maxSplits: 1)
            return pair.count == 2 && pair[0].lowercased() == "content-length" ? Int(pair[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), body: Data(body.prefix(length)))
    }

    private func respond(to request: Request, on connection: NWConnection) {
        let path = request.path.split(separator: "?").first.map(String.init) ?? ""
        guard path == "/" + token else { send(status: "404 Not Found", html: Self.page(title: "Not found", body: "<p>This sign-in page has expired.</p>"), on: connection); return }
        guard !stopped else { send(status: "410 Gone", html: Self.page(title: "Sign-in closed", body: "<p>Start the sign-in again on the TV.</p>"), on: connection); return }
        switch request.method {
        case "GET": send(status: "200 OK", html: form(message: nil), on: connection)
        case "POST":
            let pasted = Self.formValue("address", in: request.body) ?? ""
            let submit = self.submit
            Task {
                let outcome = await submit(pasted)
                self.queue.async {
                    switch outcome {
                    case .signedIn:
                        self.send(status: "200 OK", html: Self.page(title: "Signed in", body: "<p class=ok>Signed in to \(Self.escape(self.storeName)). You can close this page.</p>"), on: connection)
                        self.stop()
                    case .failed(let reason):
                        self.send(status: "200 OK", html: self.form(message: reason), on: connection)
                    }
                }
            }
        default: send(status: "405 Method Not Allowed", html: "", on: connection)
        }
    }

    private func send(status: String, html: String, on connection: NWConnection) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Page

    private func form(message: String?) -> String {
        let name = Self.escape(storeName)
        let error = message.map { "<p class=error>\(Self.escape($0))</p>" } ?? ""
        return Self.page(title: "Sign in to \(name)", body: """
        <ol>
          <li><a class=button href="\(Self.escape(loginURL.absoluteString))" target="_blank" rel="noopener noreferrer">Open \(name) sign-in</a></li>
          <li>Sign in. You land on a mostly blank \(name) page.</li>
          <li>Copy that page's address from the address bar, then come back to this tab and paste it here.</li>
        </ol>
        \(error)
        <form method=post>
          <textarea name=address rows=4 placeholder="https://…code=…" autocapitalize=off autocorrect=off spellcheck=false required></textarea>
          <button type=submit>Send to Playden</button>
        </form>
        """)
    }

    static func page(title: String, body: String) -> String {
        """
        <!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
        <title>\(title) · Playden</title><style>
        :root{color-scheme:light dark;--bg:#f5f5f7;--fg:#1d1d1f;--card:#fff;--accent:#0a64d8;--err:#b3261e;--ok:#1b7f3b}
        @media (prefers-color-scheme:dark){:root{--bg:#111214;--fg:#f2f2f4;--card:#1c1d20;--accent:#5aa2ff;--err:#ff8a80;--ok:#6fdc8c}}
        body{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);font:17px/1.45 -apple-system,system-ui,sans-serif}
        main{max-width:520px;margin:0 auto;background:var(--card);border-radius:16px;padding:20px}
        h1{font-size:22px;margin:0 0 12px}ol{padding-left:20px}li{margin:8px 0}
        .button,button{display:inline-block;background:var(--accent);color:#fff;border:0;border-radius:10px;padding:12px 16px;font:inherit;font-weight:600;text-decoration:none}
        textarea{box-sizing:border-box;width:100%;margin:8px 0 12px;padding:10px;border-radius:10px;border:1px solid #8886;background:transparent;color:inherit;font:15px ui-monospace,monospace}
        button{width:100%}.error{color:var(--err)}.ok{color:var(--ok);font-weight:600}
        </style></head><body><main><h1>\(title)</h1>\(body)</main></body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Reads one field of an `application/x-www-form-urlencoded` body.
    static func formValue(_ name: String, in body: Data) -> String? {
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.first == name else { continue }
            return (parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        return nil
    }

    /// The IPv4 address a phone on the same network can reach: the first running `en` interface.
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host), name = String(cString: entry.ifa_name)
            guard !address.hasPrefix("169.254.") else { continue }
            candidates.append((name, address))
        }
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.address
    }
}
