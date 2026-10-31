import CoreGraphics
import Foundation

// MARK: - 事件来源

/// 事件是谁发的。Velto 自己合成的事件都带标记(`eventSourceUserData`),分发时据此放行或
/// 跳过,否则自己发的事件会被自己再处理一遍。
enum InputEventOrigin: Equatable {
    /// 真实设备,或者别的 App 合成的。
    case device
    /// 手势、鼠标绑定、按键映射发出的快捷键。
    case shortcut
    /// 强制英文标点替换出来的字符。
    case punctuation
    /// 输入法切换修复合成的按键。
    case inputSourceFix
    /// 手势引擎补发的右键。
    case rightClickReplay
    /// 平滑滚动合成的滚轮。
    case smoothScroll

    init(_ event: CGEvent) {
        switch event.getIntegerValueField(.eventSourceUserData) {
        case ShortcutSynthesizer.syntheticEventMarker:
            self = .shortcut
        case InputSourcePunctuationController.syntheticEventMarker:
            self = .punctuation
        case GestureEngine.rightClickReplayMarker:
            self = .rightClickReplay
        case MouseControlController.syntheticScrollMarker:
            self = .smoothScroll
        default:
            // 输入法修复不只看标记:修复进行中自己进程发出的事件也算,所以放在最后判断。
            self = InputSourceSwitchSelector.isSyntheticEvent(event) ? .inputSourceFix : .device
        }
    }

    /// 合成的键盘事件不能再被按键映射改写,也不能污染修饰键状态机。
    var isSynthesizedKeyboard: Bool {
        self == .shortcut || self == .punctuation || self == .inputSourceFix
    }
}

// MARK: - 各模块接入分发的接口

/// 接入分发的模块都要能清掉瞬态:tap 被系统禁用期间事件全丢,按下没等到抬起的记录留着
/// 就会出错(手势卡在半路、修饰键粘住、下一次抬起被误吞)。写进协议,新模块不实现就编译
/// 不过,不会再漏。
protocol InputModule: AnyObject {
    func resetTransientState()
}

/// 全局快捷键:增强 Finder、截图、窗口最大化。
protocol GlobalShortcutInput: InputModule {
    func handleKeyDown(event: CGEvent, normalizedFlags raw: UInt64) -> Bool
}

protocol KeyRemapInput: InputModule {
    func handleFlagsChanged(event: CGEvent) -> Bool
    func handleKeyDown(event: CGEvent) -> Bool
    func handleKeyUp(event: CGEvent) -> Bool
}

protocol PunctuationInput: InputModule {
    func handleKeyDown(event: CGEvent) -> Bool
    func shouldConsumeKeyUp(event: CGEvent) -> Bool
    func noteMouseDown()
}

protocol MouseTriggerInput: InputModule {
    func handleTriggerEvent(type: CGEventType, event: CGEvent, normalizedFlags: UInt64) -> Bool
}

protocol GestureInput: InputModule {
    var isHandlingRightMouse: Bool { get }
    func handleRightMouseDown(at location: CGPoint, originalEvent: CGEvent?) -> Bool
    func handleRightMouseDragged(at location: CGPoint) -> Bool
    func handleRightMouseUp(at location: CGPoint, originalEvent: CGEvent?) -> Bool
    func handleButtonTriggerDown(event: CGEvent, normalizedFlags: UInt64) -> Bool
    func handleButtonTriggerUp(button: Int64) -> Bool
    func isHoldingTriggerButton(_ button: Int64) -> Bool
}

protocol WindowShortcutInput: GlobalShortcutInput {
    func handleMouseDown(event: CGEvent, normalizedFlags raw: UInt64) -> Bool
    func handleMouseUp(button: Int64) -> Bool
    func isHoldingButton(_ button: Int64) -> Bool
}

protocol WindowDragInput: InputModule {
    func dragMode(forNormalizedFlags raw: UInt64) -> WindowDragController.DragMode?
    func handleMouseMoved(at location: CGPoint, mode: WindowDragController.DragMode)
    func handleFlagsChanged(event: CGEvent, normalizedFlags raw: UInt64)
}

protocol ContentZoomInput: InputModule {
    func handleFlagsChanged(normalizedFlags raw: UInt64)
}

extension BetterFinderGlobalShortcutController: GlobalShortcutInput {
    /// 只匹配 keyDown,没有按住状态。
    func resetTransientState() {}
}

extension ScreenshotShortcutController: GlobalShortcutInput {
    /// 只匹配 keyDown,没有按住状态。
    func resetTransientState() {}
}

