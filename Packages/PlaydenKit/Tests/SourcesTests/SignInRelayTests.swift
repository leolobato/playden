import XCTest
import Domain
@testable import Sources

final class SignInRelayTests: XCTestCase {
    let login = URL(string: "https://auth.gog.com/auth?client_id=1&redirect_uri=x")!

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }

    private func post(_ url: URL, _ value: String) async throws -> (String, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        request.httpBody = Data("address=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)".utf8)
        let (data, response) = try await session().data(for: request)
        return (String(decoding: data, as: UTF8.self), (response as! HTTPURLResponse).statusCode)
    }

    func testPageFormAndSuccess() async throws {
        let received = Box()
        let relay = SignInRelay(storeName: "GOG", loginURL: login, host: "127.0.0.1") { pasted in
            received.value = pasted
            return pasted.contains("code=good") ? .signedIn : .failed("That address didn't work.")
        }
        let url = try await relay.start()
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path.count, 33, "a random 32-character token")

        let (page, response) = try await session().data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        let html = String(decoding: page, as: UTF8.self)
        XCTAssertTrue(html.contains(#"href="https://auth.gog.com/auth?client_id=1&amp;redirect_uri=x" target="_blank""#))
        XCTAssertTrue(html.contains("Sign in to GOG"))

        let (failed, _) = try await post(url, "https://embed.gog.com/on_login_success?origin=client&code=bad")
        XCTAssertTrue(failed.contains("That address didn&#39;t work.") || failed.contains("That address didn't work."))
        XCTAssertTrue(failed.contains("<form"), "the form stays for another try")

        let (done, _) = try await post(url, "https://embed.gog.com/on_login_success?origin=client&code=good")
        XCTAssertEqual(received.value, "https://embed.gog.com/on_login_success?origin=client&code=good")
        XCTAssertTrue(done.contains("Signed in to GOG"))
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            let (_, after) = try await session().data(from: url)
            XCTAssertNotEqual((after as! HTTPURLResponse).statusCode, 200, "the relay stops after a sign-in")
        } catch {}
    }

    func testWrongTokenIsNotFound() async throws {
        let relay = SignInRelay(storeName: "GOG", loginURL: login, host: "127.0.0.1") { _ in .signedIn }
        let url = try await relay.start()
        defer { relay.stop() }
        let other = URL(string: "http://127.0.0.1:\(url.port!)/0123456789abcdef0123456789abcdef")!
        let (_, response) = try await session().data(from: other)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 404)
    }

    func testStopRunsOnStopOnceAndTimesOut() async throws {
        let stops = Box()
        let relay = SignInRelay(storeName: "GOG", loginURL: login, host: "127.0.0.1", timeout: 0.2) { _ in .signedIn }
        relay.onStop = { stops.value = (stops.value ?? "") + "x" }
        _ = try await relay.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        relay.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(stops.value, "x")
    }

    func testParsingAndForms() {
        let request = Data("POST /abc HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\naddress=a+b".utf8)
        XCTAssertEqual(SignInRelay.parse(request), .init(method: "POST", path: "/abc", body: Data("address=a+b".utf8)))
        XCTAssertNil(SignInRelay.parse(Data("POST /abc HTTP/1.1\r\nContent-Length: 11\r\n\r\naddr".utf8)), "waits for the body")
        XCTAssertEqual(SignInRelay.formValue("address", in: Data("x=1&address=https%3A%2F%2Fa%3Fcode%3D1+2".utf8)), "https://a?code=1 2")
        XCTAssertEqual(SignInRelay.escape(#"<a href="x">&"#), "&lt;a href=&quot;x&quot;&gt;&amp;")
    }

    func testRedactorRemovesGOGSecrets() {
        let text = DiagnosticRedactor.redact("GET https://embed.gog.com/on_login_success?origin=client&code=SECRETCODE user_id=4242 "
            + "https://gog-cdn-fastly.gog.com/token=nva=1790801388~dirs=4~token=SIGNED/content-system/v2/store/1 "
            + "https://gog-cdn.gcdn.co/content-system/v2/store/1/ab?wsSecret=GCORE&wsTime=1 exit code: 1")
        XCTAssertFalse(text.contains("SECRETCODE"))
        XCTAssertFalse(text.contains("4242"))
        XCTAssertFalse(text.contains("SIGNED"))
        XCTAssertFalse(text.contains("GCORE"))
        XCTAssertTrue(text.contains("exit code: 1"), "ordinary codes stay readable")
        XCTAssertTrue(text.contains("/content-system/v2/store/1"))
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
