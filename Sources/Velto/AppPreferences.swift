import CoreGraphics
import Foundation

struct AppPreferences: Codable, Equatable {
    var gesturesEnabled: Bool
    /// 窗口管理(拖窗 / 内容缩放 / 窗口快捷键)总开关。关掉只停这三项,不影响手势 /
    /// 鼠标控制。带默认值,旧配置(无此字段)解码时按 `decodeField` 回退到 true。
    var windowManagementEnabled: Bool = true
    /// 窗口管理调试日志开关。默认关,关闭时日志路径零文件开销。开启后写
    /// ~/Library/Logs/Velto/window-management.log,记录 move/resize 目标定位决策。
    var windowManagementDebugLoggingEnabled: Bool = false
    /// 网络监控(菜单栏网速 + 进程/连接面板)开关。默认开。
    var networkMonitorEnabled: Bool = true
    var showTrail: Bool
    var showMenuBarIcon: Bool
    var recognitionThreshold: Double
    var gestureTimeoutSeconds: Double
    /// 开启后,手势进行中"来回乱划几下"会立即判为无效并取消,无需等待超时。
    var scribbleCancelEnabled: Bool
    /// 调试模式总开关(默认关)。开启后诊断日志(如手势轨迹)会写入
    /// ~/Library/Logs/Velto/,便于排查与迭代;关闭时几乎零开销。
    var debugLoggingEnabled: Bool
    var gestureTargetPolicy: GestureTargetPolicy
    var windowMoveModifierFlags: UInt64
    var windowResizeModifierFlags: UInt64
    var contentZoomModifierFlags: UInt64
    var windowMaximizeShortcut: Shortcut?
    /// 按下此鼠标按钮 → 最大化光标下的窗口。带默认值,旧配置(无此字段)解码为 nil。
    var windowMaximizeButton: MouseButtonTrigger? = nil
    /// 最大化鼠标按钮的例外 App(bundle id):光标下是这些 App 时按钮原样交给 App
    /// (如 Movist Pro 自己把中键配成全屏播放)。旧配置解码为空。
    var windowMaximizeButtonExcludedApps: [String] = []
    var mouseControl: MouseControlPreferences
    /// 窗口切换器的全部配置 —— 子结构定义在 Switcher/SwitcherPreferences.swift。
    /// 嵌进来跟手势/窗口管理共享一份 JSON 持久化。
    var switcher: SwitcherPreferences
    /// 输入法自动切换的全部配置 —— 子结构定义在
    /// InputSourceSwitch/InputSourceSwitchPreferences.swift。
    var inputSourceSwitch: InputSourceSwitchPreferences
    /// 截图模块配置 —— 子结构在 Screenshot/ScreenshotPreferences.swift。
    var screenshot: ScreenshotPreferences
    /// 专注自动化 —— 子结构在 FocusAutomation/FocusAutomationPreferences.swift。
    var focusAutomation: FocusAutomationPreferences = .defaults
    /// Mac小助手 —— 子结构在 MacAssistant/MacAssistantPreferences.swift。
    var macAssistant: MacAssistantPreferences = .defaults

