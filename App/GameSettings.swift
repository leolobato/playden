import Foundation
import Domain
import Input
import Focus

enum GameSettingsRow: Equatable { case profile, moreSettings, setting(RuntimeSettingID), resetAll }

/// Validates the free-text Tier 3 settings (`launchArguments`, `environmentVariables`, `libraryOverrides`)
/// before they're saved as overrides. Mirrors the launch-time checks in `CrossOverRunner.arguments` and
/// `RuntimeMechanisms.managedKeys` (`Packages/PlaydenKit/Sources/Runner/CrossOverRunner.swift` and
/// `RuntimeSettingsApplication.swift`); duplicated here since `RuntimeMechanisms` is `internal` to Runner.
enum RuntimeTextValidation {
    /// Environment keys CrossOver/Wine itself needs; a user value would collide with the process launch.
    fileprivate static let deniedEnvironmentKeys: Set<String> = [
        "HOME", "PATH", "WINEPREFIX", "CX_BOTTLE", "CX_ROOT", "XDG_CONFIG_HOME", "CX_DIRECT_DESKTOP", "CODEX_HOME", "PLAYDEN_AUDIO_DEVICE_UID"
    ]
    /// Environment keys Playden itself manages through other settings rows.
    fileprivate static let managedEnvironmentKeys: Set<String> = [
        "CX_GRAPHICS_BACKEND", "WINEMSYNC", "WINEESYNC", "DXVK_FRAME_RATE", "MTL_HUD_ENABLED", "DXVK_HUD", "WINE_LARGE_ADDRESS_AWARE"
    ]
    private static let environmentKeyPattern = #"^[A-Za-z_][A-Za-z0-9_]*$"#
    private static let libraryOverridePattern = #"^[A-Za-z0-9_.*-]+=(n|b|d|n,b|b,n)$"#

    static func parse(_ text: String, for setting: RuntimeSettingID) -> Result<[String], RuntimeTextError> {
        switch setting {
        case .launchArguments: launchArguments(text)
        case .environmentVariables: environmentVariables(text)
        case .libraryOverrides: libraryOverrides(text)
        default: .success([])
        }
    }

    private static func launchArguments(_ text: String) -> Result<[String], RuntimeTextError> {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return .failure(.malformed("")) }
        let tokens = splitHonoringQuotes(text)
        guard tokens.count <= 20, tokens.allSatisfy({ $0.count <= 200 }) else { return .failure(.malformed("")) }
        return .success(tokens)
    }
    /// Whitespace-splits `text`, treating a double-quoted span as a single argument with the quotes removed.
    private static func splitHonoringQuotes(_ text: String) -> [String] {
        var tokens: [String] = [], current = "", inQuotes = false, hasToken = false
        for character in text {
            if character == "\"" { inQuotes.toggle(); hasToken = true; continue }
            if character.isWhitespace && !inQuotes {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(character); hasToken = true
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    /// Later occurrences of a duplicate key win, but the key keeps its first-seen position.
    private static func environmentVariables(_ text: String) -> Result<[String], RuntimeTextError> {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return .failure(.malformed("")) }
        var order: [String] = [], values: [String: String] = [:]
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard let equals = token.firstIndex(of: "=") else { return .failure(.malformed(token)) }
            let key = String(token[token.startIndex..<equals]), value = String(token[token.index(after: equals)...])
            guard key.range(of: environmentKeyPattern, options: .regularExpression) != nil, value.count <= 500 else {
                return .failure(.malformed(token))
            }
            guard !managedEnvironmentKeys.contains(key), !deniedEnvironmentKeys.contains(key), !key.hasPrefix("DYLD_") else {
                return .failure(.reservedKey(key))
            }
            if values[key] == nil { order.append(key) }
            values[key] = value
        }
        return .success(order.map { "\($0)=\(values[$0]!)" })
    }

    /// Later occurrences of a duplicate library name win, but the name keeps its first-seen position.
    private static func libraryOverrides(_ text: String) -> Result<[String], RuntimeTextError> {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return .failure(.malformed("")) }
        var order: [String] = [], values: [String: String] = [:]
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard let equals = token.firstIndex(of: "="), token.range(of: libraryOverridePattern, options: .regularExpression) != nil else {
                return .failure(.invalidOverride(token))
            }
            let name = String(token[token.startIndex..<equals])
            if values[name] == nil { order.append(name) }
            values[name] = token
        }
        return .success(order.map { values[$0]! })
    }
}

