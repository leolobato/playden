import Foundation

extension LibraryModel {
    var audioSummary: String {
        guard let selectedAudioDeviceUID else { return audioDeviceError ?? "System default · Applies when you launch a game" }
        if let choice = audioDevices.first(where: { $0.id == selectedAudioDeviceUID }) {
            return "\(choice.name) · Applies when you launch a game"
        }
        return "\(selectedAudioDeviceName ?? "Preferred device") disconnected · Using system default"
    }
    func refreshAudioDevices() {
        guard !isPreview else { return }
        let focused = setupScreen == .audio ? audioDevices[safe: setupIndex - 1]?.id : nil
        let wasBack = setupScreen == .audio && setupIndex == audioDevices.count + 1
        do { audioDevices = try AudioDevices.outputs(); audioDeviceError = nil }
        catch { audioDevices = []; audioDeviceError = "Audio devices unavailable · Using system default" }
        if setupScreen == .audio {
            if wasBack { setupIndex = audioDevices.count + 1 }
            else if let focused { setupIndex = audioDevices.firstIndex(where: { $0.id == focused }).map { $0 + 1 } ?? 0 }
        }
    }
    func openAudioSettings() {
        refreshAudioDevices()
        onboarding = false; setupFailure = nil; setupScreen = .audio
        setupIndex = audioDevices.firstIndex(where: { $0.id == selectedAudioDeviceUID }).map { $0 + 1 } ?? 0
    }
    func selectAudioDevice(_ choice: AudioDeviceChoice?) {
        do {
            try updateSetupPreferences { $0.selectedAudioDeviceUID = choice?.id; $0.selectedAudioDeviceName = choice?.name }
            selectedAudioDeviceUID = choice?.id; selectedAudioDeviceName = choice?.name
            finishSetup()
        } catch {
            setupFailure = .init(stage: "Choose audio device", reason: error.localizedDescription, output: error.localizedDescription)
        }
    }
}