    init(
        gesturesEnabled: Bool,
        showTrail: Bool,
        showMenuBarIcon: Bool,
        recognitionThreshold: Double,
        gestureTimeoutSeconds: Double,
        scribbleCancelEnabled: Bool,
        debugLoggingEnabled: Bool,
        gestureTargetPolicy: GestureTargetPolicy,
        windowMoveModifierFlags: UInt64,
        windowResizeModifierFlags: UInt64,
        contentZoomModifierFlags: UInt64,
        windowMaximizeShortcut: Shortcut?,
        mouseControl: MouseControlPreferences,
        switcher: SwitcherPreferences,
        inputSourceSwitch: InputSourceSwitchPreferences,
        screenshot: ScreenshotPreferences
    ) {
        self.gesturesEnabled = gesturesEnabled
        self.showTrail = showTrail
        self.showMenuBarIcon = showMenuBarIcon
        self.recognitionThreshold = recognitionThreshold
        self.gestureTimeoutSeconds = gestureTimeoutSeconds
        self.scribbleCancelEnabled = scribbleCancelEnabled
        self.debugLoggingEnabled = debugLoggingEnabled
        self.gestureTargetPolicy = gestureTargetPolicy
        self.windowMoveModifierFlags = windowMoveModifierFlags
        self.windowResizeModifierFlags = windowResizeModifierFlags
        self.contentZoomModifierFlags = contentZoomModifierFlags
        self.windowMaximizeShortcut = windowMaximizeShortcut
        self.mouseControl = mouseControl
        self.switcher = switcher
        self.inputSourceSwitch = inputSourceSwitch
        self.screenshot = screenshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gesturesEnabled = try container.decodeField(Bool.self, forKey: .gesturesEnabled, in: decoder) ?? Self.defaults.gesturesEnabled
        windowManagementEnabled = try container.decodeField(Bool.self, forKey: .windowManagementEnabled, in: decoder) ?? Self.defaults.windowManagementEnabled
        windowManagementDebugLoggingEnabled = try container.decodeField(Bool.self, forKey: .windowManagementDebugLoggingEnabled, in: decoder) ?? Self.defaults.windowManagementDebugLoggingEnabled
        networkMonitorEnabled = try container.decodeField(Bool.self, forKey: .networkMonitorEnabled, in: decoder) ?? Self.defaults.networkMonitorEnabled
        showTrail = try container.decodeField(Bool.self, forKey: .showTrail, in: decoder) ?? Self.defaults.showTrail
        showMenuBarIcon = try container.decodeField(Bool.self, forKey: .showMenuBarIcon, in: decoder) ?? Self.defaults.showMenuBarIcon
        recognitionThreshold = try container.decodeField(Double.self, forKey: .recognitionThreshold, in: decoder) ?? Self.defaults.recognitionThreshold
        gestureTimeoutSeconds = try container.decodeField(Double.self, forKey: .gestureTimeoutSeconds, in: decoder) ?? Self.defaults.gestureTimeoutSeconds
        scribbleCancelEnabled = try container.decodeField(Bool.self, forKey: .scribbleCancelEnabled, in: decoder) ?? Self.defaults.scribbleCancelEnabled
        debugLoggingEnabled = try container.decodeField(Bool.self, forKey: .debugLoggingEnabled, in: decoder) ?? Self.defaults.debugLoggingEnabled
        gestureTargetPolicy = try container.decodeField(GestureTargetPolicy.self, forKey: .gestureTargetPolicy, in: decoder) ?? Self.defaults.gestureTargetPolicy
        windowMoveModifierFlags = try container.decodeField(UInt64.self, forKey: .windowMoveModifierFlags, in: decoder) ?? Self.defaults.windowMoveModifierFlags
        windowResizeModifierFlags = try container.decodeField(UInt64.self, forKey: .windowResizeModifierFlags, in: decoder) ?? Self.defaults.windowResizeModifierFlags
        contentZoomModifierFlags = try container.decodeField(UInt64.self, forKey: .contentZoomModifierFlags, in: decoder) ?? Self.defaults.contentZoomModifierFlags
        windowMaximizeShortcut = try container.decodeField(Shortcut.self, forKey: .windowMaximizeShortcut, in: decoder) ?? Self.defaults.windowMaximizeShortcut
        windowMaximizeButton = try container.decodeField(MouseButtonTrigger.self, forKey: .windowMaximizeButton, in: decoder)
        windowMaximizeButtonExcludedApps = try container.decodeField([String].self, forKey: .windowMaximizeButtonExcludedApps, in: decoder) ?? []
        mouseControl = try container.decodeField(MouseControlPreferences.self, forKey: .mouseControl, in: decoder) ?? Self.defaults.mouseControl
        switcher = try container.decodeField(SwitcherPreferences.self, forKey: .switcher, in: decoder) ?? Self.defaults.switcher
        inputSourceSwitch = try container.decodeField(InputSourceSwitchPreferences.self, forKey: .inputSourceSwitch, in: decoder) ?? Self.defaults.inputSourceSwitch
        screenshot = try container.decodeField(ScreenshotPreferences.self, forKey: .screenshot, in: decoder) ?? Self.defaults.screenshot
        focusAutomation = try container.decodeField(FocusAutomationPreferences.self, forKey: .focusAutomation, in: decoder) ?? Self.defaults.focusAutomation
        macAssistant = try container.decodeField(MacAssistantPreferences.self, forKey: .macAssistant, in: decoder) ?? Self.defaults.macAssistant
    }

    static let defaults = AppPreferences(
        gesturesEnabled: true,
        showTrail: true,
        showMenuBarIcon: true,
        recognitionThreshold: 0.34,
        gestureTimeoutSeconds: 3.0,
        scribbleCancelEnabled: true,
        debugLoggingEnabled: false,
        gestureTargetPolicy: .windowUnderPointer,
        windowMoveModifierFlags: 0,
        windowResizeModifierFlags: 0,
        contentZoomModifierFlags: 0,
        windowMaximizeShortcut: nil,
        mouseControl: .defaults,
        switcher: .defaults,
        inputSourceSwitch: .defaults,
        screenshot: .defaults
    )
}
