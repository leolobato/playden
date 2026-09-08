import Foundation
import Domain
import Input
import Runner
import AppKit

enum SetupScreen { case controller, display, audio, account, volume, runtime }
struct DisplayChoice: Identifiable, Equatable {
    var id: UInt32
    var name: String
    var resolution: String
    var uuid: String? = nil
}

extension LibraryModel {
    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
    }
    func startSetupServices() {
        guard !isPreview else { return }
        if let preferences = try? catalog?.preferences(), !preferences.setupCompleted {
            onboarding = true; setupScreen = .controller; setupIndex = 0
        }
        let (generation, previous) = beginSetupOperation()
        setupTask = Task { [weak self] in
            guard let self, let runtime else { return }
            await previous?.value
            guard setupGeneration == generation, !Task.isCancelled else { return }
            let info = await runtime.inspect()
            guard setupGeneration == generation, !Task.isCancelled else { return }
            runtimeInfo = info
        }
    }
    func openVolumeSetup(firstRun: Bool = false) {
        onboarding = firstRun; setupScreen = .volume; setupIndex = 0; setupFailure = nil
        let (generation, previous) = beginSetupOperation()
        setupBusy = true; volumeSaving = false
        setupTask = Task { [weak self] in
            guard let self else { return }
            await previous?.value
            guard setupGeneration == generation else { return }
            do {
                try Task.checkCancellation()
                guard let volumeStore else { throw setupIssue("Choose volume", "Volume selection is available in the live app.") }
                let volumes = try await volumeStore.availableVolumes()
                try Task.checkCancellation()
                availableVolumes = volumes
                guard setupGeneration == generation else { return }
                setupIndex = volumes.firstIndex(where: { $0.id == gamesVolume?.volumeID }) ?? volumes.firstIndex(where: \.isRecommended) ?? 0
                selectedVolumeID = volumes[safe: setupIndex]?.id
            } catch {
                guard setupGeneration == generation else { return }
                setupFailure = setupProblem(error, stage: "Choose volume")
            }
            setupBusy = false
        }
    }
    func openRuntimeSetup(firstRun: Bool = false) {
        onboarding = firstRun; setupScreen = .runtime; setupIndex = 0; setupFailure = runtimeInfo?.failure
        setupBusy = false
        if firstRun { prepareRuntime() }
        else { checkRuntime() }
    }
    func checkRuntime() {
        guard !setupBusy else { return }
        let (generation, previous) = beginSetupOperation()
        runtimeChecking = true; setupFailure = nil; setupIndex = 0
        setupTask = Task { [weak self] in
            guard let self else { return }
            await previous?.value
            guard setupGeneration == generation, !Task.isCancelled else { return }
            let info = await runtime?.inspect()
            guard setupGeneration == generation, !Task.isCancelled else { return }
            runtimeInfo = info
            setupFailure = info?.failure
            runtimeChecking = false
            templateStage = info?.templateReady == true ? .ready : .checking
            setupIndex = 0
        }
    }
    func prepareRuntime() {
        guard !setupBusy else { return }
        let (generation, previous) = beginSetupOperation()
        runtimeChecking = false; setupBusy = true; setupFailure = nil; setupIndex = 0; templateStage = .checking
        setupTask = Task { [weak self] in
            guard let self else { return }
            await previous?.value
            guard setupGeneration == generation else { return }
            do {
                try Task.checkCancellation()
                guard let runtime else { throw setupIssue("Prepare games", "Game setup is available in the live app.") }
                let info = try await runtime.prepareTemplate { [weak self] stage in
                    Task { @MainActor in
                        guard let self, self.setupGeneration == generation, self.setupBusy,
                              self.setupTask?.isCancelled == false else { return }
                        self.templateStage = stage
                    }
                }
                try Task.checkCancellation()
                guard setupGeneration == generation else { return }
                runtimeInfo = info; templateStage = info.templateReady ? .ready : templateStage
            } catch {
                guard setupGeneration == generation else { return }
                setupFailure = setupProblem(error, stage: "Prepare games")
            }
            setupBusy = false; setupIndex = 0
        }
    }
    var setupActions: [String] {
        switch setupScreen {
        case .controller: [controllerName == nil ? "Continue with keyboard" : "Continue", "Open Bluetooth settings"]
        case .display: displays.map { $0.name } + ["Back"]
        case .audio: ["System default"] + audioDevices.map(\.name) + ["Back"]
        case .volume:
            if setupBusy { volumeSaving ? ["Cancel"] : [] }
            else if setupFailure != nil { ["Choose another drive", onboarding ? "Set up later" : "Back"] }
            else { availableVolumes.map(\.name) + [onboarding ? "Set up later" : "Back"] }
        case .runtime:
            if setupBusy { ["Stop setup"] }
            else if runtimeChecking { ["Back"] }
            else if !onboarding {
                runtimeInfo?.templateReady == true && setupFailure == nil ? ["Check again", "Back"]
                    : [setupFailure == nil ? "Prepare games" : "Retry setup", "Check again", "Back"]
            }
            else if runtimeInfo?.templateReady == true && setupFailure == nil { [onboarding ? "Let’s play" : "Back"] }
            else { [setupFailure == nil ? "Prepare games" : "Retry", onboarding ? "Browse library" : "Back"] }
        default: []
        }
    }
    func performSetup(_ action: InputAction) {
        switch action {
        case .move(let direction): setupIndex = min(max(0, setupIndex + (direction == .up || direction == .left ? -1 : 1)), max(0, setupActions.count - 1))
        case .confirm: activateSetup()
        case .back:
            if setupBusy { setupTask?.cancel() }
            else if setupScreen == .display && onboarding { setupScreen = .controller; setupIndex = 0 }
            else { finishSetup() }
        default: break
        }
    }
    func activateSetup() {
        guard let action = setupActions[safe: setupIndex] else { return }
        switch setupScreen {
        case .controller:
            if setupIndex == 1 { openBluetoothSettings(); return }
            if displays.count > 1 { setupScreen = .display; setupIndex = 0 }
            else { advanceToAccount() }
        case .display:
            guard let display = displays[safe: setupIndex] else {
                if onboarding { setupScreen = .controller; setupIndex = 0 } else { finishSetup() }
                return
            }
            do {
                try updateSetupPreferences {
                    $0.selectedDisplayID = display.id; $0.selectedDisplayUUID = display.uuid; $0.selectedDisplayName = display.name
                }
                selectedDisplayID = display.id; selectedDisplayUUID = display.uuid; selectedDisplayName = display.name
                onDisplaySelected?(display.id)
                if onboarding { advanceToAccount() } else { finishSetup() }
            } catch { setupFailure = setupProblem(error, stage: "Choose display") }
        case .audio:
            if setupIndex == 0 { selectAudioDevice(nil) }
            else if let device = audioDevices[safe: setupIndex - 1] { selectAudioDevice(device) }
            else { finishSetup() }
        case .volume:
            if setupBusy { setupTask?.cancel() }
            else if setupFailure != nil {
                if setupIndex == 0 { openVolumeSetup(firstRun: onboarding) } else { finishSetup() }
            } else if let volume = availableVolumes[safe: setupIndex] { selectedVolumeID = volume.id; saveVolumeSelection() }
            else { finishSetup() }
        case .runtime:
            if action == "Stop setup" { setupTask?.cancel() }
            else if action == "Check again" { checkRuntime() }
            else if action == "Retry" || action == "Retry setup" || action == "Prepare games" { prepareRuntime() }
            else { finishSetup() }
        default: break
        }
    }
    private func advanceToAccount() {
        setupScreen = .account
        if identity != nil { openVolumeSetup(firstRun: true) }
        else { beginSignIn() }
    }
    private func saveVolumeSelection() {
        guard let volume = availableVolumes.first(where: { $0.id == selectedVolumeID }), let volumeStore else {
            setupFailure = setupIssue("Choose volume", "Connect a writable games drive, then retry."); setupIndex = 0; return
        }
        setupBusy = true; volumeSaving = true; setupIndex = 0
        let (generation, previous) = beginSetupOperation()
        setupTask = Task { [weak self] in
            guard let self else { return }
            await previous?.value
            guard setupGeneration == generation else { return }
            do {
                try Task.checkCancellation()
                let selection = try await volumeStore.select(volume)
                try Task.checkCancellation()
                guard setupGeneration == generation else { return }
                try updateSetupPreferences { $0.gamesVolume = selection }
                gamesVolume = selection; setupBusy = false
                if onboarding { openRuntimeSetup(firstRun: true) } else { finishSetup() }
            } catch {
                guard setupGeneration == generation else { return }
                setupBusy = false; setupFailure = setupProblem(error, stage: "Choose volume"); setupIndex = 0
            }
        }
    }
    func finishSetup() {
        do {
            if onboarding { try updateSetupPreferences { $0.setupCompleted = true } }
            setupGeneration = UUID(); setupTask?.cancel(); runtimeChecking = false; setupBusy = false; volumeSaving = false
            onboarding = false; setupScreen = nil; setupFailure = nil; setupIndex = 0
        } catch { setupFailure = setupProblem(error, stage: "Save setup") }
    }
    func updateSetupPreferences(_ update: (inout LibraryPreferences) -> Void) throws {
        guard let catalog else { if isPreview { return }; throw setupIssue("Save setup", "The library database is unavailable.") }
        var preferences = try catalog.preferences(); update(&preferences); try catalog.savePreferences(preferences)
    }
    /// Join the preceding worker before starting another. Generation checks also reject late
    /// results/progress from services that finish after cancellation or after this screen closes.
    private func beginSetupOperation() -> (UUID, Task<Void, Never>?) {
        let previous = setupTask
        previous?.cancel(); setupGeneration = UUID()
        return (setupGeneration, previous)
    }
    private func setupIssue(_ stage: String, _ reason: String) -> OperationFailure { OperationFailure(stage: stage, reason: reason, output: "") }
    private func setupProblem(_ error: Error, stage: String) -> OperationFailure {
        if error is CancellationError { return setupIssue(stage, "Setup was stopped. You can retry when you’re ready.") }
        return (error as? OperationFailure) ?? OperationFailure(stage: stage, reason: "This setup step could not finish. Try again.", output: error.localizedDescription)
    }
}