enum RuntimeTextError: Error, Equatable {
    case malformed(String), reservedKey(String), invalidOverride(String)
    var message: String {
        switch self {
        case .malformed(let token): token.isEmpty ? "Check the text and try again." : "\(token) isn’t KEY=VALUE."
        case .reservedKey(let key):
            RuntimeTextValidation.managedEnvironmentKeys.contains(key)
                ? "\(key) is set by Playden. Use the matching setting instead." : "\(key) can’t be changed here."
        case .invalidOverride(let token): "\(token) isn’t a library override. Use name=n,b, name=b or name=d."
        }
    }
}

extension LibraryModel {
    func profile(for id: GameID) -> RuntimeProfile { runtimeProfiles[id] ?? RuntimeProfile() }
    func profileLabel(_ id: GameID) -> String { RuntimeResolver.displayName(profile(for: id), catalog: profileCatalog) }
    /// The base profile's own name, without the "Custom · from" prefix — for the picker footnote and toast.
    func profileName(_ id: GameID) -> String {
        guard let baseID = profile(for: id).base, let curated = profileCatalog[baseID] else { return "Playden default" }
        return curated.name
    }
    func resolvedValues(_ id: GameID) -> (resolved: [RuntimeSettingID: RuntimeSettingValue], base: [RuntimeSettingID: RuntimeSettingValue]) {
        RuntimeResolver.values(profile(for: id), catalog: profileCatalog)
    }
    func settingsRows(for id: GameID) -> [GameSettingsRow] {
        var rows: [GameSettingsRow] = [.profile] + GameSettingsCatalog.rows(in: .tier1).map { .setting($0.id) } + [.moreSettings]
        if moreSettingsExpanded { rows += GameSettingsCatalog.rows(in: .tier2).map { .setting($0.id) } }
        rows += GameSettingsCatalog.rows(in: .advanced).map { .setting($0.id) }
        rows.append(.resetAll)
        return rows
    }
    var focusedSettingsRow: GameSettingsRow? {
        guard case .gameSettings(let id) = panel else { return nil }
        return settingsRows(for: id)[safe: settingsFocus]
    }
    func rowValueLabel(_ id: GameID, _ setting: RuntimeSettingID) -> String {
        GameSettingsCatalog.valueLabel(setting, value: resolvedValues(id).resolved[setting], launchOptions: gameLaunchOptions[id] ?? [])
    }
    func rowDiffers(_ id: GameID, _ setting: RuntimeSettingID) -> Bool { profile(for: id).overrides[setting] != nil }

    func showGameSettings(_ id: GameID) {
        settingsFocus = 0; moreSettingsExpanded = false; settingsScrollOffset = 0; settingsChangedCount = 0
        gameSettingsError = nil
        show(.gameSettings(id))
    }
    /// Back from a picker or the profile chooser keeps the sheet's focus and change count.
    func returnToGameSettings(_ id: GameID) { panel = .gameSettings(id) }
    func closeGameSettings() {
        guard case .gameSettings(let id) = panel else { panel = nil; return }
        panel = nil
        guard settingsChangedCount > 0 else { return }
        enqueueNotification(.init(source: .settings(id), tone: .success,
            title: "Settings saved · \(profileLabel(id))",
            detail: settingsChangedCount == 1 ? "1 change applies on next launch" : "\(settingsChangedCount) changes apply on next launch"))
    }

