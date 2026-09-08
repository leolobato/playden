import Foundation

/// Distinguishes a tap on release from a one-second hold; each press emits only one action.
public struct HomeHold: Sendable {
    private var began: TimeInterval?
    private var fired = false
    public init() {}
    public enum Event: Equatable, Sendable { case tap, hold }

    public mutating func event(pressed: Bool, at time: TimeInterval) -> Event? {
        guard pressed else {
            defer { began = nil; fired = false }
            guard let began, !fired else { return nil }
            // A release can be the first poll after the hold threshold.
            return time - began >= 1 ? .hold : .tap
        }
        guard let began else { self.began = time; return nil }
        guard !fired, time - began >= 1 else { return nil }
        fired = true; return .hold
    }

    public mutating func update(pressed: Bool, at time: TimeInterval) -> Bool {
        event(pressed: pressed, at: time) == .hold
    }
}
