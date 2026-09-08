import XCTest
import SwiftUI
import Vision
import Domain
@testable import Playden

@MainActor final class ExitOverlayLayoutTests: XCTestCase {
    func testPreparingFilesAndInstallOnlyQuitShowProgressAndConsequences() throws {
        Design.registerFonts()
        for quit in [false, true] {
            let model = InstallSnapshots.model(for: "install-verifying-all")
            for index in model.games.indices { model.games[index].coverURL = nil; model.games[index].heroURL = nil }
            let index = try XCTUnwrap(model.installJobs.firstIndex { $0.id == model.activeInstallID })
            model.installJobs[index].stage = .stage
            let check = InstallFileVerification(file: "Game/Data0.bdt", bytesChecked: 32_000_000_000, bytesTotal: 64_000_000_000, scope: .installation)
            model.installTransfer = .init(bytesPerSecond: 0, secondsRemaining: nil, verification: check)
            model.installPreparation = .init(step: .verifying(check), sequence: 1)
            if quit { model.requestLauncherQuit() }
            let view = quit ? AnyView(GameExitOverlay(model: model)) : AnyView(LauncherView(model: model))
            let renderer = ImageRenderer(content: view.frame(width: 1920, height: 1080))
            let image = try XCTUnwrap(renderer.cgImage)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            let expected = quit ? ["quit playden", "keep launcher open", "downloaded files are kept", "file checks may restart"]
                : ["checking files before setup", "50%", "checked", "game/data", ".bdt"]
            for value in expected { XCTAssertTrue(text.contains(value), "Missing \(value): \(text)") }
            XCTAssertFalse(text.contains("quit game and launcher"))
            let attachment = XCTAttachment(image: NSImage(cgImage: image, size: .zero))
            let name = quit ? "quit-during-preparation" : "preparation-progress"
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png")
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: path)
        }
    }
    func testAudioPickerAndVisibleQuitActionsRenderAt1080() async throws {
        Design.registerFonts()
        for screen in ["audio", "about", "quit", "running"] {
            let model = LibraryModel(); model.fixedClock = true; model.reducedMotion = true
            for index in model.games.indices {
                model.games[index].coverURL = nil; model.games[index].heroURL = nil; model.games[index].logoURL = nil
            }
            let content: AnyView
            let expected: [String]
            if screen == "audio" {
                model.audioDevices = [.init(id: "tv", name: "Living room speakers"), .init(id: "headphones", name: "Wireless headphones")]
                model.selectedAudioDeviceUID = "tv"; model.setupScreen = .audio; model.setupIndex = 1
                content = AnyView(SetupView(model: model)); expected = ["choose your audio output", "system default", "living room speakers", "next launch"]
            } else if screen == "about" {
                model.selectTab(.settings); model.settingsSection = 5; model.settingsIndex = 0
                content = AnyView(LauncherView(model: model)); expected = ["quit playden", "reset app data"]
            } else if screen == "quit" {
                model.selectTab(.settings); model.settingsSection = 6; model.settingsRailFocused = true
                content = AnyView(LauncherView(model: model)); expected = ["quit playden", "downloads pause"]
            } else {
                model.configureSessionSnapshot("exit-overlay"); model.exitOverlay = false
                model.detailID = model.sessionGame?.id
                content = AnyView(LauncherView(model: model)); expected = ["return to game", "game settings", "more"]
            }
            // AppKit-backed scroll views need a hosting view to participate in snapshots.
            let hosting = NSHostingView(rootView: content.frame(width: 1920, height: 1080))
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1920, height: 1080),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let attachment = XCTAttachment(image: NSImage(cgImage: image, size: .zero))
            attachment.name = "audio-quit-\(screen)"; attachment.lifetime = .keepAlways; add(attachment)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            for value in expected { XCTAssertTrue(text.contains(value), "Missing \(value): \(text)") }
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("playden-audio-quit-review")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(screen).png"))
        }
    }
    func testDownloadsShowActualVerificationPercentageAt1080And4K() throws {
        Design.registerFonts()
        for width in [1920, 3840] {
            let model = InstallSnapshots.model(for: "install-verifying-all")
            let renderer = ImageRenderer(content: LauncherView(model: model).frame(width: 1920, height: 1080))
            renderer.scale = CGFloat(width) / 1920
            let image = try XCTUnwrap(renderer.cgImage)
            let attachment = XCTAttachment(image: NSImage(cgImage: image, size: .zero))
            attachment.name = "verification-percentage-\(width)"; attachment.lifetime = .keepAlways; add(attachment)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("verifying files"), text)
            XCTAssertTrue(text.contains("50%"), text)
            XCTAssertTrue(text.contains("checked"), text)
            XCTAssertFalse(text.contains("100%"), text)
        }
    }
    func testLongWarningKeepsConsequencesAndActionsVisibleAt1080And4K() throws {
        Design.registerFonts()
        for screen in ["launcher-quit-warning", "exit-overlay-warning"] {
            for width in [1920, 3840] {
                let model = LibraryModel()
                model.fixedClock = true; model.reducedMotion = true
                // Keep rendering independent of the network and the user's artwork cache.
                for index in model.games.indices {
                    model.games[index].coverURL = nil; model.games[index].heroURL = nil
                }
                model.configureSessionSnapshot(screen)
                let renderer = ImageRenderer(content: GameExitOverlay(model: model))
                renderer.scale = CGFloat(width) / 1920
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, width)
                XCTAssertEqual(image.height, width * 9 / 16)
                let attachment = XCTAttachment(image: NSImage(cgImage: image, size: .zero))
                attachment.name = "\(screen)-\(width)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
                for expected in ["unsaved progress may be lost", "keyboard focus",
                                 screen.hasPrefix("launcher") ? "keep launcher open" : "return to game",
                                 screen.hasPrefix("launcher") ? "quit game and launcher" : "quit game",
                                 screen.hasPrefix("launcher") ? "downloads pause" : "forces it after 10 seconds"] {
                    XCTAssertTrue(text.contains(expected), "Missing '\(expected)' in \(screen) at \(width): \(text)")
                }
                if let path = ProcessInfo.processInfo.environment["PLAYDEN_TEST_SNAPSHOT_DIR"] {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("\(screen)-\(width).png"))
                }
            }
        }
    }
}
