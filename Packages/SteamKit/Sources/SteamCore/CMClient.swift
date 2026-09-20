import Foundation
import SwiftProtobuf
import SteamProto

/// Connection to a Steam CM (connection manager) server over WebSocket.
///
/// Framing per message: uint32 LE (EMsg | 0x80000000) + uint32 LE header length
/// + CMsgProtoBufHeader + protobuf body. TLS replaces the legacy channel crypto.
public actor CMClient {
    public private(set) var steamID: UInt64 = 0x0110_0001_0000_0000  // anonymous individual, desktop instance
    public private(set) var sessionID: Int32 = 0
    public private(set) var cellID: UInt32 = 0
    public private(set) var licenses: [CMsgClientLicenseList.License] = []

    private let diagnostic: @Sendable (String) -> Void
    private var socket: (any CMTransport)?
    private var connectionID = UUID()
    private let requestTimeout: TimeInterval
    let depotKeyStore: any DepotKeyStore
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    private var jobCounter: UInt64 = 0
    private enum RequestKind { case job, logon, licenses, hello }
    private struct PendingJob {
        let kind: RequestKind
        var parts: [Data] = []
        var byteCount = 0
        var isComplete: (Data) -> Bool
        var continuation: CheckedContinuation<[Data], Error>
        var deadline: Task<Void, Never>?
        var sending: Task<Void, Never>?
    }
    private var pendingJobs: [UInt64: PendingJob] = [:]
    private var haveLicenses = false
    var outstandingRequests: Int { pendingJobs.count }

    public init(depotKeyStore: any DepotKeyStore = FileDepotKeys(), requestTimeout: TimeInterval = 30,
                diagnostic: @escaping @Sendable (String) -> Void = { _ in }) {
        self.diagnostic = diagnostic
        self.depotKeyStore = depotKeyStore
        self.requestTimeout = requestTimeout.isFinite ? min(300, max(0.01, requestTimeout)) : 30
    }

    // MARK: connect + logon

    public func connect() async throws {
        let json = try await SteamWebAPI.callJSON(
            interface: "ISteamDirectory", method: "GetCMListForConnect",
            params: ["cmtype": "websockets", "maxcount": "16"])
        guard let response = json["response"] as? [String: Any],
              let list = response["serverlist"] as? [[String: Any]], !list.isEmpty else {
            throw SteamError.protocolError("empty CM server list")
        }
        let endpoints = list.compactMap { $0["endpoint"] as? String }
        var lastError: Error = SteamError.protocolError("no CM endpoints")
        for endpoint in endpoints.prefix(4) {
            try Task.checkCancellation()
            do {
                try await open(endpoint: endpoint)
                return
            } catch {
                try Task.checkCancellation()
                disconnect()
                lastError = error
            }
        }
        throw lastError
    }

    private func open(endpoint: String) async throws {
        guard let url = URL(string: "wss://\(endpoint)/cmsocket/") else {
            throw SteamError.protocolError("bad CM endpoint \(endpoint)")
        }
        try await attach(WebSocketCMTransport(url: url, timeout: requestTimeout))
    }

    /// Internal transport seam also exercises the production framing/request lifecycle in tests.
    func attach(_ transport: any CMTransport) async throws {
        disconnect()
        socket = transport
        let epoch = connectionID
        receiveTask = Task { await self.receiveLoop(transport, connectionID: epoch) }
        var hello = CMsgClientHello(); hello.protocolVersion = 65580
        do {
            _ = try await request(.kEmsgClientHello, body: hello, kind: .hello)
            try Task.checkCancellation()
            guard connectionID == epoch else { throw CancellationError() }
        }
        catch { if connectionID == epoch { disconnect() }; throw error }
    }

    public func logOn(accountName: String, refreshToken: String) async throws -> CMsgClientLogonResponse {
        var logon = CMsgClientLogon()
        logon.protocolVersion = 65580
        logon.clientPackageVersion = 1771
        logon.clientLanguage = "english"
        logon.clientOsType = 0  // EOSType.WinUnknown — pose as Windows (doc 04 §4)
        logon.supportsRateLimitResponse = true
        logon.accountName = accountName
        logon.accessToken = refreshToken  // CM logon takes the *refresh* token here
        logon.cellID = cellID

        guard !pendingJobs.values.contains(where: { $0.kind == .logon }), sessionID == 0 else {
            throw SteamError.protocolError("CM logon is already active")
        }
        let epoch = connectionID
        let response: CMsgClientLogonResponse
        do {
            let parts = try await request(.kEmsgClientLogon, body: logon, kind: .logon)
            guard connectionID == epoch else { throw CancellationError() }
            guard let first = parts.first else { throw SteamError.protocolError("empty CM logon response") }
            response = try CMsgClientLogonResponse(serializedBytes: first)
        } catch { if connectionID == epoch { disconnect() }; throw error }
        diagnostic("CM logon result=\(response.eresult)")
        let result = EResult(rawValue: response.eresult)
        guard result == .ok else {
            disconnect()
            if result == .invalidPassword {
                throw SteamError.authFailed("CM rejected the refresh token (expired/revoked) — log in again")
            }
            throw SteamError.eresult(result, context: "CM logon")
        }
        cellID = response.cellID
        var seconds = response.hasHeartbeatSeconds ? response.heartbeatSeconds : response.legacyOutOfGameHeartbeatSeconds
        if seconds <= 0 { seconds = 9 }
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                    try Task.checkCancellation()
                    try await self?.send(.kEmsgClientHeartBeat, body: CMsgClientHeartBeat())
                } catch { return }
            }
        }
        return response
    }

    public func disconnect() {
        closeConnection(with: CancellationError())
    }
    private func closeConnection(with error: Error) {
        connectionID = UUID()
        heartbeatTask?.cancel(); heartbeatTask = nil
        receiveTask?.cancel(); receiveTask = nil
        socket?.close(); socket = nil
        steamID = 0x0110_0001_0000_0000; sessionID = 0
        licenses = []; haveLicenses = false
        failAll(with: error)
    }

    /// Multiple callers may wait for the same list; each has an independent deadline/cancellation.
    public func waitForLicenses() async throws {
        try Task.checkCancellation()
        if haveLicenses { return }
        _ = try await request(.kEmsgInvalid, body: CMsgClientHeartBeat(), kind: .licenses)
    }

    // MARK: send / receive plumbing

    private func send<M: Message>(_ emsg: EMsg, body: M, header: CMsgProtoBufHeader? = nil) async throws {
        guard let socket else { throw URLError(.networkConnectionLost) }
        var hdr = header ?? CMsgProtoBufHeader()
        hdr.steamid = steamID
        hdr.clientSessionid = sessionID
        let headerData = try hdr.serializedData()
        let bodyData = try body.serializedData()
        var frame = Data()
        frame.appendLE(UInt32(truncatingIfNeeded: emsg.rawValue) | 0x8000_0000)
        frame.appendLE(UInt32(headerData.count))
        frame.append(headerData)
        frame.append(bodyData)
        try Task.checkCancellation()
        try await socket.send(frame)
    }

    private func receiveLoop(_ transport: any CMTransport, connectionID epoch: UUID) async {
        while !Task.isCancelled && connectionID == epoch {
            do {
                let data = try await transport.receive()
                guard connectionID == epoch, !Task.isCancelled else { return }
                handleFrame(data)
            } catch {
                guard connectionID == epoch else { return }
                diagnostic("CM receive failed code=\((error as NSError).code)")
                closeConnection(with: URLError(.networkConnectionLost))
                return
            }
        }
    }

    private func handleFrame(_ data: Data, depth: Int = 0) {
        guard depth < 16 else { failAll(with: SteamError.protocolError("CM nested message limit exceeded")); return }
        guard data.count >= 8 else { return }
        let raw = data.readLE(UInt32.self, at: 0)
        let emsgValue = Int(raw & ~0x8000_0000)
        let headerLen = Int(data.readLE(UInt32.self, at: 4))
        guard data.count >= 8 + headerLen else { return }
        guard let header = try? CMsgProtoBufHeader(serializedBytes: data.subdata(in: data.startIndex + 8..<data.startIndex + 8 + headerLen)) else { return }
        let body = data.subdata(in: data.startIndex + 8 + headerLen..<data.endIndex)
        let emsg = EMsg(rawValue: emsgValue) ?? .kEmsgInvalid

        // Adopt session identity from the logon response path.
        if emsg == .kEmsgClientLogOnResponse, pendingJobs.values.contains(where: { $0.kind == .logon }),
           header.steamid != 0 && sessionID == 0 && header.clientSessionid != 0 {
            steamID = header.steamid
            sessionID = header.clientSessionid
        }

        switch emsg {
        case .kEmsgMulti:
            if let multi = try? CMsgMulti(serializedBytes: body) {
                guard multi.sizeUnzipped <= 32 * 1024 * 1024 else { disconnect(); return }
                var payload = multi.messageBody
                if multi.sizeUnzipped > 0 {
                    payload = (try? Decompress.gunzip(payload)) ?? Data()
                }
                var offset = payload.startIndex
                while offset + 4 <= payload.endIndex {
                    let size = Int(payload.readLE(UInt32.self, at: offset - payload.startIndex))
                    let start = offset + 4
                    guard start + size <= payload.endIndex else { break }
                    handleFrame(payload.subdata(in: start..<start + size), depth: depth + 1)
                    offset = start + size
                }
            }

        case .kEmsgClientLogOnResponse:
            if (try? CMsgClientLogonResponse(serializedBytes: body)) != nil {
                // TryAnotherCM etc. come with eresult != OK; deliver either way.
                if let id = pendingJobs.first(where: { $0.value.kind == .logon })?.key {
                    finish(id, result: .success([body]))
                }
            }

        case .kEmsgClientLicenseList:
            if let list = try? CMsgClientLicenseList(serializedBytes: body) {
                diagnostic("CM licenses result=\(list.eresult) count=\(list.licenses.count)")
                if list.hasEresult && list.eresult != EResult.ok.rawValue {
                    closeConnection(with: SteamError.authSessionExpired)
                    return
                }
                licenses = list.licenses
                haveLicenses = true
                for id in pendingJobs.filter({ $0.value.kind == .licenses }).map(\.key) { finish(id, result: .success([])) }
            }

        case .kEmsgClientLoggedOff:
            let reason = try? CMsgClientLoggedOff(serializedBytes: body)
            diagnostic("CM logged off result=\(reason.map { String($0.eresult) } ?? "unreadable") pending=\(pendingJobs.count)")
            closeConnection(with: SteamError.authSessionExpired)

        default:
            break
        }

        // Job responses (PICS, depot keys, service methods...).
        // Note: jobid fields default to UInt64.max when absent, so require presence.
        if header.hasJobidTarget, var job = pendingJobs[header.jobidTarget], job.kind == .job {
            if let eresult = header.hasEresult ? EResult(rawValue: header.eresult) : nil, eresult != .ok {
                diagnostic("CM job message=\(emsgValue) result=\(eresult.rawValue)")
                finish(header.jobidTarget, result: .failure(SteamError.eresult(eresult, context: "CM job (\(emsgValue))")))
                return
            }
            job.byteCount += body.count
            guard job.byteCount <= 64 * 1024 * 1024 else {
                finish(header.jobidTarget, result: .failure(SteamError.protocolError("CM response limit exceeded"))); return
            }
            job.parts.append(body)
            if job.isComplete(body) {
                finish(header.jobidTarget, result: .success(job.parts))
            } else {
                pendingJobs[header.jobidTarget] = job
            }
        }
    }

    private func finish(_ id: UInt64, result: Result<[Data], Error>) {
        guard let job = pendingJobs.removeValue(forKey: id) else { return }
        job.deadline?.cancel()
        if case .failure = result { job.sending?.cancel() }
        job.continuation.resume(with: result)
    }
    private func failAll(with error: Error) {
        for id in Array(pendingJobs.keys) { finish(id, result: .failure(error)) }
    }

    // MARK: jobs
    func jobRequest<M: Message>(
        _ emsg: EMsg, body: M, targetJobName: String? = nil,
        isComplete: @escaping (Data) -> Bool = { _ in true }
    ) async throws -> [Data] {
        try await request(emsg, body: body, kind: .job, targetJobName: targetJobName, isComplete: isComplete)
    }

    private func request<M: Message>(
        _ emsg: EMsg, body: M, kind: RequestKind, targetJobName: String? = nil,
        isComplete: @escaping (Data) -> Bool = { _ in true }
    ) async throws -> [Data] {
        try Task.checkCancellation()
        guard socket != nil else { throw URLError(.networkConnectionLost) }
        jobCounter += 1
        let jobID = jobCounter
        var header = CMsgProtoBufHeader()
        if kind == .job { header.jobidSource = jobID }
        if let targetJobName { header.targetJobName = targetJobName }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { cont in
                pendingJobs[jobID] = PendingJob(kind: kind, isComplete: isComplete, continuation: cont)
                pendingJobs[jobID]?.deadline = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000)) }
                    catch { return }
                    await self?.finish(jobID, result: .failure(URLError(.timedOut)))
                }
                if kind != .licenses {
                    pendingJobs[jobID]?.sending = Task {
                        do {
                            try await self.send(emsg, body: body, header: header)
                            if kind == .hello { self.finish(jobID, result: .success([])) }
                        } catch { self.finish(jobID, result: .failure(error)) }
                    }
                }
            }
        } onCancel: {
            Task { await self.finish(jobID, result: .failure(CancellationError())) }
        }
    }

    /// Unified service method call (e.g. "ContentServerDirectory.GetManifestRequestCode#1").
    public func serviceMethod<Req: Message, Resp: Message>(
        _ name: String, request: Req, responseType: Resp.Type
    ) async throws -> Resp {
        let parts = try await jobRequest(.kEmsgServiceMethodCallFromClient, body: request, targetJobName: name)
        guard let first = parts.first else { throw SteamError.protocolError("\(name): empty response") }
        return try Resp(serializedBytes: first)
    }
}

extension Data {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// Reads a little-endian value at `offset` relative to startIndex.
    func readLE(_ type: UInt32.Type, at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start]) | UInt32(self[start + 1]) << 8
            | UInt32(self[start + 2]) << 16 | UInt32(self[start + 3]) << 24
    }
}
