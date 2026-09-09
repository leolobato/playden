import Foundation
import Domain

enum RuntimeSettingTier: Equatable {
    case tier1, tier2, advanced
}

struct RuntimeSettingChoice: Equatable {
    let value: String
    let name: String
    let shortName: String
    let tag: String?
    let tagIsWarning: Bool
    let explanation: String
    let technicalNames: String

    init(value: String, name: String, shortName: String, tag: String? = nil, tagIsWarning: Bool = false,
         explanation: String, technicalNames: String) {
        self.value = value; self.name = name; self.shortName = shortName
        self.tag = tag; self.tagIsWarning = tagIsWarning
        self.explanation = explanation; self.technicalNames = technicalNames
    }
}

enum RuntimeSettingKind: Equatable {
    case choices([RuntimeSettingChoice])
    case launchOption
    case text
}

struct RuntimeSettingDefinition: Equatable {
    let id: RuntimeSettingID
    let title: String
    let effect: String
    let alsoCalled: String
    let tier: RuntimeSettingTier
    let kind: RuntimeSettingKind
    let changesBottle: Bool

    init(id: RuntimeSettingID, title: String, effect: String, alsoCalled: String, tier: RuntimeSettingTier,
         kind: RuntimeSettingKind, changesBottle: Bool = false) {
        self.id = id; self.title = title; self.effect = effect; self.alsoCalled = alsoCalled
        self.tier = tier; self.kind = kind; self.changesBottle = changesBottle
    }
}

/// Human-facing copy for every runtime setting: what it does, what it's also called, and (for
/// choice-based settings) each option's tradeoffs. Drives the game settings sheet; never mutates
/// `RuntimeProfile` itself.
enum GameSettingsCatalog {
    static let profileTitle = "Profile"
    static let profileEffect = "A ready-made bundle of the settings below. Pick one, then change anything you like."
    static let profileAlsoCalled = "runtime profile · stored with the install"

    static let all: [RuntimeSettingDefinition] = RuntimeSettingID.allCases.map(definition)

