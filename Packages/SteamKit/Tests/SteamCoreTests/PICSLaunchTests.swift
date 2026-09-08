import XCTest
@testable import SteamCore

final class PICSLaunchTests: XCTestCase {
    func testLaunchMetadataAndDLCGatesSurviveRoundTrip() throws {
        let vdf = try VDF.parse(#"""
        "appinfo" {
          "common" { "name" "Fixture" "type" "game" "controller_support" "full" }
          "extended" { "listofdlc" "200, 201" }
          "config" {
            "installdir" "Fixture Game"
            "launch" {
              "10" { "executable" "Mac.app" "config" { "oslist" "macos" } }
              "2" { "executable" "bin\\Game.exe" "workingdir" "bin\\" "arguments" "-windowed \"two words\""
                      "type" "default" "config" { "oslist" " windows,linux " "osarch" "64" "ownsdlc" "200" "betakey" "dev-debug" } }
              "0" { "executable" "Launcher.exe" "description" "Play the game" }
            }
          }
        }
        """#)
        let app = CMClient.parseAppInfo(appID: 100, root: vdf["appinfo"]!)
        XCTAssertEqual(app.dlcAppIDs, [200, 201])
        XCTAssertEqual(app.controllerSupport, "full")
        XCTAssertEqual(app.launches.map(\.id), ["0", "2", "10"])
        XCTAssertTrue(app.launches[1].isWindows)
        XCTAssertFalse(app.launches[2].isWindows)
        XCTAssertEqual(app.launches[1].requiredDLC, 200)
        XCTAssertEqual(app.launches[1].betaKey, "dev-debug")
        XCTAssertNil(app.launches[0].betaKey)
        XCTAssertEqual(app.launches[0].description, "Play the game")
        XCTAssertEqual(app.launches[1].workingDirectory, "bin\\")
        XCTAssertEqual(app.launches[1].arguments, "-windowed \"two words\"")
        XCTAssertEqual(try JSONDecoder().decode(AppInfo.self, from: JSONEncoder().encode(app)), app)
    }
    func testOSMatchingDoesNotUseSubstringAndUnknownRemainsUnknown() throws {
        XCTAssertFalse(DepotInfo(id: 1, osList: "notwindows").isWindows)
        XCTAssertTrue(DepotInfo(id: 1, osList: " linux, Windows ").isWindows)
        let app = CMClient.parseAppInfo(appID: 100, root: try VDF.parse("\"common\" { \"name\" \"Fixture\" }") )
        XCTAssertTrue(app.launches.isEmpty)
        XCTAssertTrue(app.controllerSupport.isEmpty)
    }
    func testLaunchWithoutBranchRestrictionRemainsDecodable() throws {
        let data = Data(#"{"id":"0","executable":"Game.exe","arguments":"","workingDirectory":"","osList":"","osArch":"","type":""}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AppLaunch.self, from: data).betaKey)
    }
}
