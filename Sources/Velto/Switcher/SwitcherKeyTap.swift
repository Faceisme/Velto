import Cocoa
@preconcurrency import CoreFoundation

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
/// Tap 跑在独立的 userInteractive 线程,而非 main runloop —— 主线程被 SwiftUI
/// 设置页 / 文件 IO 之类卡住时,Cmd+Tab 仍可即时响应。这跟 EventTapManager 同款
/// 设计,代价是 callback 跨线程,所有共享字段都走 NSLock 保护。
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
        applySystemHotkeyState()
    }

    /// 系统符号热键状态 = (启用?, 触发键)。**先把三个热键全部恢复**(治崩溃残留 +
    /// 换触发键时把上次占用的放回去),**再**仅在启用时关掉"当前触发键实际占用"的那几个。
    /// 系统 hotkey 的 enable 状态持久到下次开机,切 true/false 即时生效,无需重启 tap。
    private func applySystemHotkeyState() {
        setNativeCommandTabEnabled(true)   // 全部恢复
        let trigger = triggerSnapshot
        let occupied = switcherEnabled
            ? Self.occupiedSystemHotkeys(keyCode: trigger.keyCode, modifierFlags: trigger.modifierFlags)
            : []
        if !occupied.isEmpty {
            setNativeCommandTabEnabled(false, occupied)
        }
        didDisableSystemHotkey = !occupied.isEmpty
    }

    /// 触发键实际占用哪些系统符号热键 —— 只有真正冲突时才关对应系统 hotkey,
    /// 否则"自定义触发键 + 保留系统 Cmd+Tab"无法成立(P1a)。
    ///   - ⌘+Tab → commandTab + commandShiftTab(反向用 ⇧)
    ///   - ⌘+`(键码 50)→ commandKeyAboveTab
    ///   - 其它 → 不占用任何系统热键
    private static func occupiedSystemHotkeys(keyCode: UInt16, modifierFlags: UInt64) -> [CGSSymbolicHotKey] {
        let shiftMask = UInt64(CGEventFlags.maskShift.rawValue)
        let nonShift = (modifierFlags & modifierMask) & ~shiftMask
        guard nonShift == UInt64(CGEventFlags.maskCommand.rawValue) else { return [] }
        switch keyCode {
        case 48: return [.commandTab, .commandShiftTab]   // Tab
        case 50: return [.commandKeyAboveTab]             // `(grave)
        default: return []
        }
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
        // 兜底校验:必须有 keyCode 且含真 modifier;裸键 / 仅 Shift / nil 一律回退默认
        // ⌘+Tab —— 绝不把会全局吞普通输入的裸键推给 tap。
        if let shortcut, shortcut.keyCode != 0, shortcut.hasRealModifier {
            _triggerKeyCode = shortcut.keyCode
            _triggerModifierFlags = shortcut.modifierFlags & Self.modifierMask
        } else {
            _triggerKeyCode = 48
            _triggerModifierFlags = UInt64(CGEventFlags.maskCommand.rawValue)
        }
        triggerLock.unlock()
        // 触发键变了,系统热键占用要重算(可能从占用 Cmd+Tab 变成不占用,或反过来)。
        applySystemHotkeyState()
    }

    /// Tap / runloop source / tap 线程的生命周期都由 start/stop 管,这三个字段
    /// 只在主线程读写(start、stop 都只从主线程调),不需要锁。
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    /// tap 线程的 runloop。线程启动时写一次,主线程 stop 时读一次,用
    /// `ready.wait()` 同步;声明周期内不可变,不需要锁。
    private var tapRunLoop: CFRunLoop?
    private var didDisableSystemHotkey = false

    /// 启动 —— 接管 Cmd+Tab 并装 tap。失败返回 false(权限缺失 / tap 创建失败)。
    func start() -> Bool {
        guard tap == nil else { return true }

        // 启动自愈 + 按需关闭:先把系统热键全部恢复(治上次崩溃/被 kill 留下的残留),
        // 再只关当前触发键实际占用的那几个。不再无条件关掉全部三个。
        applySystemHotkeyState()

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

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            setNativeCommandTabEnabled(true)
            didDisableSystemHotkey = false
            return false
        }

        self.tap = tap
        self.runLoopSource = source

        // 起独立的高优先级线程跑 tap runloop。这样主线程被 SwiftUI 卡住时
        // Cmd+Tab 仍能即时响应。
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let runLoop = CFRunLoopGetCurrent() else {
                ready.signal()
                return
            }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            self?.tapRunLoop = runLoop
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        thread.name = "com.face.velto.switcher.keytap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        ready.wait()

        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// 停止 —— 恢复系统 Cmd+Tab,卸 tap。**必须** 在 app 退出时调用。
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let tapRunLoop {
            CFRunLoopStop(tapRunLoop)
        }
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil

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
            // 禁用期间可能丢了 modifier 松开 / Esc —— 通知 controller 取消可能残留的
            // session,避免面板卡在屏幕上、isActive 卡 true 吞掉后续方向键/Esc。
            // 未在 session 中时 controller 的 .cancel 是 no-op,安全。
            onEvent?(.cancel)
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
