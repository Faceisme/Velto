import AppKit
import Foundation

/// Per-application behavior tweaks needed because some apps don't play nicely
/// with synthetic keyboard shortcuts (WeChat is the main offender today).
///
/// Keep this isolated from GestureTargetController so the targeting code stays
/// generic and new "weird" apps can be added without touching core logic.
enum AppQuirks {
    private static let weChatMainBundleIdentifiers: Set<String> = [
        "com.tencent.xinWeChat",
        "com.tencent.WeChat",
        "com.tencent.wechat"
    ]

    /// Policy applied to a target app right before we deliver its shortcut.
    struct DeliveryPolicy {
        /// Extra delay (seconds) inserted between focusing the target and posting the key event.
        /// Lets the target app finish window activation animations before receiving input.
        var deliveryDelay: TimeInterval
        /// When the matched shortcut is ⌘W, press the AX close button directly
        /// instead of synthesizing the keystroke. Required for WeChat-family apps
        /// where ⌘W gets eaten by the window animation.
        var prefersDirectWindowClose: Bool

        static let standard = DeliveryPolicy(deliveryDelay: 0.08, prefersDirectWindowClose: false)
        static let weChatLike = DeliveryPolicy(deliveryDelay: 0.12, prefersDirectWindowClose: true)
    }

    /// Resolve the policy for the running application that owns the target window.
    /// `rawApp` is the process that actually owns the AXUIElement under the pointer,
    /// `foregroundApp` is what we end up activating (may differ for multi-process apps
    /// like WeChat where helper processes own popup windows).
    static func policy(
        rawApp: NSRunningApplication?,
        foregroundApp: NSRunningApplication?,
        ownerName: String? = nil
    ) -> DeliveryPolicy {
        if isWeChat(rawApp) || isWeChat(foregroundApp) || isWeChatText(ownerName ?? "") {
            return .weChatLike
        }
        return .standard
    }

    /// If `rawApp` is a WeChat helper process (e.g. media preview, mini-program runtime),
    /// returns the main WeChat app so we activate it instead. Otherwise returns `rawApp`
    /// unchanged.
    static func foregroundApplication(for rawApp: NSRunningApplication?) -> NSRunningApplication? {
        guard let rawApp,
              let bundleIdentifier = rawApp.bundleIdentifier else {
            return rawApp
        }

        if isWeChatBundleIdentifier(bundleIdentifier),
           !weChatMainBundleIdentifiers.contains(bundleIdentifier),
           let main = NSWorkspace.shared.runningApplications.first(where: { app in
               app.bundleIdentifier.map(weChatMainBundleIdentifiers.contains) ?? false
           }) {
            return main
        }

        return rawApp
    }

    // MARK: - WeChat detection

    private static func isWeChat(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }

        if let bundleIdentifier = application.bundleIdentifier,
           isWeChatBundleIdentifier(bundleIdentifier) {
            return true
        }

        return isWeChatText(application.localizedName ?? "")
    }

    static func isWeChatBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier.localizedCaseInsensitiveContains("wechat")
            || bundleIdentifier.localizedCaseInsensitiveContains("xinwechat")
    }

    private static func isWeChatText(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("微信")
            || text.localizedCaseInsensitiveContains("wechat")
    }
}
