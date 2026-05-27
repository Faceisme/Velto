import Cocoa

/// 切换器需要监听的"逻辑事件" —— 物理键被翻译成这些。Controller 只看这层。
enum SwitcherKeyEvent {
    /// Cmd+Tab(或 Shift+Cmd+Tab):呼出 / 循环下一个(或上一个)
    case trigger(reverse: Bool)
    /// Cmd 整体松开:确认切换
    case releaseModifier
    /// 方向键 / Tab:循环选择(在切换器已显示时使用)
    case step(reverse: Bool)
    /// Esc:取消
    case cancel
}

/// 接管系统的 Cmd+Tab,把按键事件路由给 Controller。
///
/// 工作流:
///   1. 启动时 `setNativeCommandTabEnabled(false)` —— 关闭 macOS 自带 Cmd+Tab
///   2. 装 CGEvent tap 监听 keyDown / flagsChanged
///   3. 检测到 Cmd+Tab → 吃掉事件 + 通知 Controller
///   4. Controller 决定要不要弹 panel / 循环 / 切换 / 取消
///   5. 退出时务必 `setNativeCommandTabEnabled(true)` 恢复 —— 系统 hotkey 状态
///      是**持久的**,我们 crash 了下次开机系统 Cmd+Tab 都还是关着!
///
/// `@unchecked Sendable`:tap 回调在 tap 线程,onEvent 闭包要小心 actor 边界 ——
/// Controller 自己负责回到 main。
final class SwitcherKeyTap: @unchecked Sendable {
    /// 事件回调。**在 tap 线程上调用**,Controller 负责跳回 main。
    var onEvent: ((SwitcherKeyEvent) -> Void)?

    /// 用来告诉 tap:切换器现在是不是显示中,影响事件吞吐策略
    /// (没显示时只吞 Cmd+Tab;显示时吃方向键 / Esc / Cmd 释放)。
    private let isActiveLock = NSLock()
    private var _isActive = false
    var isActive: Bool {
        get { isActiveLock.lock(); defer { isActiveLock.unlock() }; return _isActive }
        set { isActiveLock.lock(); _isActive = newValue; isActiveLock.unlock() }
    }

    /// 切换器总开关 —— UI 上"启用窗口切换器"的实时反映。
    /// 关闭时 tap 不消费 Cmd+Tab(透传给系统原生切换器),且同时调用
    /// setNativeCommandTabEnabled(true) 让系统切换器活过来。
    private let switcherEnabledLock = NSLock()
    private var _switcherEnabled = true
    var switcherEnabled: Bool {
        get { switcherEnabledLock.lock(); defer { switcherEnabledLock.unlock() }; return _switcherEnabled }
    }

    /// Controller / UI 调这里。线程安全。
    func setSwitcherEnabled(_ enabled: Bool) {
        switcherEnabledLock.lock()
        let wasEnabled = _switcherEnabled
        _switcherEnabled = enabled
        switcherEnabledLock.unlock()
        guard wasEnabled != enabled else { return }
        // 系统 hotkey 的 enable 状态在 OS 重启之前持久 —— 切回 true / false
        // 是即时生效的,不需要重启 app 或 tap。
        setNativeCommandTabEnabled(!enabled)
    }

    /// 用户配置的触发快捷键 —— Cmd+Tab 是默认,但可被设置页改成任何组合。
    /// `modifierMask` 之外的位被忽略(避免脏 flags 干扰匹配)。
    private static let modifierMask: UInt64 = UInt64(
        CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskCommand.rawValue |
        CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskControl.rawValue |
        CGEventFlags.maskSecondaryFn.rawValue
    )

    private let triggerLock = NSLock()
    private var _triggerKeyCode: UInt16 = 48
    private var _triggerModifierFlags: UInt64 = UInt64(CGEventFlags.maskCommand.rawValue)

    private var triggerSnapshot: (keyCode: UInt16, modifierFlags: UInt64) {
        triggerLock.lock()
        defer { triggerLock.unlock() }
        return (_triggerKeyCode, _triggerModifierFlags)
    }

