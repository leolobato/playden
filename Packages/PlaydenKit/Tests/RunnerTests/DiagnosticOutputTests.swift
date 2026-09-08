import XCTest
import Foundation
@testable import Runner

final class DiagnosticOutputTests: XCTestCase {
    func testTruncationCannotExposeTailOfOversizedCredentialAndStillDrains() {
        var buffer = DiagnosticOutputBuffer()
        buffer.append(Data("Ready\npassword=\"".utf8))
        for _ in 0..<100 { buffer.append(Data(repeating: 115, count: 8192)) }
        buffer.append(Data("\"\nFinished\n".utf8))
        XCTAssertTrue(buffer.text.contains("Ready")); XCTAssertTrue(buffer.text.contains("truncated"))
        XCTAssertFalse(buffer.text.contains("ssss")); XCTAssertTrue(buffer.text.contains("Finished"))
        XCTAssertLessThanOrEqual(buffer.text.utf8.count, 256 * 1024)
    }
    func testPartialCredentialAcrossPollsIsRedactedAndUnicodeIsPreserved() {
        var buffer = DiagnosticOutputBuffer()
        buffer.append(Data("password=\"PARTIAL".utf8))
        XCTAssertFalse(buffer.text.contains("PARTIAL"))
        buffer.append(Data("_SECRET\"\nReady 漢字\n".utf8))
        XCTAssertFalse(buffer.text.contains("SECRET")); XCTAssertTrue(buffer.text.contains("Ready 漢字"))
        var jwt = DiagnosticOutputBuffer(); jwt.append(Data("token eyJhbGciOiJIUzI1NiJ9.part".utf8))
        XCTAssertFalse(jwt.text.contains("eyJ"))
    }
    func testMultilineQuotedCredentialRemainsRedactedAfterOlderLinesRotate() {
        var buffer = DiagnosticOutputBuffer()
        buffer.append(Data("password=\"FIRST_LINE\n".utf8))
        for _ in 0..<200 { buffer.append(Data((String(repeating: "SECRET_CONTINUATION", count: 100) + "\n").utf8)) }
        buffer.append(Data("FINAL_SECRET\"\nAfter credential\n".utf8))
        for _ in 0..<100 { buffer.append(Data((String(repeating: "ordinary line ", count: 100) + "\n").utf8)) }
        XCTAssertFalse(buffer.text.contains("SECRET")); XCTAssertFalse(buffer.text.contains("FIRST_LINE"))
        XCTAssertTrue(buffer.text.contains("After credential")); XCTAssertTrue(buffer.text.contains("ordinary line"))
    }
}
