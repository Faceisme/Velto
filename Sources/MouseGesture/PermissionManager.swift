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

        // `kAXTrustedCheckOptionPrompt` 在 SDK 里是 const CFStringRef 全局变量,
        // Swift 6 严格并发把它判定为非 Sendable 全局可变状态。它的值是公开
        // documented 的字符串字面量 "AXTrustedCheckOptionPrompt",直接 hardcode
        // 比 nonisolated(unsafe) wrapper 更稳。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
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
