import XCTest
import AppKit
import Domain
import Catalog
@testable import BigScreen

final class LogInteractionTests: XCTestCase {
    @MainActor func testDirectionalAndPageInputScrollsWithoutEscapingModal() throws {
        let catalog = try CatalogStore()
        var job = JobRecord(gameID: .init(source: "fake", value: "log"))
        job.state = .failed; job.failure = .init(stage: "Download", reason: "Connection lost", output: "Diagnostics")
        try catalog.saveJob(job)
        let model = LibraryModel(catalog: catalog, preview: false, diagnosticArchive: DiagnosticArchive(root: URL(fileURLWithPath: "/unused")))
        model.show(.logs(job.gameID)); let tab = model.tab
        XCTAssertEqual(model.logDocument?.id, job.id)
        model.perform(.move(.down)); XCTAssertEqual(model.logScrollRequest.points, 90)
        model.perform(.nextPage); XCTAssertEqual(model.logScrollRequest.points, 450)
        model.perform(.previousPage); XCTAssertEqual(model.logScrollRequest.points, -450)
        model.perform(.move(.up)); XCTAssertEqual(model.logScrollRequest.sequence, 4)
        model.perform(.nextTab); XCTAssertEqual(model.tab, tab); XCTAssertEqual(model.panel, .logs(job.gameID))
        model.perform(.move(.right)); XCTAssertEqual(model.logActionIndex, 1)
        model.perform(.move(.left)); model.perform(.confirm); XCTAssertNil(model.panel)
        model.show(.logs(job.gameID)); XCTAssertEqual(model.logActionIndex, 0); XCTAssertEqual(model.logScrollRequest.sequence, 0)
        model.perform(.back); XCTAssertNil(model.panel)
    }
    @MainActor func testEmptyLogCannotFocusUnavailableFinderAction() {
        let model = LibraryModel()
        model.show(.logs(.init(source: "fake", value: "empty")))
        model.perform(.move(.right)); XCTAssertEqual(model.logActionIndex, 0)
        model.perform(.confirm); XCTAssertNil(model.panel)
    }
    @MainActor func testNativeViewportWrapsLongLinesAndScrollsToBothEdges() {
        let scroll = DiagnosticScrollView(frame: .init(x: 0, y: 0, width: 800, height: 400))
        let text = NSTextView(frame: .zero)
        text.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.string = String(repeating: "Long diagnostic output that must wrap without hiding content. ", count: 300)
        scroll.documentView = text; scroll.layout()
        XCTAssertGreaterThan(text.frame.height, 400)
        let maximum = text.frame.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: .init(x: 0, y: maximum))
        XCTAssertEqual(scroll.contentView.bounds.minY, maximum, accuracy: 1)
        scroll.contentView.scroll(to: .zero)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
    }
}
