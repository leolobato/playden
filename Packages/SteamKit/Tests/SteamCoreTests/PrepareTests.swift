import XCTest
import CryptoKit
import SwiftProtobuf
import SteamProto
@testable import SteamCore

final class PrepareTests: XCTestCase {
    func testRepeatedPreparationPreservesCustomSettingsOriginalAndSave() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("Game"), settings = game.appendingPathComponent("steam_settings")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let asset32 = root.appendingPathComponent("steam_api.dll"), asset64 = root.appendingPathComponent("steam_api64.dll")
        try makePE(architecture: .x86, section: ".text", strings: []).write(to: asset32)
        try makePE(architecture: .x86_64, section: ".text", strings: []).write(to: asset64)
        let original = makePE(architecture: .x86, section: ".text", strings: ["STEAMUSERSTATS_INTERFACE_VERSION011"])
        try original.write(to: game.appendingPathComponent("steam_api.dll"))
        let custom: [String: String] = [
            "user": "; user comment\n[user::general]\naccount_name=old\nticket=old-ticket\ncustom_user=keep\n[user::saves]\nlocal_save_path=old\ncustom_save=keep\n",
            "app": "; app comment\n[app::dlcs]\nunlock_all=1\n200=old\n300=unowned\n[app::paths]\n100=old\nother=keep\n[app::cloud_save::win]\ndir1=old\n[app::custom]\nvalue=keep\n",
            "main": "; main comment\n[main::connectivity]\noffline=1\ndisable_lan_only=0\ndisable_networking=1\ncustom_connectivity=keep\n[main::overlay]\nenable_experimental_overlay=1\n"
        ]
        for (name, value) in custom { try Data(value.utf8).write(to: settings.appendingPathComponent("configs.\(name).ini")) }
        let save = game.appendingPathComponent("save.dat"), saved = Data("saved progress".utf8)
        try saved.write(to: save)
        let preparer = SteamPreparer(assets: GBEAssets(steamAPI32: asset32, steamAPI64: asset64))
        var previous: [String: Data] = [:]
        for attempt in 0..<2 {
            _ = try preparer.prepare(appID: 100, gameDirectory: game,
                account: PrepareAccount(accountName: "current", steamID: 0),
                metadata: PrepareMetadata(dlcAppIDs: [200]), offline: false)
            for name in custom.keys {
                let url = settings.appendingPathComponent("configs.\(name).ini"), bytes = try Data(contentsOf: url)
                if attempt == 1 { XCTAssertEqual(bytes, previous[name]) }
                previous[name] = bytes
            }
            let user = String(decoding: previous["user"]!, as: UTF8.self)
            XCTAssertTrue(user.contains("; user comment\n")); XCTAssertTrue(user.contains("account_name=current\n"))
            XCTAssertTrue(user.contains("custom_user=keep\n")); XCTAssertTrue(user.contains("custom_save=keep\n"))
            XCTAssertFalse(user.contains("ticket=")); XCTAssertFalse(user.contains("local_save_path=old"))
            let app = String(decoding: previous["app"]!, as: UTF8.self)
            XCTAssertTrue(app.contains("; app comment\n")); XCTAssertTrue(app.contains("unlock_all=0\n200=dlc200\n"))
            XCTAssertTrue(app.contains("other=keep\n")); XCTAssertTrue(app.contains("[app::custom]\nvalue=keep\n"))
            XCTAssertFalse(app.contains("300=")); XCTAssertFalse(app.contains("dir1="))
            let main = String(decoding: previous["main"]!, as: UTF8.self)
            XCTAssertTrue(main.contains("; main comment\n")); XCTAssertTrue(main.contains("disable_lan_only=1\n"))
            XCTAssertTrue(main.contains("disable_networking=1\ncustom_connectivity=keep\n"))
            XCTAssertTrue(main.contains("[main::overlay]\nenable_experimental_overlay=1\n"))
            XCTAssertFalse(main.contains("offline="))
            XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent("steam_api.dll.orig")), original)
            XCTAssertEqual(try Data(contentsOf: save), saved)
        }
    }

    func testOnikenInterfacesAreCompleteAndRepairExistingConfiguration() throws {
        // Versions extracted from Oniken's original Steam API DLL (app 252010).
        let expected = [
            "SteamClient012", "SteamFriends014", "SteamGameServer011", "SteamGameServerStats001",
            "SteamMatchMaking009", "SteamMatchMakingServers002", "SteamNetworking005",
            "SteamUser017", "SteamUtils006", "STEAMUGC_INTERFACE_VERSION001",
            "STEAMCONTROLLER_INTERFACE_VERSION", "STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001",
            "STEAMHTTP_INTERFACE_VERSION002", "STEAMSCREENSHOTS_INTERFACE_VERSION002",
            "STEAMREMOTESTORAGE_INTERFACE_VERSION012", "STEAMAPPS_INTERFACE_VERSION006",
            "STEAMUSERSTATS_INTERFACE_VERSION011",
        ].sorted()
        for architecture in [PEArchitecture.x86, .x86_64] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let assetsDir = root.appendingPathComponent("assets")
            let game = root.appendingPathComponent("Oniken/DATA")
            try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            let asset32 = assetsDir.appendingPathComponent("steam_api.dll")
            let asset64 = assetsDir.appendingPathComponent("steam_api64.dll")
            let replacementVersions = ["SteamClient021", "STEAMUSERSTATS_INTERFACE_VERSION013"]
            try makePE(architecture: .x86, section: ".text", strings: replacementVersions).write(to: asset32)
            try makePE(architecture: .x86_64, section: ".text", strings: replacementVersions).write(to: asset64)
            let dll = game.appendingPathComponent(architecture == .x86 ? "steam_api.dll" : "steam_api64.dll")
            let original = makePE(architecture: architecture, section: ".text", strings: expected + [
                "SteamUser017", "SteamAPI_Init", "SteamReplacement999", "STEAMUSERSTATS_INTERFACE_VERSION",
                "STEAMUSERSTATS_INTERFACE_VERSION011junk", "STEAMCONTROLLER_INTERFACE_VERSIONjunk",
            ])
            try original.write(to: dll)
            let preparer = SteamPreparer(assets: GBEAssets(steamAPI32: asset32, steamAPI64: asset64))
            let paths = [game.appendingPathComponent("steam_interfaces.txt"),
                         game.appendingPathComponent("steam_settings/steam_interfaces.txt")]
            let account = PrepareAccount(accountName: "Fixture", steamID: 0)
            let first = try preparer.prepare(appID: 252010, gameDirectory: game,
                                             account: account, metadata: PrepareMetadata(), offline: true)
            XCTAssertEqual(first.dlls.first?.interfaceCount, 17)
            let contents = expected.joined(separator: "\n") + "\n"
            for path in paths { XCTAssertEqual(try String(contentsOf: path), contents) }

            // Simulate an old incomplete file, including a stale file in GBE's preferred directory.
            for path in paths { try "SteamClient012\nSteamUser017\n".write(to: path, atomically: true, encoding: .utf8) }
            for _ in 0..<2 {
                let repaired = try preparer.prepare(appID: 252010, gameDirectory: game,
                                                    account: account, metadata: PrepareMetadata(), offline: true)
                XCTAssertEqual(repaired.dlls.first?.interfaceCount, 17)
                for path in paths { XCTAssertEqual(try String(contentsOf: path), contents) }
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dll.path + ".orig")), original)
            }
        }
    }

    func testModernInterfaceFamiliesAndLegacyClientExport() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let asset32 = root.appendingPathComponent("steam_api.dll")
        let asset64 = root.appendingPathComponent("steam_api64.dll")
        try makePE(architecture: .x86, section: ".text", strings: []).write(to: asset32)
        try makePE(architecture: .x86_64, section: ".text", strings: []).write(to: asset64)
        let expected = ["SteamClient017", "STEAMHTMLSURFACE_INTERFACE_VERSION_005",
                        "STEAMINVENTORY_INTERFACE_V003", "STEAMTIMELINE_INTERFACE_V004",
                        "STEAMVIDEO_INTERFACE_V007", "SteamInput006"].sorted()
        try makePE(architecture: .x86_64, section: ".text", strings: expected + ["SteamClient021"])
            .write(to: game.appendingPathComponent("steam_api64.dll"))
        let preparer = SteamPreparer(assets: GBEAssets(steamAPI32: asset32, steamAPI64: asset64))
        let result = try preparer.prepare(appID: 100, gameDirectory: game,
                                          account: PrepareAccount(accountName: "Fixture", steamID: 0),
                                          metadata: PrepareMetadata(), offline: true)
        XCTAssertEqual(result.dlls.first?.interfaceCount, expected.count)
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("steam_settings/steam_interfaces.txt")),
                       expected.joined(separator: "\n") + "\n")
    }

    func testUndiscoverableInterfacesPreserveManualConfiguration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("Game")
        let settings = game.appendingPathComponent("steam_settings")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let asset32 = root.appendingPathComponent("steam_api.dll")
        let asset64 = root.appendingPathComponent("steam_api64.dll")
        try makePE(architecture: .x86, section: ".text", strings: []).write(to: asset32)
        try makePE(architecture: .x86_64, section: ".text", strings: []).write(to: asset64)
        try makePE(architecture: .x86, section: ".text", strings: ["no interface versions"])
            .write(to: game.appendingPathComponent("steam_api.dll"))
        let preparer = SteamPreparer(assets: GBEAssets(steamAPI32: asset32, steamAPI64: asset64))
        let canonical = settings.appendingPathComponent("steam_interfaces.txt")
        let legacy = game.appendingPathComponent("steam_interfaces.txt")
        for expectedCount in [0, 1, 2] {
            if expectedCount == 1 { try "SteamClient012\n".write(to: legacy, atomically: true, encoding: .utf8) }
            if expectedCount == 2 {
                try "SteamClient012\nSteamUser017\n".write(to: canonical, atomically: true, encoding: .utf8)
            }
            let result = try preparer.prepare(appID: 100, gameDirectory: game,
                                              account: PrepareAccount(accountName: "Fixture", steamID: 0),
                                              metadata: PrepareMetadata(), offline: true)
            XCTAssertEqual(result.dlls.first?.interfaceCount, expectedCount)
            if expectedCount > 0 { XCTAssertEqual(try String(contentsOf: legacy), "SteamClient012\n") }
            if expectedCount == 2 {
                XCTAssertEqual(try String(contentsOf: canonical), "SteamClient012\nSteamUser017\n")
            }
        }
    }

    func testOfflineStagingNeverLoadsOrReusesStoredIdentity() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assetsDir = root.appendingPathComponent("assets")
        let game = root.appendingPathComponent("Fixture")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)

        let asset32 = assetsDir.appendingPathComponent("steam_api.dll")
        let asset64 = assetsDir.appendingPathComponent("steam_api64.dll")
        let dll = game.appendingPathComponent("steam_api.dll")
        try makePE(architecture: .x86, section: ".text", strings: ["SteamClient020"]).write(to: dll)
        try makePE(architecture: .x86, section: ".text", strings: []).write(to: asset32)
        try makePE(architecture: .x86_64, section: ".text", strings: []).write(to: asset64)

        var storedAuthLoadCount = 0
        let storedAuth = StoredAuth(accountName: "private-account",
                                    steamID: 76_561_198_012_345_678,
                                    refreshToken: "private-refresh-token")
        let identity = try PrepareIdentity.resolve(offline: true, language: "ENGLISH") {
            storedAuthLoadCount += 1
            return storedAuth
        }
        XCTAssertEqual(storedAuthLoadCount, 0)
        XCTAssertNil(identity.storedAuth)
        XCTAssertEqual(identity.account.accountName, "Playden")
        XCTAssertEqual(identity.account.steamID, 0)
        XCTAssertEqual(identity.account.accountID, 0)

        let preparer = SteamPreparer(assets: GBEAssets(steamAPI32: asset32, steamAPI64: asset64))
        _ = try preparer.prepare(appID: 8870, gameDirectory: game,
                                 account: identity.account, metadata: PrepareMetadata(), offline: true)

        let userINI = try String(contentsOf: game.appendingPathComponent("steam_settings/configs.user.ini"))
        XCTAssertTrue(userINI.contains("account_name=Playden"))
        XCTAssertTrue(userINI.contains("account_steamid=0"))
        XCTAssertTrue(userINI.contains("userdata\\0"))
        XCTAssertFalse(userINI.contains(storedAuth.accountName))
        XCTAssertFalse(userINI.contains(String(storedAuth.steamID)))
        XCTAssertFalse(userINI.contains("ticket="))
    }

    func testStagingLayoutInterfacesIdempotencyAndRestore() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assetsDir = root.appendingPathComponent("assets")
        let game = root.appendingPathComponent("Look Outside")
        let bin = game.appendingPathComponent("win64")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let original = makePE(architecture: .x86_64, section: ".text",
                              strings: ["SteamUtils010", "SteamClient020", "noise"])
        let replacement64 = makePE(architecture: .x86_64, section: ".text",
                                   strings: ["SteamReplacement999"])
        let replacement32 = makePE(architecture: .x86, section: ".text",
                                   strings: ["SteamReplacement998"])
        let dll = bin.appendingPathComponent("steam_api64.dll")
        let asset64 = assetsDir.appendingPathComponent("steam_api64.dll")
        let asset32 = assetsDir.appendingPathComponent("steam_api.dll")
        try original.write(to: dll)
        try replacement64.write(to: asset64)
        try replacement32.write(to: asset32)
        try makePE(architecture: .x86_64, section: ".bind", strings: [])
            .write(to: game.appendingPathComponent("Game.exe"))

        let schema = achievementSchema()
        let stats = SteamUserStatsData(
            appID: 3_373_660, crc: 1, schema: schema, stats: [],
            achievementBlocks: [SteamAchievementBlock(id: 10, unlockTimes: [1_722_222_222])])
        let ufs = UFS(saveFilePatterns: [
            SaveFilePattern(root: .WinAppDataRoaming,
                            path: "LookOutside/{64BitSteamID}", pattern: "*.sav", recursive: 1),
            SaveFilePattern(root: .LinuxHome, path: ".config", pattern: "*.sav"),
        ])
        let ticket = Data([0x08, 0x01, 0x2a, 0x02, 0xca, 0xfe])
        let metadata = PrepareMetadata(
            installDir: "Look Outside", installedDepotIDs: [3_373_661, 3_373_662],
            dlcAppIDs: [3_400_002, 3_400_001], forceDLC: false, ufs: ufs,
            encryptedAppTicket: ticket, userStats: stats)
        let preparer = SteamPreparer(assets: GBEAssets(steamAPI32: asset32, steamAPI64: asset64))
        let account = PrepareAccount(accountName: "fixture-user",
                                     steamID: 76_561_198_012_345_678, language: "ENGLISH")

        let first = try preparer.prepare(appID: 3_373_660, gameDirectory: game,
                                         account: account, metadata: metadata)
        XCTAssertEqual(first.dlls.count, 1)
        XCTAssertEqual(first.dlls[0].architecture, .x86_64)
        XCTAssertEqual(first.dlls[0].interfaceCount, 2)
        XCTAssertEqual(first.steamStubRequirements.count, 1)
        XCTAssertTrue(first.ticketIncluded)
        XCTAssertEqual(first.achievementCount, 1)
        XCTAssertEqual(try Data(contentsOf: dll), replacement64)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dll.path + ".orig")), original)

        let settings = bin.appendingPathComponent("steam_settings")
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent("steam_appid.txt")), "3373660")
        XCTAssertEqual(try String(contentsOf: settings.appendingPathComponent("steam_appid.txt")), "3373660")
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent("steam_interfaces.txt")),
                       "SteamClient020\nSteamUtils010\n")
        XCTAssertEqual(try String(contentsOf: settings.appendingPathComponent("depots.txt")),
                       "3373661\n3373662")

        let userINI = try String(contentsOf: settings.appendingPathComponent("configs.user.ini"))
        XCTAssertTrue(userINI.contains("account_name=fixture-user"))
        XCTAssertTrue(userINI.contains("account_steamid=76561198012345678"))
        XCTAssertTrue(userINI.contains("ticket=\(ticket.base64EncodedString())"))
        XCTAssertTrue(userINI.contains("language=english"))
        let appINI = try String(contentsOf: settings.appendingPathComponent("configs.app.ini"))
        XCTAssertTrue(appINI.contains("3400001=dlc3400001\n3400002=dlc3400002"))
        XCTAssertTrue(appINI.contains("3373660=./steamapps/common/Look Outside"))
        XCTAssertTrue(appINI.contains("dir1={::WinAppDataRoaming::}/LookOutside/{::64BitSteamID::}"))
        XCTAssertFalse(appINI.contains("LinuxHome"))

        let achievements = try jsonArray(settings.appendingPathComponent("achievements.json"))
        XCTAssertEqual(achievements.count, 1)
        XCTAssertEqual(achievements[0]["name"] as? String, "FIRST_STEP")
        XCTAssertEqual(achievements[0]["hidden"] as? Int, 1)
        let mapping = try jsonDictionary(settings.appendingPathComponent("achievement_name_to_block.json"))
        XCTAssertEqual(mapping["FIRST_STEP"] as? [Int], [10, 0])

        // Regeneration must use .orig, never the replacement currently at the DLL path.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("steam_interfaces.txt"))
        let second = try preparer.prepare(appID: 3_373_660, gameDirectory: game,
                                          account: account, metadata: metadata)
        XCTAssertEqual(second.dlls[0].interfaceCount, 2)
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent("steam_interfaces.txt")),
                       "SteamClient020\nSteamUtils010\n")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dll.path + ".orig")), original)

        let restored = try preparer.restore(gameDirectory: game)
        XCTAssertEqual(restored.restoredDLLs, [dll])
        XCTAssertEqual(try Data(contentsOf: dll), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.appendingPathComponent(".steam_dll_restored").path))
        _ = try preparer.prepare(appID: 3_373_660, gameDirectory: game,
                                 account: account, metadata: metadata)
        XCTAssertEqual(try Data(contentsOf: dll), replacement64)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dll.path + ".orig")), original)
    }

    func testBundledAssetsHaveRecordedHashesAndArchitectures() throws {
        let assets = try GBEAssets.bundled()
        XCTAssertEqual(try PEInspector.inspect(assets.steamAPI32).architecture, .x86)
        XCTAssertEqual(try PEInspector.inspect(assets.steamAPI64).architecture, .x86_64)
        XCTAssertEqual(sha256(try Data(contentsOf: assets.steamAPI32)), GBEAssets.steamAPI32SHA256)
        XCTAssertEqual(sha256(try Data(contentsOf: assets.steamAPI64)), GBEAssets.steamAPI64SHA256)
    }

    func testPICSParsesDLCInstallDirAndWindowsUFSOverrides() throws {
        let text = #"""
        "appinfo"
        {
          "common" { "name" "Fixture" "type" "Game" "extended" { "listofdlc" "200,201" } }
          "config" { "installdir" "Fixture Install" }
          "depots"
          {
            "1" { "manifests" { "public" "7" } }
            "2" { "dlcappid" "200" "manifests" { "public" "8" } }
          }
          "ufs"
          {
            "rootoverrides"
            {
              "0" { "os" "Windows" "root" "WinAppDataRoaming" "useinstead" "WinSavedGames" "addpath" "Studio\\Game" }
              "1" { "os" "Linux" "root" "WinMyDocuments" "useinstead" "LinuxHome" }
            }
            "savefiles"
            {
              "0" { "root" "WinAppDataRoaming" "path" "slot" "pattern" "*.sav" "recursive" "1" "platforms" { "0" "Windows" } }
              "1" { "root" "LinuxHome" "path" ".config" "pattern" "*.sav" "platforms" { "0" "Linux" } }
            }
          }
        }
        """#
        let vdf = try VDF.parse(text)
        let app = CMClient.parseAppInfo(appID: 100, root: vdf["appinfo"]!)
        XCTAssertEqual(app.installDir, "Fixture Install")
        XCTAssertEqual(app.dlcAppIDs, [200, 201])
        XCTAssertEqual(app.depots.first(where: { $0.id == 2 })?.dlcAppID, 200)
        XCTAssertEqual(app.ufs.saveFilePatterns.count, 1)
        XCTAssertEqual(app.ufs.saveFilePatterns[0].root, .WinSavedGames)
        XCTAssertEqual(app.ufs.saveFilePatterns[0].path, "Studio/Game/slot")
        XCTAssertEqual(app.ufs.saveFilePatterns[0].uploadRoot, .WinAppDataRoaming)
        XCTAssertEqual(app.ufs.saveFilePatterns[0].uploadPath, "slot")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bigscreen-prepare-\(UUID().uuidString)")
    }

    private func makePE(architecture: PEArchitecture, section: String, strings: [String]) -> Data {
        var data = Data(repeating: 0, count: 0x400)
        data[0] = 0x4d; data[1] = 0x5a
        put32(0x80, into: &data, at: 0x3c)
        data[0x80] = 0x50; data[0x81] = 0x45
        put16(architecture == .x86 ? 0x014c : 0x8664, into: &data, at: 0x84)
        put16(1, into: &data, at: 0x86)
        let optionalSize: UInt16 = architecture == .x86 ? 0xe0 : 0xf0
        put16(optionalSize, into: &data, at: 0x94)
        put16(architecture == .x86 ? 0x10b : 0x20b, into: &data, at: 0x98)
        put32(0x1000, into: &data, at: 0xa8)
        let table = 0x98 + Int(optionalSize)
        for (index, byte) in section.utf8.prefix(8).enumerated() { data[table + index] = byte }
        put32(0x1000, into: &data, at: table + 8)
        put32(0x1000, into: &data, at: table + 12)
        put32(0x200, into: &data, at: table + 16)
        for string in strings {
            data.append(contentsOf: string.utf8)
            data.append(0)
        }
        return data
    }

    private func achievementSchema() -> Data {
        let display = section("display", body:
            string("name", "First Step") + string("desc", "Do the thing")
                + string("hidden", "1") + string("icon", "first.jpg")
                + string("icon_gray", "first_gray.jpg"))
        let achievement = section("0", body: string("name", "FIRST_STEP") + display)
        let bits = section("bits", body: achievement)
        let achievementBlock = section("10", body: string("type", "4") + bits)
        let ordinaryStat = section("20", body: string("type", "1")
            + string("name", "score") + string("default", "5"))
        return section("3373660", body: section("stats", body: achievementBlock + ordinaryStat)) + Data([0x08])
    }

    private func section(_ name: String, body: Data) -> Data {
        Data([0x00]) + cString(name) + body + Data([0x08])
    }

    private func string(_ name: String, _ value: String) -> Data {
        Data([0x01]) + cString(name) + cString(value)
    }

    private func cString(_ value: String) -> Data { Data(value.utf8) + Data([0]) }

    private func put16(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8(value >> 8)
    }

    private func put32(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff) }
    }

    private func jsonArray(_ url: URL) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    }

    private func jsonDictionary(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