    static func definition(_ id: RuntimeSettingID) -> RuntimeSettingDefinition {
        switch id {
        case .graphics:
            return RuntimeSettingDefinition(
                id: .graphics, title: "Graphics",
                effect: "Picks the translator that turns the game’s DirectX graphics into the Mac’s Metal. Decides whether most games render at all, and how fast.",
                alsoCalled: "D3DMetal, DXVK, DXMT · CX_GRAPHICS_BACKEND", tier: .tier1,
                kind: .choices([
                    RuntimeSettingChoice(value: "d3dmetal", name: "Default", shortName: "D3DMetal", tag: "D3DMetal",
                                         explanation: "Apple’s own translator for DirectX 11 and 12. Usually the fastest for modern games.",
                                         technicalNames: "D3DMetal · Game Porting Toolkit"),
                    RuntimeSettingChoice(value: "dxvk", name: "DXVK", shortName: "DXVK", tag: "Community",
                                         explanation: "Turns DirectX 9, 10 and 11 into Vulkan, then MoltenVK turns that into Metal. Slower, very mature, fixes many visual bugs in older games.",
                                         technicalNames: "DXVK, MoltenVK, Vulkan"),
                    RuntimeSettingChoice(value: "dxmt", name: "DXMT", shortName: "DXMT", tag: "Community · experimental", tagIsWarning: true,
                                         explanation: "Turns DirectX 11 straight into Metal. Often faster than DXVK and renders some games correctly where D3DMetal glitches.",
                                         technicalNames: "DXMT"),
                ]), changesBottle: true)
        case .synchronization:
            return RuntimeSettingDefinition(
                id: .synchronization, title: "Synchronization",
                effect: "A speed boost for how the game’s many tasks wait for each other. The fastest mode makes a few games hang; try switching after Graphics.",
                alsoCalled: "MSync (WINEMSYNC), ESync (WINEESYNC)", tier: .tier1,
                kind: .choices([
                    RuntimeSettingChoice(value: "msync", name: "Default", shortName: "MSync", tag: "MSync",
                                         explanation: "The fastest method, Mac-only. Occasionally confuses a game into hanging.",
                                         technicalNames: "MSync · WINEMSYNC=1"),
                    RuntimeSettingChoice(value: "esync", name: "ESync", shortName: "ESync",
                                         explanation: "Faster than Wine’s original waiting, older than MSync and more widely tested.",
                                         technicalNames: "ESync · WINEESYNC=1"),
                    RuntimeSettingChoice(value: "off", name: "Off", shortName: "Off",
                                         explanation: "Wine’s original waiting. Slowest, most compatible.",
                                         technicalNames: "WINEMSYNC=0, WINEESYNC=0"),
                ]), changesBottle: true)
        case .controller:
            return RuntimeSettingDefinition(
                id: .controller, title: "Controller",
                effect: "How the game sees your pad. Xbox compatible works with nearly every game; Native passes a DualShock or DualSense through.",
                alsoCalled: "hidraw, WineBus · DisableHidraw", tier: .tier1,
                kind: .choices([
                    RuntimeSettingChoice(value: "xboxCompatible", name: "Xbox compatible", shortName: "Xbox compatible",
                                         explanation: "Presents the pad as a standard Xbox controller, which most PC games expect.",
                                         technicalNames: "hidraw off"),
                    RuntimeSettingChoice(value: "native", name: "Native", shortName: "Native",
                                         explanation: "Passes the real DualShock or DualSense through, for games that support them directly.",
                                         technicalNames: "hidraw on"),
                ]))
        case .windowsVersion:
            return RuntimeSettingDefinition(
                id: .windowsVersion, title: "Windows version",
                effect: "Which Windows the game is told it runs on. Older games sometimes refuse to start on Windows 10.",
                alsoCalled: "Windows Version · winecfg, cxstart --winver", tier: .tier1,
                kind: .choices([
                    RuntimeSettingChoice(value: "win10", name: "Windows 10", shortName: "Windows 10",
                                         explanation: "What Playden’s runtime claims by default.",
                                         technicalNames: "win10"),
                    RuntimeSettingChoice(value: "win81", name: "Windows 8.1", shortName: "Windows 8.1",
                                         explanation: "For games from around 2013 to 2015 that check the Windows version.",
                                         technicalNames: "win81"),
                    RuntimeSettingChoice(value: "win7", name: "Windows 7", shortName: "Windows 7",
                                         explanation: "Many games from 2009 to 2013 check for Windows 7 and refuse anything newer.",
                                         technicalNames: "win7"),
                ]))
        case .launchOption:
            return RuntimeSettingDefinition(
                id: .launchOption, title: "Launch option",
                effect: "Which of the game’s launch entries to start. Games often ship separate DirectX 11 and DirectX 12 executables as launch options.",
                alsoCalled: "Steam launch options · appinfo launch config", tier: .tier1, kind: .launchOption)
        case .highResolution:
            return RuntimeSettingDefinition(
                id: .highResolution, title: "High resolution mode",
                effect: "Uses full-resolution rendering on Retina displays for sharper text and HUDs, at a performance cost. Standard displays keep their native 1× size.",
                alsoCalled: "High Resolution Mode, Retina Mode · RetinaMode", tier: .tier2,
                kind: .choices([
                    RuntimeSettingChoice(value: "on", name: "On", shortName: "On",
                                         explanation: "Uses 2× rendering on a Retina game monitor. On a standard monitor, a 1920×1080 virtual desktop remains 1920×1080.",
                                         technicalNames: "RetinaMode=y on Retina displays; n on standard displays"),
                    RuntimeSettingChoice(value: "off", name: "Off", shortName: "Off",
                                         explanation: "Uses 1× rendering. On Retina displays, macOS scales it up: softer and faster. Standard displays stay at native size.",
                                         technicalNames: "RetinaMode=n"),
                ]))
        case .virtualDesktop:
            return RuntimeSettingDefinition(
                id: .virtualDesktop, title: "Virtual desktop",
                effect: "Runs the game inside a fixed-size Windows desktop. Rescues games that break in fullscreen or change the TV resolution. If it opens on the wrong monitor, try Make game monitor primary.",
                alsoCalled: "Emulate a virtual desktop · winecfg", tier: .tier2,
                kind: .choices([
                    RuntimeSettingChoice(value: "off", name: "Off", shortName: "Off",
                                         explanation: "The game takes over the screen as usual.",
                                         technicalNames: "Explorer\\Desktop unset"),
                    RuntimeSettingChoice(value: "1920x1080", name: "1920×1080", shortName: "1920×1080",
                                         explanation: "A fake Windows desktop of this size; the game runs inside it.",
                                         technicalNames: "Desktops\\Default=1920x1080"),
                    RuntimeSettingChoice(value: "2560x1440", name: "2560×1440", shortName: "2560×1440",
                                         explanation: "A fake Windows desktop of this size; the game runs inside it.",
                                         technicalNames: "Desktops\\Default=2560x1440"),
                    RuntimeSettingChoice(value: "3840x2160", name: "3840×2160", shortName: "3840×2160",
                                         explanation: "A fake Windows desktop of this size; the game runs inside it.",
                                         technicalNames: "Desktops\\Default=3840x2160"),
                ]))
        case .temporaryPrimaryDisplay:
            return RuntimeSettingDefinition(
                id: .temporaryPrimaryDisplay, title: "Make game monitor primary",
                effect: "Temporarily makes the game’s monitor the Mac’s main display. Can help games open on the correct monitor, including with Virtual desktop.",
                alsoCalled: "Applies to the whole Mac while playing", tier: .tier2,
                kind: .choices([
                    RuntimeSettingChoice(value: "off", name: "Off", shortName: "Off",
                                         explanation: "Keeps your Mac’s main display unchanged.", technicalNames: ""),
                    RuntimeSettingChoice(value: "on", name: "While playing", shortName: "While playing",
                                         tag: "Changes Mac display layout", tagIsWarning: true,
                                         explanation: "Other windows, the Dock and menu bar may move. Restores the display configuration when the game ends or Playden quits. Applies on the next launch.",
                                         technicalNames: ""),
                ]))
        case .steamOverlay:
            return RuntimeSettingDefinition(
                id: .steamOverlay, title: "Steam features",
                effect: "Options of the built-in Steam stand-in. Offline only in this version.",
                alsoCalled: "GBE Fork · steam_settings, configs.overlay.ini", tier: .tier2,
                kind: .choices([
                    RuntimeSettingChoice(value: "off", name: "Overlay off", shortName: "Overlay off",
                                         explanation: "No in-game overlay. Most games run best this way.",
                                         technicalNames: "enable_experimental_overlay=0"),
                    RuntimeSettingChoice(value: "on", name: "Overlay on", shortName: "Overlay on", tag: "experimental", tagIsWarning: true,
                                         explanation: "Shows the stand-in’s experimental in-game overlay. Some games misbehave with it.",
                                         technicalNames: "enable_experimental_overlay=1"),
                ]))
        case .performanceOverlay:
            return RuntimeSettingDefinition(
                id: .performanceOverlay, title: "Performance overlay",
                effect: "Shows a frames-per-second counter and GPU load in the corner while playing.",
                alsoCalled: "Metal HUD (MTL_HUD_ENABLED), DXVK HUD", tier: .tier2,
                kind: .choices([
                    RuntimeSettingChoice(value: "off", name: "Off", shortName: "Off",
                                         explanation: "No counter.", technicalNames: ""),
                    RuntimeSettingChoice(value: "on", name: "On", shortName: "On",
                                         explanation: "Metal HUD in the corner; with DXVK graphics, its own HUD as well.",
                                         technicalNames: "MTL_HUD_ENABLED=1 · DXVK_HUD=fps"),
                ]))
        case .frameLimit:
            return RuntimeSettingDefinition(
                id: .frameLimit, title: "Frame limit",
                effect: "Caps frames per second. Steadier on a 60 Hz TV and cooler laptop. DXVK only in this version.",
                alsoCalled: "DXVK_FRAME_RATE", tier: .tier2,
                kind: .choices([
                    RuntimeSettingChoice(value: "off", name: "Off", shortName: "Off",
                                         explanation: "The game runs as fast as it can.", technicalNames: ""),
                    RuntimeSettingChoice(value: "30", name: "30", shortName: "30 fps",
                                         explanation: "Capped at 30 frames per second. Only applies with DXVK graphics.",
                                         technicalNames: "DXVK_FRAME_RATE=30"),
                    RuntimeSettingChoice(value: "60", name: "60", shortName: "60 fps",
                                         explanation: "Capped at 60 frames per second. Only applies with DXVK graphics.",
                                         technicalNames: "DXVK_FRAME_RATE=60"),
                    RuntimeSettingChoice(value: "120", name: "120", shortName: "120 fps",
                                         explanation: "Capped at 120 frames per second. Only applies with DXVK graphics.",
                                         technicalNames: "DXVK_FRAME_RATE=120"),
                ]))
        case .largeAddressAware:
            return RuntimeSettingDefinition(
                id: .largeAddressAware, title: "Large address aware",
                effect: "Lets a 32-bit game use more than 2 GB of memory. Old games with big mods, or that crash after an hour, often need it.",
                alsoCalled: "WINE_LARGE_ADDRESS_AWARE", tier: .tier2,
                kind: .choices([
                    RuntimeSettingChoice(value: "off", name: "Off", shortName: "Off",
                                         explanation: "The game keeps Windows’ usual 2 GB limit for 32-bit programs.", technicalNames: ""),
                    RuntimeSettingChoice(value: "on", name: "On", shortName: "On",
                                         explanation: "The game may use up to 4 GB.",
                                         technicalNames: "WINE_LARGE_ADDRESS_AWARE=1"),
                ]))
        case .launchArguments:
            return RuntimeSettingDefinition(
                id: .launchArguments, title: "Launch arguments",
                effect: "Extra text passed to the game executable. Common ones: -windowed, -dx11, -nolauncher, -skipintro.",
                alsoCalled: "Steam launch options, cxstart arguments", tier: .advanced, kind: .text)
        case .environmentVariables:
            return RuntimeSettingDefinition(
                id: .environmentVariables, title: "Environment variables",
                effect: "Named switches read by CrossOver, Wine or the graphics layer at start. Allowlisted keys only, written KEY=VALUE.",
                alsoCalled: "cxbottle.conf [EnvironmentVariables]", tier: .advanced, kind: .text)
        case .libraryOverrides:
            return RuntimeSettingDefinition(
                id: .libraryOverrides, title: "Library overrides",
                effect: "Tells Wine to use the game’s own copy of a Windows library, or to ignore it. Fixes crashes in input, audio and shader libraries.",
                alsoCalled: "DLL overrides · winecfg Libraries, WINEDLLOVERRIDES, cxstart --dll", tier: .advanced, kind: .text)
        }
    }

