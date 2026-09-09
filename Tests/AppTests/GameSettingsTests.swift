import XCTest
import Domain
import Catalog
@testable import Playden

@MainActor final class GameSettingsTests: XCTestCase {
    private let id = GameID(source: "fixture", value: "settings")
    private func makeModel(_ catalog: CatalogStore) throws -> LibraryModel {
        try catalog.replaceSourceCatalog(source: "fixture", games: [.init(id: id, title: "Settings fixture")])
        let model = LibraryModel(catalog: catalog, preview: false)
        model.openGame(try XCTUnwrap(model.games.first))
        return model
    }
    private func selectDXVK(_ model: LibraryModel) {
        model.perform(.move(.down)); model.perform(.confirm) // Graphics row → picker
        model.perform(.move(.down)); model.perform(.confirm) // DXVK → back on the sheet
    }

    func testSheetOpensFromDetailActionsAndListsProfileThenGraphicsFirst() throws {
        let catalog = try CatalogStore()
        let model = try makeModel(catalog)
        model.detailAction = 1; model.perform(.confirm)
        XCTAssertEqual(model.panel, .gameSettings(id))
        let rows = model.settingsRows(for: id)
        XCTAssertEqual(rows.first, .profile)
        XCTAssertEqual(rows[safe: 1], .setting(.graphics))
        XCTAssertEqual(model.focusedSettingsRow, .profile)
    }

