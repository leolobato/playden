import Foundation

/// Every client ID, secret and host Epic sign-in and downloads use. Kept in one place so a rotation is one edit.
public struct EpicClientConfig: Sendable, Equatable {
    public struct Client: Sendable, Equatable {
        public var id: String
        public var secret: String
        public init(id: String, secret: String) { self.id = id; self.secret = secret }
        var basicAuthorization: String { "Basic " + Data("\(id):\(secret)".utf8).base64EncodedString() }
    }

    /// `launcherAppClient2`, the Epic Games Launcher's client. Library, manifests and launch codes need its tokens.
    public var launcher: Client
    /// A console client that may use the OAuth device flow. Its session is traded for a launcher one.
    public var deviceCode: Client
    public var userAgent: String
    public var accountHost: String
    public var launcherHost: String
    public var libraryHost: String
    public var catalogHost: String
    public var ecommerceHost: String

    public static let `default` = EpicClientConfig(
        launcher: Client(id: "34a02cf8f4414e29b15921876da36f9a", secret: "daafbccc737745039dffe53d94fc76cf"),
        deviceCode: Client(id: "98f7e42c2e3a4f86a74eb43fbb41ed39", secret: "0a2449a2-001a-451e-afec-3e812901c4d7"),
        userAgent: "UELauncher/15.18.2-29993784+++Portal+Release-Live Windows/10.0.19041.1.256.64bit",
        accountHost: "account-public-service-prod03.ol.epicgames.com",
        launcherHost: "launcher-public-service-prod06.ol.epicgames.com",
        libraryHost: "library-service.live.use1a.on.epicgames.com",
        catalogHost: "catalog-public-service-prod06.ol.epicgames.com",
        ecommerceHost: "ecommerceintegration-public-service-ecomprod02.ol.epicgames.com")

    public init(launcher: Client, deviceCode: Client, userAgent: String, accountHost: String, launcherHost: String,
                libraryHost: String, catalogHost: String, ecommerceHost: String) {
        self.launcher = launcher; self.deviceCode = deviceCode; self.userAgent = userAgent
        self.accountHost = accountHost; self.launcherHost = launcherHost; self.libraryHost = libraryHost
        self.catalogHost = catalogHost; self.ecommerceHost = ecommerceHost
    }
}

public protocol EpicTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: EpicTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EpicError.malformed("non-HTTP response") }
        return (data, http)
    }
}

/// Epic's error body: `{errorCode, errorMessage, correctiveAction?, continuationUrl?}`.
struct EpicErrorBody: Decodable {
    var errorCode: String?
    var errorMessage: String?
    var continuationUrl: String?
}

struct EpicHTTP: Sendable {
    enum Auth { case none, basic(EpicClientConfig.Client), bearer(String) }

    let config: EpicClientConfig
    let transport: any EpicTransport
    /// Waits between retries of throttled or failed requests; tests pass a no-op.
    let pause: @Sendable (Double) async throws -> Void
    var attempts = 3

    func request(_ method: String, _ url: URL, auth: Auth, form: [String: String]? = nil,
                 accept: ClosedRange<Int> = 200...299) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        switch auth {
        case .none: break
        case .basic(let client): request.setValue(client.basicAuthorization, forHTTPHeaderField: "Authorization")
        case .bearer(let token): request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.encodeForm(form).utf8)
        }
        var attempt = 0
        while true {
            attempt += 1
            let data: Data, response: HTTPURLResponse
            do { (data, response) = try await transport.send(request) }
            catch is CancellationError { throw EpicError.cancelled }
            catch let error as URLError where error.code == .cancelled { throw EpicError.cancelled }
            catch let error as EpicError { throw error }
            catch {
                if attempt < attempts { try await pause(Double(attempt)); continue }
                throw EpicError.network(error.localizedDescription)
            }
            if accept.contains(response.statusCode) { return data }
            if (response.statusCode == 429 || response.statusCode >= 500), attempt < attempts {
                try await pause(Double(1 << attempt)); continue
            }
            throw Self.error(status: response.statusCode, data: data)
        }
    }

    func json<T: Decodable>(_ type: T.Type, _ method: String, _ url: URL, auth: Auth, form: [String: String]? = nil) async throws -> T {
        let data = try await request(method, url, auth: auth, form: form)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw EpicError.malformed("\(T.self): \(error)") }
    }

    static func error(status: Int, data: Data) -> EpicError {
        let body = try? JSONDecoder().decode(EpicErrorBody.self, from: data)
        let code = body?.errorCode
        if code == "errors.com.epicgames.oauth.corrective_action_required" {
            return .correctiveAction(body?.continuationUrl.flatMap(URL.init(string:)))
        }
        return .http(status: status, code: code, message: body?.errorMessage)
    }

    static func encodeForm(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)"
        }.joined(separator: "&")
    }

    func url(_ host: String, _ path: String, _ query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = host; components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }
}
