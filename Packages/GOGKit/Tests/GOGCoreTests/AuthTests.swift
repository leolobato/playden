import XCTest
@testable import GOGCore

final class AuthTests: XCTestCase {
    func testCodeFromRedirectAddress() throws {
        XCTAssertEqual(try GOGAuth.code(from: " https://embed.gog.com/on_login_success?origin=client&code=abc-DEF_123 \n"), "abc-DEF_123")
        XCTAssertEqual(try GOGAuth.code(from: "abc-DEF_123"), "abc-DEF_123")
        XCTAssertThrowsError(try GOGAuth.code(from: "https://embed.gog.com/on_login_success?origin=client"))
        XCTAssertThrowsError(try GOGAuth.code(from: "not a code"))
    }

    func testLoginURLCarriesTheGalaxyRedirect() {
        let url = GOGAuth().loginURL()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, "https://embed.gog.com/on_login_success?origin=client")
        XCTAssertEqual(items.first { $0.name == "client_id" }?.value, "46899977096215655")
    }

    func testCodecHelpers() throws {
        XCTAssertEqual(GOGCodec.galaxyPath("059fe48b93b6d1691f158b6ef0404b6e"), "05/9f/059fe48b93b6d1691f158b6ef0404b6e")
        let json = Data(#"{"version":2}"#.utf8)
        // zlib stream of the JSON above, made with Python's zlib.compress.
        let compressed = Data([0x78, 0x9c, 0xab, 0x56, 0x2a, 0x4b, 0x2d, 0x2a, 0xce, 0xcc, 0xcf, 0x53, 0xb2, 0x32, 0xaa, 0x05, 0x00, 0x22, 0x38, 0x04, 0xaf])
        XCTAssertEqual(try GOGCodec.maybeInflate(compressed), json)
        XCTAssertEqual(try GOGCodec.maybeInflate(json), json)
    }

    func testEndpointTemplate() throws {
        let endpoint = try JSONDecoder().decode(GOGBuild.Endpoint.self, from: Data(#"{"endpoint_name":"fastly","url_format":"{base_url}/token=nva={expires_at}~dirs={dirs}~token={token}{path}","parameters":{"base_url":"https://cdn","path":"/content-system/v2/store/1","expires_at":1700000000,"dirs":4,"token":"t"}}"#.utf8))
        XCTAssertEqual(endpoint.url(appendingPath: "/ab/cd/abcd")?.absoluteString, "https://cdn/token=nva=1700000000~dirs=4~token=t/content-system/v2/store/1/ab/cd/abcd")
    }
}
