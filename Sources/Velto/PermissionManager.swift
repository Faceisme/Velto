import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum PermissionManager {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 屏幕录制权限 —— 切换器抓窗口缩略图必需。
    /// 注意:`CGPreflightScreenCaptureAccess()` 在 macOS 11+ 才有,Tahoe 上稳定。
    /// 它**只查**不弹窗,弹窗用 `CGRequestScreenCaptureAccess()`(下面那个)。
    static var isScreenRecordingTrusted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统级 Screen Recording 授权弹窗。第一次调会弹,后续调返回当前状态。
    /// 用户授权后**必须重启 app** 才生效 —— 这是 macOS 的固有限制,没法绕过。
    @discardableResult
    static func requestScreenRecordingPrompt() -> Bool {
        CGRequestScreenCaptureAccess()
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

    /// 打开「系统设置 → 键盘」,引导用户确认/设置「选择上一个输入法」快捷键。
    static func openKeyboardSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard"
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            NSWorkspace.shared.open(url)
            break
        }
    }
}
