import XCTest
import SwiftUI
import Vision
@testable import BigScreen

@MainActor final class ExitOverlayLayoutTests: XCTestCase {
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
                if let path = ProcessInfo.processInfo.environment["BIGSCREEN_TEST_SNAPSHOT_DIR"] {
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
