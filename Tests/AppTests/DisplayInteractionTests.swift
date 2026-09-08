import XCTest
import Catalog
import Domain
@testable import Playden

final class DisplayInteractionTests: XCTestCase {
    @MainActor func testAudioSelectionPersistsAndDisconnectedDeviceFallsBackWithoutLosingPreference() throws {
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog, preview: false)
        let output = AudioDeviceChoice(id: "stable-output-uid", name: "Living room speakers")
        model.audioDevices = [output]; model.setupScreen = .audio; model.setupIndex = 1
        model.perform(.confirm)
        XCTAssertNil(model.setupScreen)
        XCTAssertEqual(try catalog.preferences().selectedAudioDeviceUID, output.id)
        model.downloadWhilePlaying = true
        let restored = LibraryModel(catalog: catalog, preview: false)
        XCTAssertEqual(restored.selectedAudioDeviceUID, output.id)
        XCTAssertTrue(restored.audioSummary.contains("disconnected"))
        restored.audioDevices = [output]
        XCTAssertTrue(restored.audioSummary.hasPrefix(output.name))
        restored.setupScreen = .audio; restored.setupIndex = 0; restored.perform(.confirm)
        XCTAssertNil(try catalog.preferences().selectedAudioDeviceUID)
        XCTAssertNil(try catalog.preferences().selectedAudioDeviceName)
        XCTAssertTrue(restored.audioSummary.hasPrefix("System default"))
    }
    @MainActor func testAudioSettingsAreReachableWithControllerAndBackDoesNotChangeSelection() {
        let model = LibraryModel()
        model.selectTab(.settings); model.settingsRailFocused = true; model.settingsSection = 2
        model.perform(.move(.down)); XCTAssertEqual(model.settingsSection, 3)
        model.perform(.confirm); model.perform(.confirm)
        XCTAssertEqual(model.setupScreen, .audio)
        model.perform(.back)
        XCTAssertNil(model.setupScreen)
        XCTAssertNil(model.selectedAudioDeviceUID)
    }

    @MainActor func testStartupPreferenceSurvivesOtherSettingsAndLaunchOverridesAreTemporary() throws {
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog, preview: false)
        XCTAssertTrue(model.shouldStartFullscreen(arguments: []))
        model.selectTab(.settings); model.settingsSection = 2; model.settingsRailFocused = false
        model.settingsIndex = 2; model.perform(.confirm)
        XCTAssertFalse(model.startInFullscreen)
        model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(model.settingsIndex, 3)
        XCTAssertTrue(model.reducedMotion)
        model.perform(.move(.down)); XCTAssertEqual(model.settingsIndex, 3)
        let restored = LibraryModel(catalog: catalog, preview: false)
        XCTAssertFalse(restored.shouldStartFullscreen(arguments: []))
        XCTAssertTrue(restored.shouldStartFullscreen(arguments: ["--fullscreen"]))
        XCTAssertFalse(try XCTUnwrap(catalog.preferences().startInFullscreen))
        restored.toggleStartInFullscreen()
        XCTAssertFalse(restored.shouldStartFullscreen(arguments: ["--windowed"]))
        XCTAssertTrue(try XCTUnwrap(catalog.preferences().startInFullscreen))
    }

    @MainActor func testCurrentFullscreenUsesWindowAcknowledgementAndDoesNotChangeStartup() throws {
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog, preview: false)
        var requests: [Bool] = []
        model.onFullscreenRequested = { requests.append($0) }
        model.requestFullscreen()
        XCTAssertEqual(requests, [true])
        XCTAssertFalse(model.isFullscreen)
        model.fullscreenTransitioning = true
        model.requestFullscreen()
        XCTAssertEqual(requests, [true])
        model.fullscreenTransitioning = false; model.isFullscreen = true
        model.requestFullscreen()
        XCTAssertEqual(requests, [true, false])
        XCTAssertNil(try catalog.preferences().startInFullscreen)
    }

    @MainActor func testMonitorIdentitySurvivesReconnectionWithoutSelectingRecycledID() throws {
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog, preview: false)
        model.displays = [DisplayChoice(id: 42, name: "TV", resolution: "3840 × 2160", uuid: "tv-uuid")]
        model.setupScreen = .display; model.perform(.confirm)
        model.downloadWhilePlaying = true
        let restored = LibraryModel(catalog: catalog, preview: false)
        restored.currentDisplayName = "Built-in display"
        restored.displays = [DisplayChoice(id: 42, name: "Desk", resolution: "1920 × 1080", uuid: "desk-uuid")]
        XCTAssertNil(restored.preferredDisplay)
        XCTAssertEqual(restored.displaySummary, "TV disconnected · Using Built-in display")
        restored.displays.append(DisplayChoice(id: 99, name: "TV", resolution: "3840 × 2160", uuid: "tv-uuid"))
        XCTAssertEqual(restored.preferredDisplay?.id, 99)
        XCTAssertEqual(try catalog.preferences().selectedDisplayUUID, "tv-uuid")
        XCTAssertTrue(restored.downloadWhilePlaying)
    }

    @MainActor func testOldProfilesKeepDisplayChoiceAndFullscreenDefault() throws {
        let data = Data(#"{"scope":{"all":{}},"sort":"name","reducedMotion":false,"downloadWhilePlaying":false,"selectedDisplayID":42,"setupCompleted":true}"#.utf8)
        let preferences = try JSONDecoder().decode(LibraryPreferences.self, from: data)
        let catalog = try CatalogStore(); try catalog.savePreferences(preferences)
        let model = LibraryModel(catalog: catalog, preview: false)
        model.displays = [DisplayChoice(id: 42, name: "TV", resolution: "3840 × 2160", uuid: "tv")]
        XCTAssertEqual(model.preferredDisplay?.id, 42)
        XCTAssertTrue(model.shouldStartFullscreen(arguments: []))
    }
}
