import Foundation

/// A focus-driven viewport in logical design coordinates, independent of SwiftUI's scaled scroll views.
public enum FocusViewport {
    public static func reveal(offset: Double, itemMin: Double, itemMax: Double,
                              viewport: Double, content: Double, margin: Double = 24) -> Double {
        let maximum = max(0, content - viewport)
        var result = min(maximum, max(0, offset))
        if itemMin - margin < result { result = itemMin - margin }
        else if itemMax + margin > result + viewport { result = itemMax + margin - viewport }
        return min(maximum, max(0, result))
    }
}
