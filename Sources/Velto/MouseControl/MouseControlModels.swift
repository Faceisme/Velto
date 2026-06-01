import AppKit
import CoreGraphics
import Foundation

enum MouseInputKind: String, Codable, Equatable {
    case keyboard
    case mouse
    case custom
}

struct MouseInputTrigger: Codable, Equatable, Hashable {
    var kind: MouseInputKind
    var code: UInt16
    var modifierFlags: UInt64
    var displayName: String

    init(
        kind: MouseInputKind,
        code: UInt16,
        modifierFlags: UInt64 = 0,
        displayName: String
    ) {
        self.kind = kind
        self.code = code
        self.modifierFlags = modifierFlags
        self.displayName = displayName
    }

    static let optionKey = MouseInputTrigger(
        kind: .keyboard,
        code: MouseKeyCodes.leftOption,
        displayName: "⌥"
    )

    static let shiftKey = MouseInputTrigger(
        kind: .keyboard,
        code: MouseKeyCodes.leftShift,
        displayName: "⇧"
    )

    static let commandKey = MouseInputTrigger(
        kind: .keyboard,
        code: MouseKeyCodes.leftCommand,
        displayName: "⌘"
    )

    var displayComponents: [String] {
        displayName
            .split(separator: " ")
            .map(String.init)
    }
}

enum MouseKeyCodes {
    static let leftShift: UInt16 = 56
    static let rightShift: UInt16 = 60
    static let leftControl: UInt16 = 59
    static let rightControl: UInt16 = 62
    static let leftOption: UInt16 = 58
    static let rightOption: UInt16 = 61
    static let leftCommand: UInt16 = 55
    static let rightCommand: UInt16 = 54
    static let function: UInt16 = 63

    static let modifierKeyToFlag: [UInt16: CGEventFlags] = [
        leftShift: .maskShift,
        rightShift: .maskShift,
        leftControl: .maskControl,
        rightControl: .maskControl,
        leftOption: .maskAlternate,
        rightOption: .maskAlternate,
        leftCommand: .maskCommand,
        rightCommand: .maskCommand,
        function: .maskSecondaryFn
    ]
}

struct MouseScrollProfile: Codable, Equatable {
    var smooth: Bool
    var smoothVertical: Bool
    var smoothHorizontal: Bool
    var reverse: Bool
    var reverseVertical: Bool
    var reverseHorizontal: Bool
    var minStep: Double
    var speedGain: Double
    var duration: Double
    var simulateTrackpad: Bool

    static let defaults = MouseScrollProfile(
        smooth: true,
        smoothVertical: true,
        smoothHorizontal: true,
        reverse: false,
        reverseVertical: true,
        reverseHorizontal: true,
        minStep: 33.6,
        speedGain: 2.7,
        duration: 4.35,
        simulateTrackpad: false
    )

    var transitionFactor: Double {
        let clamped = min(max(duration, 0.5), 5.0)
        let upperLimit = 5.2
        let value = 1.0 - sqrt(clamped / upperLimit)
        return min(max(value, 0.02), 0.45)
    }
}

struct MouseScrollHotkeys: Codable, Equatable {
    var acceleration: MouseInputTrigger?
    var directionToggle: MouseInputTrigger?
    var disableSmooth: MouseInputTrigger?

    static let defaults = MouseScrollHotkeys(
        acceleration: .optionKey,
        directionToggle: .shiftKey,
        disableSmooth: .commandKey
    )
}

enum MouseSystemAction: String, Codable, CaseIterable, Identifiable {
    case missionControl
    case applicationWindows
    case showDesktop
    case screenshot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .missionControl: "调度中心"
        case .applicationWindows: "应用窗口"
        case .showDesktop: "显示桌面"
        case .screenshot: "截图"
        }
    }

    var shortcut: Shortcut {
        switch self {
        case .missionControl:
            Shortcut(
                keyCode: 126,
                modifierFlags: CGEventFlags.maskControl.storedRawValue,
                displayName: "⌃↑"
            )
        case .applicationWindows:
            Shortcut(
                keyCode: 125,
                modifierFlags: CGEventFlags.maskControl.storedRawValue,
                displayName: "⌃↓"
            )
        case .showDesktop:
            Shortcut(keyCode: 103, modifierFlags: 0, displayName: "F11")
        case .screenshot:
            Shortcut(
                keyCode: 21,
                modifierFlags: (
                    CGEventFlags.maskCommand.rawValue
                        | CGEventFlags.maskShift.rawValue
                ),
                displayName: "⇧⌘4"
            )
        }
    }
}

