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

    var fullscreenControlEnabled: Bool { !immersiveMode && !immersiveModeChanging && !fullscreenTransitioning }
    var immersiveFullscreen: Bool { immersiveMode || startInFullscreen }

    func requestFullscreen() {
        guard fullscreenControlEnabled else { return }
        if let onFullscreenRequested { onFullscreenRequested(!isFullscreen) }
        else if isPreview { fullscreenDidChange(!isFullscreen) }
    }

    func fullscreenDidChange(_ enabled: Bool, remember: Bool = true) {
        isFullscreen = enabled
        guard remember, !immersiveMode else { return }
        do {
            try updateSetupPreferences { $0.startInFullscreen = enabled }
            startInFullscreen = enabled
        } catch {
            persistenceError = error.localizedDescription
            show(.persistenceFailure)
        }
    }

    func toggleImmersiveMode() {
        guard !immersiveModeChanging, !fullscreenTransitioning else { return }
        do {
            let enabled = !immersiveMode
            // Keep the normal window mode as the restoration value across app launches.
            let previousFullscreen = isFullscreen
            try updateSetupPreferences {
                $0.immersiveMode = enabled
                if enabled { $0.startInFullscreen = previousFullscreen }
            }
            if enabled { startInFullscreen = previousFullscreen }
            immersiveMode = enabled; immersiveModeError = nil
            onImmersiveModeChanged?()
            if isPreview { fullscreenDidChange(immersiveFullscreen, remember: false) }
        } catch {
            persistenceError = error.localizedDescription
            show(.persistenceFailure)
        }
    }

    func exitImmersiveAfterDisplayLoss() {
        guard immersiveMode else { return }
        immersiveMode = false
        immersiveModeChanging = false
        do { try updateSetupPreferences { $0.immersiveMode = false } }
        catch { persistenceError = error.localizedDescription; show(.persistenceFailure) }
        onImmersiveModeChanged?()
        immersiveModeError = "Immersive mode ended because the selected display disconnected or its display helper stopped."
    }

    func shouldStartFullscreen(arguments: [String]) -> Bool {
        if !isPreview && immersiveMode { return true }
        if arguments.contains("--fullscreen") { return true }
        if arguments.contains("--windowed") { return false }
        return !isPreview && startInFullscreen
    }
}
