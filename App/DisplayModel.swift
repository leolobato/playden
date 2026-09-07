import Foundation
import Domain

extension LibraryModel {
    var preferredDisplay: DisplayChoice? {
        // Numeric IDs can be reassigned after reconnecting a monitor. Once a UUID is
        // saved, never mistake another monitor with the old numeric ID for the preferred one.
        if let selectedDisplayUUID { return displays.first { $0.uuid == selectedDisplayUUID } }
        return displays.first { $0.id == selectedDisplayID }
    }

    var displaySummary: String {
        if let display = preferredDisplay { return "\(display.name) · \(display.resolution)" }
        if selectedDisplayUUID != nil || selectedDisplayID != nil {
            return "\(selectedDisplayName ?? "Preferred display") disconnected · Using \(currentDisplayName ?? "current display")"
        }
        return currentDisplayName ?? "Current display"
    }

    func requestFullscreen() {
        guard !fullscreenTransitioning else { return }
        if let onFullscreenRequested { onFullscreenRequested(!isFullscreen) }
        else if isPreview { isFullscreen.toggle() }
    }

    func toggleStartInFullscreen() {
        do {
            let enabled = !startInFullscreen
            try updateSetupPreferences { $0.startInFullscreen = enabled }
            startInFullscreen = enabled
        } catch {
            persistenceError = error.localizedDescription
            show(.persistenceFailure)
        }
    }

    func shouldStartFullscreen(arguments: [String]) -> Bool {
        if arguments.contains("--fullscreen") { return true }
        if arguments.contains("--windowed") { return false }
        return !isPreview && startInFullscreen
    }
}
