import XCTest
import Domain

final class RuntimeSettingsTests: XCTestCase {
    func testRuntimeProfileRoundTripEncodesOverridesAsObject() throws {
        let profile = RuntimeProfile(base: "modern-dx12", overrides: [.graphics: .scalar("dxvk"), .environmentVariables: .list(["A=1"])], source: .user)
        let data = try JSONEncoder().encode(profile)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"graphics\":\"dxvk\""), json)
        XCTAssertTrue(json.contains("\"environmentVariables\":[\"A=1\"]"), json)
        let decoded = try JSONDecoder().decode(RuntimeProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testDecodingDropsUnknownOverrideIDsAndDefaultsSource() throws {
        let json = Data(#"{"base":"x","overrides":{"graphics":"dxvk","bogus":"1"}}"#.utf8)
        let profile = try JSONDecoder().decode(RuntimeProfile.self, from: json)
        XCTAssertEqual(profile.base, "x")
        XCTAssertEqual(profile.overrides, [.graphics: .scalar("dxvk")])
        XCTAssertEqual(profile.source, .playdenDefault)
        XCTAssertNil(profile.appliedAt)
    }

    func testBundledCatalogHasEightProfilesInOrderAndReproducesEveryScalar() throws {
        let catalog = CuratedProfileCatalog.bundled()
        XCTAssertEqual(catalog.profiles.map(\.id), [
            "playden-default", "modern-dx12", "dx11-alternative", "older-3d-game",
            "unity-unreal-launcher", "web-launcher", "fewer-cores", "native-dualsense",
        ])
        for profile in catalog.profiles {
            let settings = RuntimeResolver.settings(from: profile.settings)
            for (id, value) in profile.settings {
                switch (id, value) {
                case (.graphics, .scalar(let raw)): XCTAssertEqual(settings.graphics.rawValue, raw, profile.id)
                case (.synchronization, .scalar(let raw)): XCTAssertEqual(settings.synchronization.rawValue, raw, profile.id)
                case (.controller, .scalar(let raw)): XCTAssertEqual(settings.controller.rawValue, raw, profile.id)
                case (.windowsVersion, .scalar(let raw)): XCTAssertEqual(settings.windowsVersion.rawValue, raw, profile.id)
                case (.highResolution, .scalar(let raw)): XCTAssertEqual(settings.highResolution, raw == "on", profile.id)
                case (.virtualDesktop, .scalar(let raw)): XCTAssertEqual(settings.virtualDesktop.rawValue, raw, profile.id)
                case (.performanceOverlay, .scalar(let raw)): XCTAssertEqual(settings.performanceOverlay, raw == "on", profile.id)
                case (.frameLimit, .scalar(let raw)): XCTAssertEqual(settings.frameLimit.rawValue, raw, profile.id)
                case (.largeAddressAware, .scalar(let raw)): XCTAssertEqual(settings.largeAddressAware, raw == "on", profile.id)
                case (.launchArguments, .list(let values)): XCTAssertEqual(settings.launchArguments, values, profile.id)
                case (.libraryOverrides, .list(let values)): XCTAssertEqual(settings.dllOverrides, values, profile.id)
                case (.environmentVariables, .list(let values)):
                    for entry in values {
                        let parts = entry.split(separator: "=", maxSplits: 1)
                        XCTAssertEqual(settings.environment[String(parts[0])], String(parts[1]), profile.id)
                    }
                default: XCTFail("Unhandled setting \(id) in \(profile.id)")
                }
            }
        }
    }

    func testResolverPrecedenceOverrideBeatsProfileBeatsDefault() {
        let catalog = CuratedProfileCatalog.bundled()
        let profile = RuntimeProfile(base: "older-3d-game", overrides: [.graphics: .scalar("d3dmetal")])
        let settings = RuntimeResolver.settings(profile, catalog: catalog)
        XCTAssertEqual(settings.graphics, .d3dMetal)
        XCTAssertEqual(settings.synchronization, .esync)
        XCTAssertEqual(settings.windowsVersion, .win7)
    }

    func testNormalizedDropsOverridesEqualToBaseAndKeepsDivergentOnes() {
        let catalog = CuratedProfileCatalog.bundled()
        let profile = RuntimeProfile(base: "older-3d-game", overrides: [.graphics: .scalar("dxvk"), .synchronization: .scalar("msync")])
        let normalized = RuntimeResolver.normalized(profile, catalog: catalog)
        XCTAssertEqual(normalized.overrides, [.synchronization: .scalar("msync")])
    }

    func testIsCustomAndDisplayName() {
        let catalog = CuratedProfileCatalog.bundled()
        let clean = RuntimeProfile(base: "older-3d-game")
        XCTAssertFalse(clean.isCustom)
        XCTAssertEqual(RuntimeResolver.displayName(clean, catalog: catalog), "Older 3D game")

        let custom = RuntimeProfile(base: "older-3d-game", overrides: [.graphics: .scalar("d3dmetal")])
        XCTAssertTrue(custom.isCustom)
        XCTAssertEqual(RuntimeResolver.displayName(custom, catalog: catalog), "Custom · from Older 3D game")

        XCTAssertEqual(RuntimeResolver.displayName(RuntimeProfile(), catalog: catalog), "Playden default")
        XCTAssertEqual(RuntimeResolver.displayName(RuntimeProfile(base: "unknown-id"), catalog: catalog), "Playden default")
    }

    func testPlaydenDefaultMatchesSettingsFromDefaultValues() {
        XCTAssertEqual(RuntimeSettings.playdenDefault, RuntimeResolver.settings(from: RuntimeResolver.defaultValues))
    }

    func testSteamOverlaySourceOptionReflectsToggle() {
        let on = RuntimeResolver.settings(from: [.steamOverlay: .scalar("on")])
        let off = RuntimeResolver.settings(from: [.steamOverlay: .scalar("off")])
        XCTAssertEqual(on.sourceOptions["steam.overlay"], "1")
        XCTAssertEqual(off.sourceOptions["steam.overlay"], "0")
    }
}
