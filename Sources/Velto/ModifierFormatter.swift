import AppKit
import CoreGraphics
import Foundation

/// Normalizes and pretty-prints modifier-key flag sets.
/// Shared between the runtime event tap (`EventTapManager`) and the SwiftUI
/// modifier recorder (`ModifierRecorderField`).
enum ModifierFormatter {
    private static let relevantFlags: CGEventFlags = [
        .maskControl,
        .maskAlternate,
        .maskShift,
        .maskCommand,
        .maskSecondaryFn
    ]

    static func normalizedRawValue(from flags: CGEventFlags) -> UInt64 {
        UInt64(flags.intersection(relevantFlags).rawValue)
    }

    static func normalizedRawValue(from flags: NSEvent.ModifierFlags) -> UInt64 {
        normalizedRawValue(from: ShortcutFormatter.cgFlags(from: flags))
    }

    static func displayName(rawValue: UInt64) -> String {
        guard rawValue != 0 else {
            return "未设置"
        }

        let flags = CGEventFlags(rawValue: CGEventFlags.RawValue(rawValue))
        var parts: [String] = []

        if flags.contains(.maskControl)    { parts.append("⌃") }
        if flags.contains(.maskAlternate)  { parts.append("⌥") }
        if flags.contains(.maskShift)      { parts.append("⇧") }
        if flags.contains(.maskCommand)    { parts.append("⌘") }
        if flags.contains(.maskSecondaryFn){ parts.append("Fn") }

        return parts.joined()
    }
}