enum MouseButtonAction: Codable, Equatable {
    case system(MouseSystemAction)
    case shortcut(Shortcut)
    case openApplication(path: String, bundleIdentifier: String?)
    case openFile(path: String)
    case runScript(String)

    var label: String {
        switch self {
        case .system(let action):
            return action.label
        case .shortcut(let shortcut):
            return shortcut.displayName
        case .openApplication(let path, _):
            return "打开 \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)"
        case .openFile(let path):
            return "打开 \(URL(fileURLWithPath: path).lastPathComponent)"
        case .runScript:
            return "运行脚本"
        }
    }
}

struct MouseButtonBinding: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var trigger: MouseInputTrigger
    var action: MouseButtonAction

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        trigger: MouseInputTrigger,
        action: MouseButtonAction
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.action = action
    }
}

struct MouseAppRule: Codable, Identifiable, Equatable {
    var id: UUID
    var bundleIdentifier: String
    var displayName: String
    var path: String
    var inheritScroll: Bool
    var inheritHotkeys: Bool
    var inheritButtons: Bool
    var scroll: MouseScrollProfile
    var hotkeys: MouseScrollHotkeys
    var buttonBindings: [MouseButtonBinding]

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        displayName: String,
        path: String,
        inheritScroll: Bool = true,
        inheritHotkeys: Bool = true,
        inheritButtons: Bool = true,
        scroll: MouseScrollProfile = .defaults,
        hotkeys: MouseScrollHotkeys = .defaults,
        buttonBindings: [MouseButtonBinding] = []
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.path = path
        self.inheritScroll = inheritScroll
        self.inheritHotkeys = inheritHotkeys
        self.inheritButtons = inheritButtons
        self.scroll = scroll
        self.hotkeys = hotkeys
        self.buttonBindings = buttonBindings
    }
}

struct MouseControlPreferences: Codable, Equatable {
    var enabled: Bool
    var debugLoggingEnabled: Bool
    var scroll: MouseScrollProfile
    var hotkeys: MouseScrollHotkeys
    var appRules: [MouseAppRule]
    var buttonBindings: [MouseButtonBinding]

    init(
        enabled: Bool,
        debugLoggingEnabled: Bool,
        scroll: MouseScrollProfile,
        hotkeys: MouseScrollHotkeys,
        appRules: [MouseAppRule],
        buttonBindings: [MouseButtonBinding]
    ) {
        self.enabled = enabled
        self.debugLoggingEnabled = debugLoggingEnabled
        self.scroll = scroll
        self.hotkeys = hotkeys
        self.appRules = appRules
        self.buttonBindings = buttonBindings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.defaults.enabled
        debugLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .debugLoggingEnabled) ?? Self.defaults.debugLoggingEnabled
        scroll = try container.decodeIfPresent(MouseScrollProfile.self, forKey: .scroll) ?? Self.defaults.scroll
        hotkeys = try container.decodeIfPresent(MouseScrollHotkeys.self, forKey: .hotkeys) ?? Self.defaults.hotkeys
        appRules = try container.decodeIfPresent([MouseAppRule].self, forKey: .appRules) ?? Self.defaults.appRules
        buttonBindings = try container.decodeIfPresent([MouseButtonBinding].self, forKey: .buttonBindings) ?? Self.defaults.buttonBindings
    }

    static let defaults = MouseControlPreferences(
        enabled: true,
        debugLoggingEnabled: false,
        scroll: .defaults,
        hotkeys: .defaults,
        appRules: [],
        buttonBindings: []
    )
}
