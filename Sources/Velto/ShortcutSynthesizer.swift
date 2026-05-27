import AppKit
import CoreGraphics
import Foundation

enum ShortcutSynthesizer {
    static let syntheticEventMarker: Int64 = 0x4D47534B4559

    static func send(_ shortcut: Shortcut) {
        sendKey(keyCode: shortcut.keyCode, modifierFlags: shortcut.modifierFlags)
    }

    static func sendKey(keyCode: UInt16, modifierFlags: UInt64 = 0) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return
        }

        let key = CGKeyCode(keyCode)
        let flags = CGEventFlags(rawValue: CGEventFlags.RawValue(modifierFlags))

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        keyDown?.flags = flags
        keyDown?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        keyUp?.flags = flags
        keyUp?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    static func sendEscape() {
        sendKey(keyCode: VirtualKeyCode.escape)
    }
}

enum ShortcutFormatter {
    static func shortcut(from event: NSEvent) -> Shortcut? {
        guard !isModifierOnly(event) else {
            return nil
        }

        let flags = cgFlags(from: event.modifierFlags)
        let keyName = keyName(for: event)
        let display = displayName(flags: event.modifierFlags, keyName: keyName)

        return Shortcut(
            keyCode: event.keyCode,
            modifierFlags: UInt64(flags.rawValue),
            displayName: display
        )
    }

    static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result = CGEventFlags()

        if flags.contains(.command) {
            result.insert(.maskCommand)
        }
        if flags.contains(.option) {
            result.insert(.maskAlternate)
        }
        if flags.contains(.control) {
            result.insert(.maskControl)
        }
        if flags.contains(.shift) {
            result.insert(.maskShift)
        }
        if flags.contains(.function) {
            result.insert(.maskSecondaryFn)
        }

        return result
    }

    static func displayName(flags: NSEvent.ModifierFlags, keyName: String) -> String {
        var parts: [String] = []

        if flags.contains(.control) {
            parts.append("⌃")
        }
        if flags.contains(.option) {
            parts.append("⌥")
        }
        if flags.contains(.shift) {
            parts.append("⇧")
        }
        if flags.contains(.command) {
            parts.append("⌘")
        }
        if flags.contains(.function) {
            parts.append("Fn")
        }

        parts.append(keyName)
        return parts.joined()
    }

    static func keyName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36:
            return "回车"
        case 48:
            return "Tab"
        case 49:
            return "空格"
        case 51:
            return "删除"
        case 53:
            return "Esc"
        case 18:
            return "1"
        case 19:
            return "2"
        case 20:
            return "3"
        case 21:
            return "4"
        case 23:
            return "5"
        case 22:
            return "6"
        case 26:
            return "7"
        case 28:
            return "8"
        case 25:
            return "9"
        case 29:
            return "0"
        case 24:
            return "="
        case 27:
            return "-"
        case 30:
            return "]"
        case 33:
            return "["
        case 39:
            return "'"
        case 41:
            return ";"
        case 42:
            return "\\"
        case 43:
            return ","
        case 44:
            return "/"
        case 47:
            return "."
        case 50:
            return "`"
        case 115:
            return "Home"
        case 116:
            return "PageUp"
        case 117:
            return "向前删除"
        case 119:
            return "End"
        case 121:
            return "PageDown"
        case 123:
            return "←"
        case 124:
            return "→"
        case 125:
            return "↓"
        case 126:
            return "↑"
        default:
            let fallback = "#\(event.keyCode)"
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
                return fallback
            }
            return characters.uppercased()
        }
    }

    private static func isModifierOnly(_ event: NSEvent) -> Bool {
        event.type == .flagsChanged
    }
}
