import Foundation

/// Fires once per press, using monotonic time. Releasing or changing controllers resets the hold.
public struct HomeHold: Sendable {
    private var began: TimeInterval?
    private var fired = false
    public init() {}
    public mutating func update(pressed: Bool, at time: TimeInterval) -> Bool {
        guard pressed else { began = nil; fired = false; return false }
        guard let began else { self.began = time; return false }
        guard !fired, time - began >= 1 else { return false }
        fired = true; return true
    }
}