    static func rows(in tier: RuntimeSettingTier) -> [RuntimeSettingDefinition] {
        all.filter { $0.tier == tier }
    }

    /// Row value text. `.choices` falls back to the Playden default when `value` is nil, and to the
    /// raw stored value when it matches no known choice. `.launchOption` resolves the stored id
    /// against the game's own launch options. `.text` never falls back to the default (all text
    /// defaults are empty anyway).
    static func valueLabel(_ id: RuntimeSettingID, value: RuntimeSettingValue?, launchOptions: [LaunchOption]) -> String {
        switch definition(id).kind {
        case .choices:
            if let match = choice(id, value: value) { return match.shortName }
            if case .scalar(let raw)? = value { return raw }
            return ""
        case .launchOption:
            guard case .scalar(let optionID)? = value else { return "Default" }
            guard let option = launchOptions.first(where: { $0.id == optionID }) else { return "Unavailable" }
            return option.title
        case .text:
            guard case .list(let values)? = value, !values.isEmpty else { return "Empty" }
            return values.joined(separator: " ")
        }
    }

    /// The choice matching `value`, or the Playden default's choice when `value` is nil.
    /// `nil` when this id isn't a `.choices` setting, or the value matches none of its choices.
    static func choice(_ id: RuntimeSettingID, value: RuntimeSettingValue?) -> RuntimeSettingChoice? {
        guard case .choices(let choices) = definition(id).kind else { return nil }
        guard case .scalar(let raw)? = value ?? RuntimeResolver.defaultValues[id] else { return nil }
        return choices.first { $0.value == raw }
    }

    static let isDefaultValue: @Sendable (RuntimeSettingID, String) -> Bool = { id, raw in
        guard case .scalar(let value)? = RuntimeResolver.defaultValues[id] else { return false }
        return value == raw
    }
}
