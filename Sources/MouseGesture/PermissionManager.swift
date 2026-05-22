import AppKit
import ApplicationServices
import Foundation

enum PermissionManager {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPrompt() {
        guard !isAccessibilityTrusted else {
            return
        }

        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else {
                continue
            }
            NSWorkspace.shared.open(url)
            break
        }
    }
}