extension KeyRemapController: KeyRemapInput {}
extension InputSourcePunctuationController: PunctuationInput {}
extension MouseControlController: MouseTriggerInput {}
extension GestureEngine: GestureInput {}
extension WindowShortcutController: WindowShortcutInput {}
extension WindowDragController: WindowDragInput {}
extension ContentZoomController: ContentZoomInput {}

// MARK: - 分发

/// 全局鼠标键盘事件的分发:一个事件依次交给哪些模块、谁能吞掉它。
///
/// 处理顺序就是功能之间的优先级,全部写在这里,由 `InputDispatcherTests` 固定下来。
/// 新增全局快捷键或事件处理时在对应函数里加一行,再补一条顺序测试。
///
/// 全部跑在 HID tap 线程上:回调一阻塞,整个系统的光标和键盘都会冻住,这里和各模块的
/// 入口都不能做可能卡住的调用。
final class InputDispatcher {
    struct Modules {
        let keyRemap: any KeyRemapInput
        let punctuation: any PunctuationInput
        let mouseControl: any MouseTriggerInput
        let gesture: any GestureInput
        let betterFinder: any GlobalShortcutInput
        let screenshot: any GlobalShortcutInput
        let windowShortcut: any WindowShortcutInput
        let windowDrag: any WindowDragInput
        let contentZoom: any ContentZoomInput
    }

    private let modules: Modules

    /// 手势 / 窗口管理是否启用的 tap 线程快照。只在 tap 线程读写(主线程经
    /// `performOnTapThread` 写入;`start()` 之前于主线程设初值,此时无并发)。tap 已和
    /// 功能开关解耦、常驻运行,各分支靠这两个快照决定是否生效。
    var gesturesEnabled = true
    var windowManagementEnabled = true

    /// 下面两项背后是全局状态,测试时替换。
    var isInRightClickPassThrough: (CGEvent) -> Bool = RightClickPassThrough.contains(_:)
    var rewritePointerLocation: (CGEvent) -> Void = { event in
        ScreenshotHotCornerGuard.shared.rewriteLocationIfNeeded(in: event)
        DockRevealGuard.shared.rewriteLocationIfNeeded(in: event)
    }

    init(modules: Modules) {
        self.modules = modules
    }

    /// tap 被系统禁用后调用。遍历 `Modules` 的全部字段,新增模块不用在这里登记。
    func resetTransientState() {
        for module in Mirror(reflecting: modules).children {
            (module.value as? any InputModule)?.resetTransientState()
        }
    }

    /// 返回 `true` 表示事件被吞掉。`event` 可能被就地改写(坐标、类型)。
    func dispatch(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            rewritePointerLocation(event)
        default:
            break
        }

        // Compute the normalized modifier flags exactly once for all
        // downstream checks. This is the hot path; everything else is gated
        // on event type.
        let raw = ModifierFormatter.normalizedRawValue(from: event.flags)

