import Foundation
import Network
import CryptoKit
import GOGCore

// Developer tool for the GOG spike (PRD 10 step 0) and the live tests.
// Usage:
//   gog-dev url                                   prints the Galaxy login URL
//   gog-dev sign-in <session.json> <address|code> exchanges the pasted address and saves the session
//   gog-dev listen <session.json> <port>          tries a loopback redirect instead of the Galaxy one
//   gog-dev check <session.json> <report.tsv>     refreshes, then lists the library with builds per platform
//   gog-dev info <session.json> <product> <windows|osx>  secure-link shape and the product's launch tasks

let arguments = CommandLine.arguments
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let auth = GOGAuth(), api = GOGAPI()

func usage() -> Never {
    print("usage: gog-dev url | sign-in <session.json> <address|code> | listen <session.json> <port> | check <session.json> <report.tsv> | info <session.json> <product> <windows|osx>")
    exit(2)
}
func save(_ session: GOGSession, to url: URL) throws {
    try encoder.encode(session).write(to: url, options: .atomic)
    chmod(url.path, 0o600)
}
func load(_ url: URL) throws -> GOGSession { try decoder.decode(GOGSession.self, from: Data(contentsOf: url)) }

/// Refreshes, saves the new session and reports what the spike needs to know about tokens.
func refreshed(_ url: URL) async throws -> GOGSession {
    let old = try load(url)
    let issued = Date()
    var session = try await auth.refresh(old)
    session.displayName = try await name(session) ?? old.displayName
    try save(session, to: url)
    print("Refresh: lifetime \(Int(session.expiresAt.timeIntervalSince(issued))) s; refresh token \(session.refreshToken == old.refreshToken ? "unchanged" : "rotated")")
    return session
}
func name(_ session: GOGSession) async throws -> String? {
    try await api.userData(accessToken: session.accessToken)["username"]?.string
}
func finishSignIn(code: String, redirect: String?, to url: URL) async throws {
    let issued = Date()
    var session = try await auth.exchange(code: code, redirectURI: redirect)
    session.displayName = try await name(session)
    try save(session, to: url)
    print("Signed in as \(session.displayName ?? session.userID). Token lifetime \(Int(session.expiresAt.timeIntervalSince(issued))) s. Saved \(url.path)")
}

/// Runs `body` over `items` with at most `width` at a time, keeping the input order.
func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], width: Int, _ body: @escaping @Sendable (T) async -> R) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count), next = 0
        for _ in 0..<min(width, items.count) { let i = next; group.addTask { (i, await body(items[i])) }; next += 1 }
        for await (i, r) in group {
            results[i] = r
            if next < items.count { let j = next; group.addTask { (j, await body(items[j])) }; next += 1 }
        }
        return results.map { $0! }
    }
}

// MARK: listen

/// Serves one request on 127.0.0.1:<port>; if GOG redirects there, the code arrives without a paste.
final class LoopbackCatcher: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<String, Error>?
    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
    }
    func firstRequestLine() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let body = "<html><body><h1>Playden got the redirect. You can close this tab.</h1></body></html>"
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    guard let line = text.split(separator: "\r\n").first, line.hasPrefix("GET ") else { return }
                    self?.continuation?.resume(returning: String(line)); self?.continuation = nil
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.continuation?.resume(throwing: error); self?.continuation = nil }
            }
            listener.start(queue: .main)
        }
    }
    func stop() { listener.cancel() }
}

// MARK: info

