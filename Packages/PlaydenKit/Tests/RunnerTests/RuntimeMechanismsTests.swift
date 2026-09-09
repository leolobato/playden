import XCTest
import Domain
@testable import Runner

final class RuntimeMechanismsTests: XCTestCase {
    func testRegistryScriptCoversXboxRetinaAndVirtualDesktopVariants() {
        let xbox = RuntimeSettings(controller: .xboxCompatible, highResolution: true, virtualDesktop: .hd1080)
        let xboxScript = RuntimeMechanisms.registryScript(xbox)
        XCTAssertTrue(xboxScript.hasPrefix("Windows Registry Editor Version 5.00\r\n"))
        XCTAssertTrue(xboxScript.contains("\"DisableHidraw\"=dword:00000001"))
        XCTAssertTrue(xboxScript.contains("\"RetinaMode\"=\"y\""))
        XCTAssertTrue(xboxScript.contains("\"Desktop\"=\"Default\""))
        XCTAssertTrue(xboxScript.contains("\"Default\"=\"1920x1080\""))

        let native = RuntimeSettings(controller: .native, highResolution: false, virtualDesktop: .off)
        let nativeScript = RuntimeMechanisms.registryScript(native)
        XCTAssertTrue(nativeScript.contains("\"DisableHidraw\"=dword:00000000"))
        XCTAssertTrue(nativeScript.contains("\"RetinaMode\"=\"n\""))
        XCTAssertTrue(nativeScript.contains("\"Desktop\"=-"))
        XCTAssertTrue(nativeScript.contains("\"Default\"=-"))
    }
    func testRegistryDataIsBOMPrefixedUTF16LEOfTheScript() {
        let data = RuntimeMechanisms.registryData(.playdenDefault)
        XCTAssertEqual(data.prefix(2), Data([0xFF, 0xFE]))
        let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        XCTAssertEqual(text, RuntimeMechanisms.registryScript(.playdenDefault))
    }
    func testBottleEnvironmentCoversAllSynchronizationModes() {
        XCTAssertEqual(RuntimeMechanisms.bottleEnvironment(RuntimeSettings(synchronization: .msync)),
            ["CX_GRAPHICS_BACKEND": "d3dmetal", "WINEMSYNC": "1", "WINEESYNC": "0"])
        XCTAssertEqual(RuntimeMechanisms.bottleEnvironment(RuntimeSettings(synchronization: .esync)),
            ["CX_GRAPHICS_BACKEND": "d3dmetal", "WINEMSYNC": "0", "WINEESYNC": "1"])
        XCTAssertEqual(RuntimeMechanisms.bottleEnvironment(RuntimeSettings(synchronization: .off)),
            ["CX_GRAPHICS_BACKEND": "d3dmetal", "WINEMSYNC": "0", "WINEESYNC": "0"])
    }
    func testLaunchEnvironmentOnlyIncludesDXVKHUDWithDXVKBackend() {
        XCTAssertEqual(RuntimeMechanisms.launchEnvironment(.playdenDefault), [:])
        XCTAssertEqual(RuntimeMechanisms.launchEnvironment(RuntimeSettings(graphics: .d3dMetal, performanceOverlay: true)), ["MTL_HUD_ENABLED": "1"])
        XCTAssertEqual(RuntimeMechanisms.launchEnvironment(RuntimeSettings(graphics: .dxvk, performanceOverlay: true)), ["MTL_HUD_ENABLED": "1", "DXVK_HUD": "fps"])
        XCTAssertEqual(RuntimeMechanisms.launchEnvironment(RuntimeSettings(graphics: .dxvk, performanceOverlay: false)), [:])
        XCTAssertEqual(RuntimeMechanisms.launchEnvironment(RuntimeSettings(frameLimit: .fps60)), ["DXVK_FRAME_RATE": "60"])
        XCTAssertEqual(RuntimeMechanisms.launchEnvironment(RuntimeSettings(largeAddressAware: true)), ["WINE_LARGE_ADDRESS_AWARE": "1"])
    }
    func testEffectiveSpecAppendsArgumentsAndOverridesAndMergesEnvironmentWithManagedPrecedence() throws {
        let spec = LaunchSpec(executableRelativePath: "game.exe", arguments: ["--base"],
            environment: ["USER_FLAG": "one", "MTL_HUD_ENABLED": "stale"], dllOverrides: ["steam_api=n"])
        let settings = RuntimeSettings(graphics: .dxvk, performanceOverlay: true, launchArguments: ["--extra"],
            environment: ["USER_FLAG": "two"], dllOverrides: ["steam_api=n", "libglesv2=d"])
        let result = try RuntimeMechanisms.effectiveSpec(spec, settings: settings)
        XCTAssertEqual(result.arguments, ["--base", "--extra"])
        XCTAssertEqual(result.dllOverrides, ["steam_api=n", "libglesv2=d"])
        XCTAssertEqual(result.environment["USER_FLAG"], "two")
        XCTAssertEqual(result.environment["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(result.environment["DXVK_HUD"], "fps")
        XCTAssertThrowsError(try RuntimeMechanisms.effectiveSpec(spec, settings: RuntimeSettings(environment: ["WINEMSYNC": "1"])))
    }
    func testRewriteBottleEnvironmentChangesOnlyGivenKeysAndReturnsWhetherItWrote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Playden-conf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let conf = root.appendingPathComponent("cxbottle.conf")
        try "[Section]\n\"Other\" = \"1\"\n[EnvironmentVariables]\n\"XDG_CONFIG_HOME\" = \"${WINEPREFIX}/.playden-folders\"\n\"CX_DIRECT_DESKTOP\" = \"1\"\n\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\"\n"
            .write(to: conf, atomically: true, encoding: .utf8)
        let wrote = try RuntimeMechanisms.rewriteBottleEnvironment(at: conf, values: ["CX_GRAPHICS_BACKEND": "dxvk", "WINEMSYNC": "1", "WINEESYNC": "0"])
        XCTAssertTrue(wrote)
        let text = try String(contentsOf: conf, encoding: .utf8)
        XCTAssertTrue(text.contains("[Section]"))
        XCTAssertTrue(text.contains("\"Other\" = \"1\""))
        XCTAssertTrue(text.contains("\"XDG_CONFIG_HOME\" = \"${WINEPREFIX}/.playden-folders\""))
        XCTAssertTrue(text.contains("\"CX_DIRECT_DESKTOP\" = \"1\""))
        XCTAssertTrue(text.contains("\"CX_GRAPHICS_BACKEND\" = \"dxvk\""))
        XCTAssertTrue(text.contains("\"WINEMSYNC\" = \"1\""))
        XCTAssertTrue(text.contains("\"WINEESYNC\" = \"0\""))
        XCTAssertFalse(text.contains("\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\""))
        let unchanged = try RuntimeMechanisms.rewriteBottleEnvironment(at: conf, values: ["CX_GRAPHICS_BACKEND": "dxvk", "WINEMSYNC": "1", "WINEESYNC": "0"])
        XCTAssertFalse(unchanged)
    }
    func testArgumentsIncludeWinverAfterNoGuiAndValidateDLLOverrideModes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Playden-args-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("game.exe"))
        let args = try CrossOverRunner.arguments(.init(executableRelativePath: "game.exe", dllOverrides: ["libglesv2=d"]), bottle: root, directory: root, winver: "win7")
        let index = try XCTUnwrap(args.firstIndex(of: "--no-gui"))
        XCTAssertEqual(Array(args[(index + 1)...(index + 2)]), ["--winver", "win7"])
        XCTAssertThrowsError(try CrossOverRunner.arguments(.init(executableRelativePath: "game.exe", dllOverrides: ["foo=x"]), bottle: root, directory: root))
    }
}
