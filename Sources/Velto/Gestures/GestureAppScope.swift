import AppKit
import CoreGraphics

/// 全局手势与按 App 手势怎么叠加。运行时匹配和设置页展示共用这一份规则,
/// 两边对「哪个手势在这个 App 里生效」的判断不会对不上。
///
/// 规则:App 的手势总是参与;开了「同时使用全局手势」时全局手势也参与,但和某个
/// App 手势同形状(签名差异度 < `sameShapeThreshold`)或同鼠标按钮的全局手势让位 ——
/// 否则两个同形状的候选会被识别器的余量判据判成模糊,谁都触发不了;同按钮则只能
/// 二选一。
enum GestureAppScope {
    /// 两条规范签名差异度低于此值即视为同一形状:同一套里算冲突,跨套则 App 的覆盖全局的。
    static let sameShapeThreshold: CGFloat = 0.05

    /// 全局手势 id → 覆盖它的 App 手势 id。同形状(两边都录了样本)或同鼠标按钮即覆盖。
    static func overrides(
        appGestures: [GestureCommand],
        globalGestures: [GestureCommand],
        signature: (GestureCommand) -> GestureDirection.Signature
    ) -> [UUID: UUID] {
        guard !appGestures.isEmpty else { return [:] }
        let appSignatures = appGestures.map { ($0.id, signature($0)) }.filter { !$0.1.isEmpty }
        let appButtons = appGestures.compactMap { g in g.buttonTrigger.map { ($0, g.id) } }
        var result: [UUID: UUID] = [:]
        for global in globalGestures {
            if let trigger = global.buttonTrigger, let hit = appButtons.first(where: { $0.0 == trigger }) {
                result[global.id] = hit.1
                continue
            }
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

    /// 手势目标所在 App 的 bundle id。主线程(画手势松手后匹配)和 tap 线程(鼠标按钮
    /// 触发)都会调,只用到线程安全的窗口列表查询与 `NSRunningApplication`。
    /// - activeWindow:手势起手时的前台 App。
    /// - windowUnderPointer:起手时光标下那个窗口的归属进程;事件没带窗口号就退到事件
    ///   的目标进程,再退到前台 App。
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

/// 鼠标按钮 → 手势的查找表,按「全局」和每个配了专属手势的 App 各备一份生效表
/// (已按 `GestureAppScope` 的覆盖规则叠好)。在主线程随手势保存构建好再交给 tap 线程:
/// 覆盖判定要算轨迹签名,不能放在按下按钮的热路径上。只收有快捷键的手势 —— 没快捷键
/// 的按钮放行给 App,不白吞一次点击。
struct GestureButtonMap: Sendable {
    private var global: [GestureButtonTrigger: GestureCommand] = [:]
    private var apps: [String: [GestureButtonTrigger: GestureCommand]] = [:]
    /// 所有作用范围里出现过的按钮触发。按下的按钮不在其中就直接放行,免去查 App 归属。
    private(set) var triggers: Set<GestureButtonTrigger> = []

    static let empty = GestureButtonMap()

    init() {}

    init(
        global: [GestureCommand],
        appProfiles: [GestureAppProfile],
        signature: (GestureCommand) -> GestureDirection.Signature
    ) {
        func table(_ commands: [GestureCommand]) -> [GestureButtonTrigger: GestureCommand] {
            var result: [GestureButtonTrigger: GestureCommand] = [:]
            for command in commands where command.shortcut != nil {
                guard let trigger = command.buttonTrigger, result[trigger] == nil else { continue }
                result[trigger] = command
            }
            return result
        }
        self.global = table(global)
        for profile in appProfiles {
            let effective = GestureAppScope.effectiveGestures(global: global, profile: profile, signature: signature)
            // 专属手势排在前面,同按钮时取专属的。
            apps[profile.bundleIdentifier] = table(effective)
        }
        triggers = Set(self.global.keys).union(apps.values.flatMap(\.keys))
    }

    /// `bundleID` 所在 App 里这个按钮对应的手势;这个 App 没配专属手势就查全局表。
    func command(for trigger: GestureButtonTrigger, bundleID: String?) -> GestureCommand? {
        if let bundleID, let appTable = apps[bundleID] {
            return appTable[trigger]
        }
        return global[trigger]
    }
}