/// Prints the secure-link shape (secret values hidden) and the product's goggame info file.
func info(product: Int, os: String, session: GOGSession) async throws {
    let builds = try await api.builds(productID: product, os: os, accessToken: session.accessToken)
    guard let build = builds.first(where: { $0.branch == nil }) ?? builds.first else { print("No \(os) build."); return }
    print("Build \(build.build_id) gen \(build.generation) \(build.version_name ?? "") (\(builds.count) listed)")
    for endpoint in build.urls ?? [] {
        print("  CDN \(endpoint.endpoint_name) priority \(endpoint.priority ?? -1) fallback \(endpoint.fallback_only ?? false)")
    }
    guard let metaEndpoint = build.urls?.first, let metaURL = URL(string: metaEndpoint.url ?? "") ?? metaEndpoint.url(appendingPath: "") else {
        print("No manifest URL."); return
    }
    let meta = try JSONDecoder().decode(GOGJSON.self, from: try await api.manifest(at: metaURL))
    let dependencies = meta["dependencies"]?.array.compactMap(\.string) ?? meta["product"]?["depots"]?.array.compactMap { $0["redist"]?.string } ?? []
    print("Dependencies: \(dependencies.isEmpty ? "none" : dependencies.joined(separator: ", "))")

    let generation = build.generation
    let linkPath = generation == 2 ? "/" : "/\(os)/\(meta["product"]?["timestamp"]?.text ?? "")/"
    let started = Date()
    let endpoints = try await api.secureLink(productID: String(product), generation: generation, path: linkPath, accessToken: session.accessToken)
    for endpoint in endpoints {
        let keys = endpoint.parameters.keys.sorted().map { key -> String in
            let value = endpoint.parameters[key]!.text
            return ["path", "expires_at", "expires", "dirs"].contains(key) ? "\(key)=\(value)" : "\(key)=<\(value.count) chars>"
        }
        print("Secure link \(endpoint.endpoint_name): format \(endpoint.url_format) params [\(keys.joined(separator: ", "))]")
    }

    if generation == 2 {
        let depots = meta["depots"]?.array ?? []
        let base = String(product)
        for depot in depots where depot["productId"]?.text == base {
            guard let hash = depot["manifest"]?.string else { continue }
            let manifest = try JSONDecoder().decode(GOGJSON.self, from: try await api.manifest(at: GOGAPI.v2MetaURL(hash)))
            let items = manifest["depot"]?["items"]?.array ?? []
            guard let file = items.first(where: { ($0["path"]?.string ?? "").lowercased().hasSuffix("goggame-\(base).info") }) else { continue }
            print("Info file \(file["path"]?.string ?? "") in depot \(hash) (bitness \(depot["osBitness"]?.array.map(\.text).joined(separator: ",") ?? "-"))")
            var data = Data()
            for chunk in file["chunks"]?.array ?? [] {
                guard let endpoint = endpoints.first else { break }
                data += try await api.chunk(compressedMD5: chunk["compressedMd5"]?.string ?? "", md5: chunk["md5"]?.string ?? "", from: endpoint)
            }
            printTasks(data)
            break
        }
    } else {
        for depot in meta["product"]?["depots"]?.array ?? [] {
            guard let name = depot["manifest"]?.string, let gameID = depot["gameIDs"]?.array.first?.text else { continue }
            let url = URL(string: "https://gog-cdn-fastly.gog.com/content-system/v1/manifests/\(gameID)/\(os)/\(meta["product"]?["timestamp"]?.text ?? "")/\(name)")!
            let manifest = try JSONDecoder().decode(GOGJSON.self, from: try await api.manifest(at: url))
            let files = manifest["depot"]?["files"]?.array ?? []
            guard let file = files.first(where: { ($0["path"]?.string ?? "").lowercased().hasSuffix("goggame-\(product).info") }),
                  let offset = Int(file["offset"]?.text ?? ""), let size = Int(file["size"]?.text ?? ""), let endpoint = endpoints.first,
                  let blob = endpoint.url(appendingPath: "/main.bin") else { continue }
            print("Info file \(file["path"]?.string ?? "") in \(name)")
            var request = URLRequest(url: blob)
            request.setValue("bytes=\(offset)-\(offset + size - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            print("Range fetch: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), md5 \(file["hash"]?.string == md5Hex(data) ? "ok" : "mismatch")")
            printTasks(data)
            break
        }
    }
    print("Secure link age at end: \(Int(Date().timeIntervalSince(started))) s")
}
func md5Hex(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func printTasks(_ data: Data) {
    guard let json = try? JSONDecoder().decode(GOGJSON.self, from: data) else { print("Info file is not JSON (\(data.count) bytes)"); return }
    for task in json["playTasks"]?.array ?? [] {
        let fields = ["type", "category", "isPrimary", "isHidden", "path", "workingDir", "arguments", "link"].compactMap { key in
            json.isNull(task[key]) ? nil : "\(key)=\(task[key]!.text)"
        }
        print("  playTask \(fields.joined(separator: " "))")
    }
}
extension GOGJSON { func isNull(_ value: GOGJSON?) -> Bool { value == nil || value == .null } }

// MARK: check

func check(session: GOGSession, report: URL) async throws {
    let owned = try await api.ownedProductIDs(accessToken: session.accessToken)
    print("Owned product IDs (embed): \(owned.count)")
    do {
        let releases = try await api.libraryReleases(userID: session.userID, accessToken: session.accessToken)
        let gog = releases.filter { $0["platform_id"]?.string == "gog" }
        print("galaxy-library releases: \(releases.count) (\(gog.count) from GOG)")
    } catch { print("galaxy-library failed: \(error.localizedDescription)") }

    struct Row: Sendable { var id: Int; var title: String; var type: String; var visible: Bool; var systems: String; var windows: String; var osx: String }
    let token = session.accessToken
    let rows: [Row] = await concurrentMap(owned, width: 8) { id in
        guard let entry = try? await api.gamesDB(productID: id) else { return Row(id: id, title: "", type: "none", visible: false, systems: "", windows: "", osx: "") }
        let type = entry["type"]?.string ?? "?"
        let visible = entry["game"]?["visible_in_library"] == .bool(true)
        let title = entry["title"]?["*"]?.string ?? entry["game"]?["title"]?["*"]?.string ?? ""
        let systems = entry["supported_operating_systems"]?.array.compactMap { $0["slug"]?.string }.joined(separator: ",") ?? ""
        guard type == "game", visible else { return Row(id: id, title: title, type: type, visible: visible, systems: systems, windows: "", osx: "") }
        func describe(_ os: String) async -> String {
            guard let builds = try? await api.builds(productID: id, os: os, accessToken: token),
                  let build = builds.first(where: { $0.branch == nil }) else { return "-" }
            var text = "gen\(build.generation)"
            if build.generation == 2, let url = build.urls?.first?.url.flatMap(URL.init(string:)),
               let meta = try? JSONDecoder().decode(GOGJSON.self, from: try await api.manifest(at: url)) {
                let deps = meta["dependencies"]?.array.compactMap(\.string) ?? []
                if !deps.isEmpty { text += " deps:" + deps.joined(separator: "+") }
                let size = meta["depots"]?.array.filter { $0["productId"]?.text == String(id) }.compactMap { Double($0["compressedSize"]?.text ?? "") }.reduce(0, +) ?? 0
                text += String(format: " %.1fGB", size / 1e9)
            }
            return text
        }
        return Row(id: id, title: title, type: type, visible: visible, systems: systems, windows: await describe("windows"), osx: await describe("osx"))
    }
    var counts: [String: Int] = [:]
    for row in rows { counts[row.visible || row.type != "game" ? row.type : "game (hidden)", default: 0] += 1 }
    print("gamesdb types: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    let games = rows.filter { $0.type == "game" && $0.visible }
    print("Games with a Windows build: \(games.filter { $0.windows != "-" }.count); with a Mac build: \(games.filter { $0.osx != "-" }.count); gen 1 only (Windows): \(games.filter { $0.windows.hasPrefix("gen1") }.count)")
    var tsv = "id\ttitle\ttype\tvisible\tsystems\twindows\tosx\n"
    for row in rows.sorted(by: { $0.title < $1.title }) {
        tsv += "\(row.id)\t\(row.title)\t\(row.type)\t\(row.visible)\t\(row.systems)\t\(row.windows)\t\(row.osx)\n"
    }
    try tsv.write(to: report, atomically: true, encoding: .utf8)
    print("Report: \(report.path)")
}

// MARK: download

/// A plain sequential gen 2 download of the base game's English depots, for the spike's signature checks.
func download(product: Int, os: String, to root: URL, session: GOGSession) async throws {
    let builds = try await api.builds(productID: product, os: os, accessToken: session.accessToken)
    guard let build = builds.first(where: { $0.branch == nil }), build.generation == 2,
          let metaURL = build.urls?.first?.url.flatMap(URL.init(string:)) else { print("No gen 2 \(os) build."); return }
    let meta = try JSONDecoder().decode(GOGJSON.self, from: try await api.manifest(at: metaURL))
    let endpoints = try await api.secureLink(productID: String(product), generation: 2, path: "/", accessToken: session.accessToken)
    var count = 0, bytes = 0
    for depot in meta["depots"]?.array ?? [] where depot["productId"]?.text == String(product) {
        let languages = depot["languages"]?.array.compactMap(\.string) ?? []
        guard languages.contains("*") || languages.contains(where: { $0.lowercased().hasPrefix("en") }), let hash = depot["manifest"]?.string else { continue }
        let manifest = try JSONDecoder().decode(GOGJSON.self, from: try await api.manifest(at: GOGAPI.v2MetaURL(hash)))
        for item in manifest["depot"]?["items"]?.array ?? [] {
            let path = (item["path"]?.string ?? "").replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = root.appendingPathComponent(path)
            switch item["type"]?.string {
            case "DepotFile":
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                var data = Data()
                for chunk in item["chunks"]?.array ?? [] {
                    data += try await api.chunk(compressedMD5: chunk["compressedMd5"]?.string ?? "", md5: chunk["md5"]?.string ?? "", from: endpoints[0])
                }
                try data.write(to: target)
                let flags = item["flags"]?.array.compactMap(\.string) ?? []
                if flags.contains("executable") { chmod(target.path, 0o755) }
                count += 1; bytes += data.count
            case "DepotLink":
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: item["target"]?.string ?? "")
            default:
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            }
        }
    }
    print("Wrote \(count) files, \(bytes / 1_000_000) MB to \(root.path)")
}

// MARK: main

guard arguments.count >= 2 else { usage() }
do {
    switch arguments[1] {
    case "url":
        print(auth.loginURL().absoluteString)
    case "sign-in":
        guard arguments.count == 4 else { usage() }
        try await finishSignIn(code: try GOGAuth.code(from: arguments[3]), redirect: nil, to: URL(fileURLWithPath: arguments[2]))
    case "listen":
        guard arguments.count == 4, let port = UInt16(arguments[3]) else { usage() }
        let redirect = "http://127.0.0.1:\(port)/gog"
        let catcher = try LoopbackCatcher(port: port)
        print("Open this, signed in to GOG or not, in a browser on this Mac:\n\(auth.loginURL(redirectURI: redirect).absoluteString)")
        fflush(stdout)
        let line = try await catcher.firstRequestLine()
        catcher.stop()
        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        print("GOG redirected to the loopback address: \(target.replacingOccurrences(of: #"code=[^&]+"#, with: "code=<redacted>", options: .regularExpression))")
        do { try await finishSignIn(code: try GOGAuth.code(from: "http://127.0.0.1" + target), redirect: redirect, to: URL(fileURLWithPath: arguments[2])) }
        catch { print("The token call refused the loopback redirect: \(error.localizedDescription)") }
    case "check":
        guard arguments.count == 4 else { usage() }
        try await check(session: try await refreshed(URL(fileURLWithPath: arguments[2])), report: URL(fileURLWithPath: arguments[3]))
    case "info":
        guard arguments.count == 5, let product = Int(arguments[3]) else { usage() }
        try await info(product: product, os: arguments[4], session: try await refreshed(URL(fileURLWithPath: arguments[2])))
    case "download":
        guard arguments.count == 6, let product = Int(arguments[3]) else { usage() }
        try await download(product: product, os: arguments[4], to: URL(fileURLWithPath: arguments[5]),
                           session: try await refreshed(URL(fileURLWithPath: arguments[2])))
    default:
        usage()
    }
} catch {
    print("Failed: \(error.localizedDescription) (\(error))"); exit(1)
}