    /// 推送新的触发快捷键给 tap。nil 时回退到 Cmd+Tab 默认。线程安全。
    /// Controller 在偏好变化时调,实时生效不需要重启。
    func setTriggerShortcut(_ shortcut: Shortcut?) {
        triggerLock.lock()
        if let shortcut, shortcut.keyCode != 0 {
            _triggerKeyCode = shortcut.keyCode
            _triggerModifierFlags = shortcut.modifierFlags & Self.modifierMask
        } else {
            _triggerKeyCode = 48
            _triggerModifierFlags = UInt64(CGEventFlags.maskCommand.rawValue)
        }
        triggerLock.unlock()
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var didDisableSystemHotkey = false

    /// 启动 —— 接管 Cmd+Tab 并装 tap。失败返回 false(权限缺失 / tap 创建失败)。
    func start() -> Bool {
        guard tap == nil else { return true }

        // 关掉系统 Cmd+Tab / Shift+Cmd+Tab / Cmd+`
        setNativeCommandTabEnabled(false)
        didDisableSystemHotkey = true

        // CGEvent tap:监听 keyDown 和 flagsChanged
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: refcon
        ) else {
            // 权限不够会失败;调用方接住后能引导用户去开权限
            setNativeCommandTabEnabled(true)
            didDisableSystemHotkey = false
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        return true
    }

    /// 停止 —— 恢复系统 Cmd+Tab,卸 tap。**必须** 在 app 退出时调用。
    func stop() {
        if let tap, let runLoopSource {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil

        if didDisableSystemHotkey {
            setNativeCommandTabEnabled(true)
            didDisableSystemHotkey = false
        }
    }

    deinit { stop() }

    // MARK: - Tap 回调

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let s = Unmanaged<SwitcherKeyTap>.fromOpaque(refcon).takeUnretainedValue()
        return s.handle(type: type, event: event)
    }

    /// 返回 nil → 吃掉事件;返回 event → 继续派发。
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统偶尔会"禁用"我们的 tap(超时 / 用户切快速用户切换 / 系统进睡眠)。
        // 这两个 case 收到时静默重新启用 tap,避免 Cmd+Tab 突然失灵。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let eventModifiers = UInt64(flags.rawValue) & Self.modifierMask
        let shift = flags.contains(.maskShift)
        let trigger = triggerSnapshot

        switch type {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // 匹配规则:keyCode 必须等于配置的 keyCode,且**配置里的所有 modifier
            // 都在 event 里被按下**(允许 event 多按 Shift,我们用 Shift 表示反向)。
            //
            // 例:用户配 ⌘+Tab(modifierFlags=Cmd)。⌘+Tab 命中(reverse=false),
            //    ⌘+⇧+Tab 也命中(reverse=true),光 Tab 不命中。
            // 若配 ⌥+`,⌥+` 命中(reverse=false),⌥+⇧+` 也命中(reverse=true)。
            //
            // 反向永远由 Shift 表示 —— 除非用户的快捷键里本身就包含 Shift,
            // 那种情况就没有"反向"了(无伤大雅)。
            let shiftMask = UInt64(CGEventFlags.maskShift.rawValue)
            let triggerHasShift = (trigger.modifierFlags & shiftMask) != 0
            let nonShiftMatch =
                keyCode == trigger.keyCode &&
                (eventModifiers & ~shiftMask) == (trigger.modifierFlags & ~shiftMask)
            if nonShiftMatch {
                let reverse = !triggerHasShift && shift
                guard switcherEnabled else {
                    return Unmanaged.passUnretained(event)
                }
                onEvent?(.trigger(reverse: reverse))
                return nil
            }
            // 切换器已活跃时,这些键也吃掉
            if isActive {
                switch keyCode {
                case 53:   // Esc
                    onEvent?(.cancel)
                    return nil
                case 124, 49:  // Right Arrow, Space
                    onEvent?(.step(reverse: false))
                    return nil
                case 123:  // Left Arrow
                    onEvent?(.step(reverse: true))
                    return nil
                case 125:  // Down Arrow
                    onEvent?(.step(reverse: false))
                    return nil
                case 126:  // Up Arrow
                    onEvent?(.step(reverse: true))
                    return nil
                default:
                    // 其他按键透传 —— P3 可以加搜索
                    return Unmanaged.passUnretained(event)
                }
            }

        case .flagsChanged:
            // 触发快捷键的**任一** modifier 松开 → 确认切换。
            // 不局限于 Cmd —— 用户配 ⌥+` 时就是 ⌥ 松开触发。
            if isActive && (eventModifiers & trigger.modifierFlags) != trigger.modifierFlags {
                onEvent?(.releaseModifier)
                return Unmanaged.passUnretained(event)
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
