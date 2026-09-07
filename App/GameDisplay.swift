import AppKit
import ColorSync
import CoreGraphics
import Domain
import Runner

@MainActor
enum GameDisplay {
    static func target(preferences: LibraryPreferences) -> GameDisplayTarget? {
        func id(_ screen: NSScreen) -> UInt32? {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        let preferred = NSScreen.screens.first { screen in
            guard let displayID = id(screen) else { return false }
            if let uuid = preferences.selectedDisplayUUID {
                guard let value = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return false }
                return CFUUIDCreateString(nil, value) as String == uuid
            }
            return displayID == preferences.selectedDisplayID
        }
        // Keep a disconnected preference saved; this launch follows the launcher's current screen.
        guard let screen = preferred ?? NSApp.mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first,
              let displayID = id(screen) else { return nil }
        return .init(bounds: CGDisplayBounds(displayID), primaryBounds: CGDisplayBounds(CGMainDisplayID()))
    }
}
