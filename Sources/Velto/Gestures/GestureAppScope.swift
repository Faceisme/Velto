import AppKit
import CoreGraphics

/// 全局手势与按 App 手势怎么叠加。运行时匹配和设置页展示共用这一份规则,
/// 两边对「哪个手势在这个 App 里生效」的判断不会对不上。
///
/// 规则:App 的手势总是参与;开了「同时使用全局手势」时全局手势也参与,但和某个
/// App 手势同形状(签名差异度 < `sameShapeThreshold`)的全局手势让位 —— 否则两个
/// 同形状的候选会被识别器的余量判据判成模糊,谁都触发不了。
enum GestureAppScope {
    /// 两条规范签名差异度低于此值即视为同一形状:同一套里算冲突,跨套则 App 的覆盖全局的。
    static let sameShapeThreshold: CGFloat = 0.05

    /// 全局手势 id → 覆盖它的 App 手势 id。没录样本的手势不参与覆盖。
    static func overrides(
        appGestures: [GestureCommand],
        globalGestures: [GestureCommand],
        signature: (GestureCommand) -> GestureDirection.Signature
    ) -> [UUID: UUID] {
        let appSignatures = appGestures
            .map { ($0.id, signature($0)) }
            .filter { !$0.1.isEmpty }
        guard !appSignatures.isEmpty else { return [:] }
        var result: [UUID: UUID] = [:]
        for global in globalGestures {
            let globalSignature = signature(global)
            guard !globalSignature.isEmpty else { continue }
            if let hit = appSignatures.first(where: {
                GestureDirection.distance($0.1, globalSignature) < sameShapeThreshold
            }) {
                result[global.id] = hit.0
            }
        }
        return result
    }

    /// 在某个 App 里实际参与匹配的手势。`profile` 为 nil(这个 App 没有专属手势)时就是全局手势。
    static func effectiveGestures(
        global: [GestureCommand],
        profile: GestureAppProfile?,
        signature: (GestureCommand) -> GestureDirection.Signature
    ) -> [GestureCommand] {
        guard let profile else { return global }
        guard profile.includesGlobalGestures else { return profile.gestures }
        let overridden = overrides(appGestures: profile.gestures, globalGestures: global, signature: signature)
        return profile.gestures + global.filter { overridden[$0.id] == nil }
    }

    /// 手势目标所在 App 的 bundle id。主线程调用(查窗口归属、前台 App)。
    /// - activeWindow:手势起手时的前台 App。
    /// - windowUnderPointer:起手时光标下那个窗口的归属进程;事件没带窗口号就退到事件
    ///   的目标进程,再退到前台 App。
    @MainActor
    static func targetBundleIdentifier(
        policy: GestureTargetPolicy,
        windowNumber: Int64,
        targetPID: pid_t,
        frontmostApplication: NSRunningApplication?
    ) -> String? {
        if policy == .windowUnderPointer {
            if windowNumber > 0, let pid = ownerPID(ofWindow: CGWindowID(windowNumber)),
               let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                return bundleID
            }
            if targetPID > 1, let bundleID = NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier {
                return bundleID
            }
        }
        return (frontmostApplication ?? NSWorkspace.shared.frontmostApplication)?.bundleIdentifier
    }

    private static func ownerPID(ofWindow windowID: CGWindowID) -> pid_t? {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
        return info?.first?[kCGWindowOwnerPID as String] as? pid_t
    }
}
