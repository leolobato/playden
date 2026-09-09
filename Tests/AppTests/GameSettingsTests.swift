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

    func testMoreSettingsTogglesTierTwoRowsAndResetAllClearsOverrides() throws {
        let catalog = try CatalogStore()
        let model = try makeModel(catalog)
        model.showGameSettings(id)
        let collapsedCount = model.settingsRows(for: id).count
        let moreIndex = try XCTUnwrap(model.settingsRows(for: id).firstIndex(of: .moreSettings))
        for _ in 0..<moreIndex { model.perform(.move(.down)) }
        model.perform(.confirm)
        XCTAssertTrue(model.moreSettingsExpanded)
        XCTAssertGreaterThan(model.settingsRows(for: id).count, collapsedCount)
        XCTAssertTrue(model.settingsRows(for: id).contains(.setting(.virtualDesktop)))
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
}