    func testGraphicsPickerPersistsOverrideThenContextAndBaseValueClearIt() throws {
        let catalog = try CatalogStore()
        let model = try makeModel(catalog)
        model.showGameSettings(id)
        model.perform(.move(.down))
        XCTAssertEqual(model.focusedSettingsRow, .setting(.graphics))
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .settingPicker(id, .graphics))
        XCTAssertEqual(model.pickerIndex, 0, "The Playden default choice starts selected")
        model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(model.panel, .gameSettings(id))
        XCTAssertEqual(model.runtimeProfiles[id]?.overrides[.graphics], .scalar("dxvk"))
        XCTAssertTrue(model.rowDiffers(id, .graphics))
        XCTAssertEqual(model.rowValueLabel(id, .graphics), "DXVK")
        XCTAssertEqual(try catalog.edits(for: id).runtimeProfile, try XCTUnwrap(model.runtimeProfiles[id]))
        XCTAssertEqual(model.settingsChangedCount, 1)
        // △ removes the override.
        model.perform(.context)
        XCTAssertNil(model.runtimeProfiles[id]?.overrides[.graphics])
        XCTAssertFalse(model.rowDiffers(id, .graphics))
        // Selecting DXVK again, then picking the base value back, also leaves no override (normalisation).
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .settingPicker(id, .graphics))
        model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(model.runtimeProfiles[id]?.overrides[.graphics], .scalar("dxvk"))
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .settingPicker(id, .graphics))
        XCTAssertEqual(model.pickerIndex, 1, "The picker opens on the currently overridden choice")
        model.perform(.move(.up)); model.perform(.confirm)
        XCTAssertNil(model.runtimeProfiles[id]?.overrides[.graphics])
    }

    func testOverridePersistsAcrossFavoriteToggleAndReload() throws {
        let catalog = try CatalogStore()
        let model = try makeModel(catalog)
        model.showGameSettings(id)
        selectDXVK(model)
        let profile = try XCTUnwrap(model.runtimeProfiles[id])
        model.toggleFavorite()
        XCTAssertEqual(try catalog.snapshot().entries.first?.edits.runtime, profile)
        XCTAssertEqual(try catalog.snapshot().entries.first?.edits.isFavorite, true)
        let restored = LibraryModel(catalog: catalog, preview: false)
        XCTAssertEqual(restored.runtimeProfiles[id], profile)
    }

    func testProfileChooserAppliesCuratedProfileAndComparisonListsChangedSettings() throws {
        let catalog = try CatalogStore()
        let model = try makeModel(catalog)
        let comparison = model.comparison(id, with: "older-3d-game")
        XCTAssertEqual(Set(comparison.filter(\.changed).map(\.id)),
            Set([.graphics, .synchronization, .windowsVersion, .virtualDesktop, .largeAddressAware]))
        model.showGameSettings(id)
        XCTAssertEqual(model.focusedSettingsRow, .profile)
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .profileChooser(id))
        let rows = model.chooserRows(id)
        let index = try XCTUnwrap(rows.firstIndex { $0?.name == "Older 3D game" })
        for _ in 0..<index { model.perform(.move(.down)) }
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .gameSettings(id))
        XCTAssertEqual(model.runtimeProfiles[id]?.base, "older-3d-game")
        XCTAssertEqual(model.runtimeProfiles[id]?.overrides, [:])
        XCTAssertEqual(model.profileLabel(id), "Older 3D game")
    }

    func testCustomOverrideAddsCustomRowAndProfileLabel() throws {
        let catalog = try CatalogStore()
        let model = try makeModel(catalog)
        model.applyProfile(id, profileID: "playden-default")
        model.showGameSettings(id)
        selectDXVK(model)
        XCTAssertTrue(model.profile(for: id).isCustom)
        XCTAssertTrue(model.profileLabel(id).hasPrefix("Custom · from"))
        let rows = model.chooserRows(id)
        XCTAssertEqual(rows.count, model.profileCatalog.profiles.count + 1)
        XCTAssertNil(rows.last!)
    }

    func testBackEnqueuesSettingsSavedNotificationOnlyWhenChanged() throws {
        let catalog = try CatalogStore()
        let model = try makeModel(catalog)
        model.showGameSettings(id)
        model.perform(.back)
        XCTAssertTrue(model.notifications.isEmpty)
        model.showGameSettings(id)
        selectDXVK(model)
        model.setOverride(id, .synchronization, .scalar("esync"))
        model.perform(.back)
        XCTAssertEqual(model.notifications.count, 1)
        let notification = try XCTUnwrap(model.notifications.first)
        XCTAssertTrue(notification.title.hasPrefix("Settings saved"))
        XCTAssertTrue(notification.detail.contains("apply on next launch"))
    }

    func testAllSettingsAreReachableWithoutExpandingAndResetAllClearsOverrides() throws {
        let catalog = try CatalogStore()
        let model = try makeModel(catalog)
        model.showGameSettings(id)
        let rows = model.settingsRows(for: id)
        XCTAssertEqual(rows.count, RuntimeSettingID.allCases.count + 2)
        let displayIndex = try XCTUnwrap(rows.firstIndex(of: .setting(.virtualDesktop)))
        for _ in 0..<displayIndex { model.perform(.move(.down)) }
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .settingPicker(id, .virtualDesktop))
        model.perform(.back)
        XCTAssertEqual(model.focusedSettingsRow, .setting(.virtualDesktop))
        model.setOverride(id, .virtualDesktop, .scalar("1920x1080"))
        XCTAssertTrue(model.profile(for: id).isCustom)
        let resetIndex = try XCTUnwrap(model.settingsRows(for: id).firstIndex(of: .resetAll))
        model.settingsFocus = resetIndex
        model.perform(.confirm)
        XCTAssertTrue(model.profile(for: id).overrides.isEmpty)
    }

    func testMoreKeepsManagementActionsReachable() throws {
        let model = LibraryModel()
        model.openGame(try XCTUnwrap(model.games.first { $0.status == .installed }))
        XCTAssertEqual(model.detailActions.count, 4)
        model.detailAction = 3; model.perform(.confirm)
        XCTAssertEqual(model.panel, .context)
        XCTAssertFalse(model.contextActions.contains("Launch options"))
        for action in ["Game settings", "Add to collection", "Set compatibility", "Hide", "Verify files", "Cloud saves", "Uninstall", "View logs"] {
            XCTAssertTrue(model.panelActions.contains(action), action)
        }
        model.panelIndex = try XCTUnwrap(model.panelActions.firstIndex(of: "Game settings"))
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .gameSettings(try XCTUnwrap(model.detailID)))
    }

    func testOldGameEditsDecodeWithoutRuntimeProfile() throws {
        let data = try JSONEncoder().encode(GameEdits())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "runtime")
        let decoded = try JSONDecoder().decode(GameEdits.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.runtime)
    }

    // MARK: - RuntimeTextValidation

    func testRuntimeTextValidationParsesLaunchArgumentsHonoringQuotes() {
        switch RuntimeTextValidation.parse("-windowed \"-mod dir\" -nolauncher", for: .launchArguments) {
        case .success(let values): XCTAssertEqual(values, ["-windowed", "-mod dir", "-nolauncher"])
        case .failure(let error): XCTFail(error.message)
        }
    }

    func testRuntimeTextValidationParsesEnvironmentVariableAndDedupesKeepingLastValue() {
        switch RuntimeTextValidation.parse("WINE_CPU_TOPOLOGY=8 WINE_CPU_TOPOLOGY=4", for: .environmentVariables) {
        case .success(let values): XCTAssertEqual(values, ["WINE_CPU_TOPOLOGY=4"])
        case .failure(let error): XCTFail(error.message)
        }
    }

    func testRuntimeTextValidationDedupesLibraryOverridesKeepingLastValue() {
        switch RuntimeTextValidation.parse("d3d9=n d3d9=b,n", for: .libraryOverrides) {
        case .success(let values): XCTAssertEqual(values, ["d3d9=b,n"])
        case .failure(let error): XCTFail(error.message)
        }
    }

    func testRuntimeTextValidationRejectsManagedEnvironmentKey() {
        switch RuntimeTextValidation.parse("WINEMSYNC=0", for: .environmentVariables) {
        case .success: XCTFail("Expected a reserved-key failure")
        case .failure(let error):
            XCTAssertEqual(error, .reservedKey("WINEMSYNC"))
            XCTAssertEqual(error.message, "WINEMSYNC is set by Playden. Use the matching setting instead.")
        }
    }

    func testRuntimeTextValidationRejectsDenylistedEnvironmentKey() {
        switch RuntimeTextValidation.parse("PATH=x", for: .environmentVariables) {
        case .success: XCTFail("Expected a reserved-key failure")
        case .failure(let error):
            XCTAssertEqual(error, .reservedKey("PATH"))
            XCTAssertEqual(error.message, "PATH can’t be changed here.")
        }
    }

    func testRuntimeTextValidationRejectsMalformedEnvironmentToken() {
        switch RuntimeTextValidation.parse("FOO", for: .environmentVariables) {
        case .success: XCTFail("Expected a malformed failure")
        case .failure(let error):
            XCTAssertEqual(error, .malformed("FOO"))
            XCTAssertEqual(error.message, "FOO isn’t KEY=VALUE.")
        }
    }

    func testRuntimeTextValidationRejectsInvalidLibraryOverride() {
        switch RuntimeTextValidation.parse("foo=x", for: .libraryOverrides) {
        case .success: XCTFail("Expected an invalid-override failure")
        case .failure(let error):
            XCTAssertEqual(error, .invalidOverride("foo=x"))
            XCTAssertEqual(error.message, "foo=x isn’t a library override. Use name=n,b, name=b or name=d.")
        }
    }

    // MARK: - Environment variables text editor

    func testEnvironmentVariablesTextEditorValidatesBeforePersisting() throws {
        let catalog = try CatalogStore()
        let model = try makeModel(catalog)
        model.showGameSettings(id)
        let rowIndex = try XCTUnwrap(model.settingsRows(for: id).firstIndex(of: .setting(.environmentVariables)))
        model.settingsFocus = rowIndex
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .textEditor(.runtimeText(id, .environmentVariables)))
        // A reserved key stays on the editor and surfaces the error on the keyboard instead of saving.
        model.insertText("WINEMSYNC=0")
        model.finishText()
        XCTAssertEqual(model.panel, .textEditor(.runtimeText(id, .environmentVariables)))
        XCTAssertEqual(model.keyboardError, "WINEMSYNC is set by Playden. Use the matching setting instead.")
        XCTAssertNil(model.gameSettingsError)
        XCTAssertNil(model.runtimeProfiles[id]?.overrides[.environmentVariables])
        // Fixing the text and confirming again persists the override and returns to the sheet.
        for _ in 0..<model.textEditor.text.count { model.eraseText() }
        model.insertText("WINE_CPU_TOPOLOGY=8:0,1,2,3,4,5,6,7")
        model.finishText()
        XCTAssertEqual(model.panel, .gameSettings(id))
        XCTAssertNil(model.gameSettingsError)
        XCTAssertEqual(model.runtimeProfiles[id]?.overrides[.environmentVariables], .list(["WINE_CPU_TOPOLOGY=8:0,1,2,3,4,5,6,7"]))
    }

    /// Regression for a Tier 3 save failure discarding the typed text: with no catalog, `persistRuntimeProfile`
    /// throws (the `catalog == nil && !isPreview` persistence rule), so `setOverride` must report failure and
    /// `finishText` must keep the editor open with the text intact rather than closing it.
    func testFailedRuntimeTextSaveKeepsEditorOpenAndText() throws {
        let model = LibraryModel(catalog: nil, preview: false)
        model.showGameSettings(id)
        let rowIndex = try XCTUnwrap(model.settingsRows(for: id).firstIndex(of: .setting(.environmentVariables)))
        model.settingsFocus = rowIndex
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .textEditor(.runtimeText(id, .environmentVariables)))
        XCTAssertFalse(model.setOverride(id, .synchronization, .scalar("esync")), "Persisting without a catalog must fail")
        model.insertText("WINE_CPU_TOPOLOGY=8:0,1,2,3,4,5,6,7")
        model.finishText()
        XCTAssertEqual(model.panel, .textEditor(.runtimeText(id, .environmentVariables)))
        XCTAssertEqual(model.keyboardError, "Could not save game settings. Try again.")
        XCTAssertEqual(model.textEditor.text, "WINE_CPU_TOPOLOGY=8:0,1,2,3,4,5,6,7")
        XCTAssertNil(model.runtimeProfiles[id]?.overrides[.environmentVariables])
    }

    // MARK: - Launch option picker

    func testLaunchOptionPickerScrollsFocusThroughManyChoices() throws {
        let catalog = try CatalogStore()
        let model = try makeModel(catalog)
        model.gameLaunchOptions[id] = (0..<6).map { index in
            LaunchOption(id: "option-\(index)", title: "Option \(index)", spec: LaunchSpec(executableRelativePath: "game\(index).exe"))
        }
        model.showSettingPicker(id, .launchOption)
        XCTAssertEqual(model.pickerChoices(id, .launchOption).count, 6)
        for _ in 0..<5 { model.perform(.move(.down)) }
        XCTAssertEqual(model.pickerIndex, 5)
        // Scrolling itself (`GameSettingPickerView`'s `ScrollViewReader`) was verified by reasoning and build only.
    }

    // MARK: - Profile comparison

    func testProfileComparisonIncludesChosenLaunchOption() throws {
        let catalog = try CatalogStore()
        let model = try makeModel(catalog)
        model.gameLaunchOptions[id] = [
            LaunchOption(id: "primary", title: "Play Game", spec: LaunchSpec(executableRelativePath: "game.exe")),
            LaunchOption(id: "editor", title: "Level Editor", spec: LaunchSpec(executableRelativePath: "editor.exe")),
        ]
        XCTAssertFalse(model.comparison(id, with: "playden-default").contains { $0.id == .launchOption },
            "No launch option chosen yet, so no row")
        model.setOverride(id, .launchOption, .scalar("editor"))
        let row = try XCTUnwrap(model.comparison(id, with: "playden-default").first { $0.id == .launchOption })
        XCTAssertTrue(row.changed)
        XCTAssertEqual(row.current, "Level Editor")
        XCTAssertEqual(row.proposed, "Default")
    }
}