    private func persistRuntimeProfile(_ profile: RuntimeProfile, for id: GameID) throws {
        if let catalog {
            var edits = try catalog.edits(for: id)
            edits.runtime = profile
            try catalog.saveEdits(edits, for: id)
        } else if !isPreview {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    func setOverride(_ id: GameID, _ setting: RuntimeSettingID, _ value: RuntimeSettingValue?) {
        var updated = profile(for: id)
        if let value { updated.overrides[setting] = value } else { updated.overrides.removeValue(forKey: setting) }
        let normalized = RuntimeResolver.normalized(updated, catalog: profileCatalog)
        guard normalized != profile(for: id) else { return }
        do {
            try persistRuntimeProfile(normalized, for: id)
            runtimeProfiles[id] = normalized
            settingsChangedCount += 1
        } catch {
            gameSettingsError = "Could not save game settings. Try again."
        }
    }
    func resetAllToProfile(_ id: GameID) {
        var updated = profile(for: id)
        let removed = updated.overrides.count
        guard removed > 0 else { return }
        updated.overrides = [:]
        do {
            try persistRuntimeProfile(updated, for: id)
            runtimeProfiles[id] = updated
            settingsChangedCount += removed
        } catch {
            gameSettingsError = "Could not save game settings. Try again."
        }
    }
    func applyProfile(_ id: GameID, profileID: String) {
        let updated = RuntimeProfile(base: profileID, overrides: [:], source: .profile, appliedAt: .now)
        guard updated != profile(for: id) else { return }
        do {
            try persistRuntimeProfile(updated, for: id)
            runtimeProfiles[id] = updated
            settingsChangedCount += 1
        } catch {
            gameSettingsError = "Could not save game settings. Try again."
        }
    }

    // MARK: - Picker
    func showSettingPicker(_ id: GameID, _ setting: RuntimeSettingID) {
        let choices = pickerChoices(id, setting)
        let currentValue = resolvedValues(id).resolved[setting]
        pickerIndex = choices.firstIndex { choice in
            guard case .scalar(let raw)? = currentValue else { return false }
            return choice.value == raw
        } ?? 0
        panel = .settingPicker(id, setting)
    }
    /// `.launchOption` synthesizes one choice per the game's own launch options; the first is the default.
    func pickerChoices(_ id: GameID, _ setting: RuntimeSettingID) -> [RuntimeSettingChoice] {
        switch GameSettingsCatalog.definition(setting).kind {
        case .choices(let choices): return choices
        case .launchOption:
            return (gameLaunchOptions[id] ?? []).map { option in
                RuntimeSettingChoice(value: option.id, name: option.title, shortName: option.title,
                    explanation: "Starts this launch entry.", technicalNames: option.spec.executableRelativePath)
            }
        case .text: return []
        }
    }
    /// "Playden default" wins over "From profile" when a choice happens to be both.
    func pickerMeta(_ id: GameID, _ setting: RuntimeSettingID, choice: RuntimeSettingChoice) -> String? {
        let isDefault: Bool
        if case .launchOption = GameSettingsCatalog.definition(setting).kind {
            isDefault = pickerChoices(id, setting).first?.value == choice.value
        } else {
            isDefault = GameSettingsCatalog.isDefaultValue(setting, choice.value)
        }
        if isDefault { return "Playden default" }
        if case .scalar(let base)? = resolvedValues(id).base[setting], base == choice.value { return "From profile" }
        return nil
    }
    func activatePickerChoice() {
        guard case .settingPicker(let id, let setting) = panel, let choice = pickerChoices(id, setting)[safe: pickerIndex] else { return }
        setOverride(id, setting, .scalar(choice.value))
        returnToGameSettings(id)
    }

    // MARK: - Profile chooser
    func showProfileChooser(_ id: GameID) {
        let current = profile(for: id)
        if current.isCustom { chooserIndex = profileCatalog.profiles.count }
        else {
            let baseID = current.base ?? CuratedProfileCatalog.playdenDefaultID
            chooserIndex = profileCatalog.profiles.firstIndex { $0.id == baseID } ?? 0
        }
        panel = .profileChooser(id)
    }
    /// `nil` stands in for the trailing Custom row, shown only while the profile has overrides.
    func chooserRows(_ id: GameID) -> [CuratedProfile?] {
        var rows: [CuratedProfile?] = profileCatalog.profiles
        if profile(for: id).isCustom { rows.append(nil) }
        return rows
    }
    struct SettingComparison: Equatable { let id: RuntimeSettingID; let title: String; let current: String; let proposed: String; let changed: Bool }
    /// Rows where the game's current value or the candidate profile's value differs from the Playden default.
    func comparison(_ id: GameID, with profileID: String) -> [SettingComparison] {
        guard let curated = profileCatalog[profileID] else { return [] }
        let resolved = resolvedValues(id).resolved
        var proposedValues = RuntimeResolver.defaultValues
        for (key, value) in curated.settings { proposedValues[key] = value }
        let launchOptions = gameLaunchOptions[id] ?? []
        return RuntimeSettingID.allCases.filter { $0 != .launchOption }.compactMap { settingID in
            let currentValue = resolved[settingID]
            let proposedValue = proposedValues[settingID]
            let defaultValue = RuntimeResolver.defaultValues[settingID]
            guard currentValue != defaultValue || proposedValue != defaultValue || currentValue != proposedValue else { return nil }
            let currentLabel = GameSettingsCatalog.valueLabel(settingID, value: currentValue, launchOptions: launchOptions)
            let proposedLabel = GameSettingsCatalog.valueLabel(settingID, value: proposedValue, launchOptions: launchOptions)
            return SettingComparison(id: settingID, title: GameSettingsCatalog.definition(settingID).title,
                current: currentLabel, proposed: proposedLabel, changed: currentLabel != proposedLabel)
        }
    }
    func activateChooserSelection() {
        guard case .profileChooser(let id) = panel, let row = chooserRows(id)[safe: chooserIndex] else { return }
        if let curated = row { applyProfile(id, profileID: curated.id) }
        returnToGameSettings(id)
    }

    // MARK: - Input
    func performGameSettingsInput(_ action: InputAction) -> Bool {
        switch panel {
        case .gameSettings(let id):
            let rows = settingsRows(for: id)
            switch action {
            case .move(let direction):
                if direction == .up { settingsFocus = max(0, settingsFocus - 1) }
                else if direction == .down { settingsFocus = min(max(0, rows.count - 1), settingsFocus + 1) }
                // .left/.right have nothing to do in this single-column list.
            case .confirm:
                switch rows[safe: settingsFocus] {
                case .profile: showProfileChooser(id)
                case .moreSettings:
                    moreSettingsExpanded.toggle()
                    settingsFocus = min(settingsFocus, max(0, settingsRows(for: id).count - 1))
                case .setting(let setting):
                    switch GameSettingsCatalog.definition(setting).kind {
                    case .choices, .launchOption: showSettingPicker(id, setting)
                    case .text: beginText(.runtimeText(id, setting))
                    }
                case .resetAll: if profile(for: id).isCustom { resetAllToProfile(id) }
                case nil: break
                }
            case .back: closeGameSettings()
            case .context: if case .setting(let setting) = rows[safe: settingsFocus] { setOverride(id, setting, nil) }
            case .previousPage: settingsFocus = max(0, settingsFocus - 5)
            case .nextPage: settingsFocus = min(max(0, rows.count - 1), settingsFocus + 5)
            default: break
            }
            return true
        case .settingPicker(let id, let setting):
            switch action {
            case .move(let direction):
                let choices = pickerChoices(id, setting)
                pickerIndex = min(max(0, pickerIndex + (direction == .up || direction == .left ? -1 : 1)), max(0, choices.count - 1))
            case .confirm: activatePickerChoice()
            case .back: returnToGameSettings(id)
            case .context: setOverride(id, setting, nil); returnToGameSettings(id)
            default: break
            }
            return true
        case .profileChooser(let id):
            switch action {
            case .move(let direction):
                if direction == .up { chooserIndex = max(0, chooserIndex - 1) }
                else if direction == .down { chooserIndex = min(max(0, chooserRows(id).count - 1), chooserIndex + 1) }
            case .confirm: activateChooserSelection()
            case .back: returnToGameSettings(id)
            default: break
            }
            return true
        default: return false
        }
    }
}