        switch type {
        case .rightMouseDown:
            return rightMouseDown(event, raw)
        case .rightMouseDragged:
            rightMouseDragged(event)
            return false
        case .rightMouseUp:
            return rightMouseUp(event, raw)
        case .leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp:
            return mouseButton(type, event, raw)
        case .otherMouseDragged:
            otherMouseDragged(event)
            return false
        case .mouseMoved:
            mouseMoved(event, raw)
            return false
        case .flagsChanged:
            return flagsChanged(event, raw)
        case .keyDown:
            return keyDown(event, raw)
        case .keyUp:
            return keyUp(event, raw)
        default:
            return false
        }
    }

    // MARK: - 右键

    private func rightMouseDown(_ event: CGEvent, _ raw: UInt64) -> Bool {
        if InputEventOrigin(event) == .rightClickReplay {
            return false
        }
        // 录制手势卡片这种自己想吃右键的 view 已经把屏幕区域登记进来 ——
        // 让事件原样透传,GestureEngine 完全不介入。
        let inPassThrough = isInRightClickPassThrough(event)
        if DebugLog.isEnabled {
            logRightClick(event, inPassThrough: inPassThrough)
        }
        if inPassThrough {
            return false
        }
        if modules.mouseControl.handleTriggerEvent(type: .rightMouseDown, event: event, normalizedFlags: raw) {
            return true
        }
        // 手势关闭:不起手,直接放行(系统右键菜单正常)。只挡 down 即可——没有起手,
        // 后续 dragged/up 时引擎处于 idle 会返回 false 自然透传,不会卡半路。
        guard gesturesEnabled else {
            return false
        }
        _ = modules.gesture.handleRightMouseDown(at: event.location, originalEvent: event)
        return true
    }

    private func rightMouseDragged(_ event: CGEvent) {
        if InputEventOrigin(event) == .rightClickReplay {
            return
        }
        // 透传区只在引擎"未在手势中"时生效。一旦手势已经在卡片外起手(引擎接管),
        // 后续 drag/up 即便飘进透传区也必须继续交给引擎,否则 up 被透传走、引擎卡死。
        if !modules.gesture.isHandlingRightMouse, isInRightClickPassThrough(event) {
            return
        }
        if modules.gesture.handleRightMouseDragged(at: event.location) {
            // 手势期间不吞 drag,而是就地降级成 mouseMoved 透传:
            // - 事件被投递,光标仍由系统指针管线驱动 —— 原生加速手感,也不会
            //   触发"消费 + 触控板同时活跃"时多设备仲裁把光标钉死在起手点的
            //   问题(实测:透传时同样的触控板接触光标跟手正常);
            // - 目标 app 看到的只是普通 mouseMoved(rightMouseDown 已被吞,
            //   在 app 眼里本来就没有按键按着),不会出现右键拖选/拖放。
            // 曾试过逐事件 CGWarpMouseCursorPosition 跟随:功能正确,但绕开
            // 系统指针管线后移动手感变了(手移距离与光标位移对不上),弃用。
            downgradeToMouseMoved(event)
        }
    }

    private func rightMouseUp(_ event: CGEvent, _ raw: UInt64) -> Bool {
        if InputEventOrigin(event) == .rightClickReplay {
            return false
        }
        if !modules.gesture.isHandlingRightMouse, isInRightClickPassThrough(event) {
            return false
        }
        if modules.mouseControl.handleTriggerEvent(type: .rightMouseUp, event: event, normalizedFlags: raw) {
            return true
        }
        return modules.gesture.handleRightMouseUp(at: event.location, originalEvent: event)
    }

    /// 诊断:右键按下时记录点击坐标 + 当前透传区,定位"录制无反应"是区域
    /// 没注册(rw=-1)还是坐标对不上(pass=false 但点其实在卡片内)。
    private func logRightClick(_ event: CGEvent, inPassThrough: Bool) {
        let region = RightClickPassThrough.regionForDebug()
        DebugLog.event("rclick", [
            "x": Double(event.location.x),
            "y": Double(event.location.y),
            "pass": inPassThrough,
            "targetPID": Double(event.getIntegerValueField(.eventTargetUnixProcessID)),
            "selfPID": Double(getpid()),
            "win": Double(event.getIntegerValueField(.mouseEventWindowUnderMousePointer)),
            "winHandle": Double(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)),
            "passWin": RightClickPassThrough.windowNumberForDebug().map(Double.init) ?? -1,
            "rx": region.map { Double($0.minX) } ?? -1,
            "ry": region.map { Double($0.minY) } ?? -1,
            "rw": region.map { Double($0.width) } ?? -1,
            "rh": region.map { Double($0.height) } ?? -1
        ])
    }

    // MARK: - 其他鼠标事件

    private func mouseButton(_ type: CGEventType, _ event: CGEvent, _ raw: UInt64) -> Bool {
        // 鼠标控制里显式绑的按钮优先,手势的鼠标按钮触发排在它后面。
        if modules.mouseControl.handleTriggerEvent(type: type, event: event, normalizedFlags: raw) {
            return true
        }
        if type == .otherMouseDown, gesturesEnabled,
           modules.gesture.handleButtonTriggerDown(event: event, normalizedFlags: raw) {
            return true
        }
        // 窗口管理的「最大化鼠标按钮」排在手势后面:某个 App 给同一按钮配了专属手势时,
        // 在那个 App 里以手势为准。
        if type == .otherMouseDown, windowManagementEnabled,
           modules.windowShortcut.handleMouseDown(event: event, normalizedFlags: raw) {
            return true
        }
        if type == .otherMouseUp {
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if modules.gesture.handleButtonTriggerUp(button: button)
                || modules.windowShortcut.handleMouseUp(button: button) {
                return true
            }
        }
        // 透传到 App 的鼠标按下会提交/取消 IME 组字,强制英文标点的组字推演跟着归零。
        if type == .leftMouseDown || type == .otherMouseDown {
            modules.punctuation.noteMouseDown()
        }
        return false
    }

    private func otherMouseDragged(_ event: CGEvent) {
        // 按钮触发(手势 / 最大化窗口)吞了 down,按住拖动同右键手势一样降级成 mouseMoved 透传:光标照常
        // 跟手,App 也不会看到一串没有按下的按钮拖动。
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if modules.gesture.isHoldingTriggerButton(button)
            || modules.windowShortcut.isHoldingButton(button) {
            downgradeToMouseMoved(event)
        }
    }

    private func downgradeToMouseMoved(_ event: CGEvent) {
        event.type = .mouseMoved
        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.setDoubleValueField(.mouseEventPressure, value: 0)
    }

    private func mouseMoved(_ event: CGEvent, _ raw: UInt64) {
        guard !modules.gesture.isHandlingRightMouse else { return }
        // 拖窗属于窗口管理:总开关关掉则不处理,原样放行。
        guard windowManagementEnabled, raw != 0,
              let mode = modules.windowDrag.dragMode(forNormalizedFlags: raw) else { return }
        modules.windowDrag.handleMouseMoved(at: event.location, mode: mode)
    }

    // MARK: - 键盘

    private func flagsChanged(_ event: CGEvent, _ raw: UInt64) -> Bool {
        // 合成的「上一个输入法」快捷键 / 按键映射修饰键不能污染鼠标控制/缩放/拖窗的修饰键状态机。
        if InputEventOrigin(event).isSynthesizedKeyboard {
            return false
        }
        if modules.keyRemap.handleFlagsChanged(event: event) {
            return true
        }
        guard !modules.gesture.isHandlingRightMouse else {
            return false
        }
        // 鼠标控制不受窗口管理开关影响,先处理;内容缩放 / 拖窗修饰键归窗口管理,
        // 受总开关门控。
        let consumed = modules.mouseControl.handleTriggerEvent(type: .flagsChanged, event: event, normalizedFlags: raw)
        if windowManagementEnabled {
            modules.contentZoom.handleFlagsChanged(normalizedFlags: raw)
            modules.windowDrag.handleFlagsChanged(event: event, normalizedFlags: raw)
        }
        return consumed
    }

    private func keyDown(_ event: CGEvent, _ raw: UInt64) -> Bool {
        switch InputEventOrigin(event) {
        case .shortcut:
            // 手势 / 鼠标绑定发出的快捷键可能正是 Velto 自己的全局快捷键(如窗口管理的
            // 最大化窗口),交给这几个处理器。它们只执行动作、不再合成按键,不会回环;
            // 按键映射、强制标点等改写类处理照旧跳过。
            return ownGlobalShortcut(event, raw)
        case .punctuation, .inputSourceFix:
            return false
        case .device, .rightClickReplay, .smoothScroll:
            break
        }
        if modules.keyRemap.handleKeyDown(event: event) {
            return true
        }
        guard !modules.gesture.isHandlingRightMouse else {
            return false
        }
        if modules.mouseControl.handleTriggerEvent(type: .keyDown, event: event, normalizedFlags: raw) {
            return true
        }
        if modules.betterFinder.handleKeyDown(event: event, normalizedFlags: raw) {
            return true
        }
        // 截图全局触发键(不受窗口管理总开关门控)。
        if modules.screenshot.handleKeyDown(event: event, normalizedFlags: raw) {
            return true
        }
        // 强制英文标点(输入法切换模块):启用的 App 里 CJKV 输入法下,标点键
        // 替换成携带英文字符的新事件。无 ⌘⌃⌥ 修饰才会命中,不影响任何快捷键。
        if modules.punctuation.handleKeyDown(event: event) {
            return true
        }
        // 窗口快捷键(如最大化)归窗口管理,受总开关门控。
        return windowManagementEnabled
            && modules.windowShortcut.handleKeyDown(event: event, normalizedFlags: raw)
    }

    /// Velto 自己的全局快捷键(增强 Finder / 截图 / 窗口管理),供合成的快捷键复用。
    /// 顺序与真实按键路径一致;窗口快捷键受窗口管理总开关门控。
    private func ownGlobalShortcut(_ event: CGEvent, _ raw: UInt64) -> Bool {
        if modules.betterFinder.handleKeyDown(event: event, normalizedFlags: raw) {
            return true
        }
        if modules.screenshot.handleKeyDown(event: event, normalizedFlags: raw) {
            return true
        }
        return windowManagementEnabled
            && modules.windowShortcut.handleKeyDown(event: event, normalizedFlags: raw)
    }

    private func keyUp(_ event: CGEvent, _ raw: UInt64) -> Bool {
        if InputEventOrigin(event).isSynthesizedKeyboard {
            return false
        }
        if modules.punctuation.shouldConsumeKeyUp(event: event) {
            return true
        }
        if modules.keyRemap.handleKeyUp(event: event) {
            return true
        }
        guard !modules.gesture.isHandlingRightMouse else {
            return false
        }
        return modules.mouseControl.handleTriggerEvent(type: .keyUp, event: event, normalizedFlags: raw)
    }
}
