import Testing
@testable import Focus

@Test func incompleteRowRetainsIntendedColumn() {
    var cursor = GridCursor(index: 5)
    #expect(cursor.move(.down, count: 9, columns: 6) == true)
    #expect(cursor.index == 8)
    #expect(cursor.move(.up, count: 9, columns: 6) == true)
    #expect(cursor.index == 5)
}

@Test func edgesHandOffWithoutWrapping() {
    var cursor = GridCursor(index: 6)
    #expect(cursor.move(.left, count: 12, columns: 6) == false)
    #expect(cursor.index == 6)
    #expect(cursor.move(.down, count: 12, columns: 6) == false)
    #expect(cursor.move(.right, count: 0, columns: 6) == false)
}

@Test func repeatAndRelease() {
    var repeatState = DirectionRepeater()
    #expect(repeatState.update(.right, at: 0) == .right)
    #expect(repeatState.update(.right, at: 0.39) == nil)
    #expect(repeatState.update(.right, at: 0.4) == .right)
    #expect(repeatState.update(.right, at: 0.5) == nil)
    #expect(repeatState.update(.right, at: 0.53) == .right)
    #expect(repeatState.update(.right, at: 1.5) == .right)
    #expect(repeatState.update(.right, at: 1.57) == .right)
    #expect(repeatState.update(nil, at: 1.58) == nil)
    #expect(repeatState.update(.right, at: 1.59) == .right)
}

@Test func deadzoneAndAxisResolution() {
    #expect(DirectionRepeater.direction(x: 0.1, y: 0.1) == nil)
    #expect(DirectionRepeater.direction(x: 0.8, y: 0.4) == .right)
    #expect(DirectionRepeater.direction(x: -0.2, y: -0.9) == .down)
}

@Test func viewportRevealsFocusInBothDirectionsOver600Games() {
    var offset = 0.0
    let viewport = 840.0, content = 48.0 + 100 * 339
    for index in Array(0..<600) + Array((0..<600).reversed()) {
        let top = 24 + Double(index / 6) * 339
        offset = FocusViewport.reveal(offset: offset, itemMin: top, itemMax: top + 315, viewport: viewport, content: content)
        #expect(top - offset >= 24)
        #expect(top + 315 - offset <= viewport - 24)
    }
    #expect(offset == 0)
}
