import XCTest
import Domain
@testable import Playden

@MainActor final class GameSettingsCatalogTests: XCTestCase {
    func testAllCoversEveryIDOnceInOrderAndTiersHaveExpectedCounts() {
        XCTAssertEqual(GameSettingsCatalog.all.map(\.id), RuntimeSettingID.allCases)
        XCTAssertEqual(GameSettingsCatalog.rows(in: .tier1).count, 5)
        XCTAssertEqual(GameSettingsCatalog.rows(in: .tier2).count, 7)
        XCTAssertEqual(GameSettingsCatalog.rows(in: .advanced).count, 3)
        XCTAssertEqual(GameSettingsCatalog.rows(in: .tier1).map(\.id), [.graphics, .synchronization, .controller, .windowsVersion, .launchOption])
        XCTAssertEqual(GameSettingsCatalog.rows(in: .tier2).map(\.id),
                        [.highResolution, .virtualDesktop, .temporaryPrimaryDisplay, .steamOverlay, .performanceOverlay, .frameLimit, .largeAddressAware])
        XCTAssertEqual(GameSettingsCatalog.rows(in: .advanced).map(\.id), [.launchArguments, .environmentVariables, .libraryOverrides])
    }

    func testChoiceValuesParseIntoDomainEnumsAndDefaultIsAChoice() throws {
        func parses(_ id: RuntimeSettingID) -> (String) -> Bool {
            switch id {
            case .graphics: return { GraphicsBackend(rawValue: $0) != nil }
            case .synchronization: return { SynchronizationMode(rawValue: $0) != nil }
            case .controller: return { ControllerMode(rawValue: $0) != nil }
            case .windowsVersion: return { WindowsVersion(rawValue: $0) != nil }
            case .virtualDesktop: return { VirtualDesktopSize(rawValue: $0) != nil }
            case .frameLimit: return { FrameLimit(rawValue: $0) != nil }
            case .highResolution, .temporaryPrimaryDisplay, .steamOverlay, .performanceOverlay, .largeAddressAware:
                return { $0 == "on" || $0 == "off" }
            case .launchOption, .launchArguments, .environmentVariables, .libraryOverrides:
                return { _ in true }
            }
        }
        for definition in GameSettingsCatalog.all {
            guard case .choices(let choices) = definition.kind else { continue }
            let isValid = parses(definition.id)
            for choice in choices {
                XCTAssertTrue(isValid(choice.value), "\(definition.id) choice \(choice.value) does not parse")
            }
            guard case .scalar(let defaultValue)? = RuntimeResolver.defaultValues[definition.id] else {
                XCTFail("\(definition.id) has no default value"); continue
            }
            XCTAssertTrue(choices.contains { $0.value == defaultValue }, "\(definition.id) default \(defaultValue) is not one of its choices")
        }
    }

    func testOnlyGraphicsAndSynchronizationChangeBottle() {
        let changesBottle = Set(GameSettingsCatalog.all.filter(\.changesBottle).map(\.id))
        XCTAssertEqual(changesBottle, [.graphics, .synchronization])
    }

    func testValueLabelFallsBackToDefaultForChoices() {
        XCTAssertEqual(GameSettingsCatalog.valueLabel(.graphics, value: nil, launchOptions: []), "D3DMetal")
        XCTAssertEqual(GameSettingsCatalog.valueLabel(.graphics, value: .scalar("dxvk"), launchOptions: []), "DXVK")
        XCTAssertEqual(GameSettingsCatalog.valueLabel(.steamOverlay, value: .scalar("on"), launchOptions: []), "Overlay on")
    }

    func testValueLabelForLaunchOption() throws {
        let option = LaunchOption(id: "dx11", title: "Play (DirectX 11)", spec: LaunchSpec(executableRelativePath: "game.exe"))
        XCTAssertEqual(GameSettingsCatalog.valueLabel(.launchOption, value: nil, launchOptions: [option]), "Default")
        XCTAssertEqual(GameSettingsCatalog.valueLabel(.launchOption, value: .scalar("dx11"), launchOptions: [option]), "Play (DirectX 11)")
        XCTAssertEqual(GameSettingsCatalog.valueLabel(.launchOption, value: .scalar("missing"), launchOptions: [option]), "Unavailable")
    }

    func testValueLabelForText() {
        XCTAssertEqual(GameSettingsCatalog.valueLabel(.environmentVariables, value: nil, launchOptions: []), "Empty")
        XCTAssertEqual(GameSettingsCatalog.valueLabel(.environmentVariables, value: .list([]), launchOptions: []), "Empty")
        XCTAssertEqual(GameSettingsCatalog.valueLabel(.environmentVariables, value: .list(["A=1", "B=2"]), launchOptions: []), "A=1 B=2")
    }
}
