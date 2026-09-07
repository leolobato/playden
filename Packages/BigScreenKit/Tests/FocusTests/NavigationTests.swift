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
