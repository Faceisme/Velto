import CoreGraphics
import Foundation

// MARK: - 枚举类型

/// 显示三档:正常显示 / 显示在末尾 / 隐藏
/// 跟 alt-tab `ShowHowPreference` 对应。
enum SwitcherShowMode: String, Codable, CaseIterable, Hashable {
    case show
    case showAtEnd
    case hide

    var displayName: String {
        switch self {
        case .show: return "显示"
        case .showAtEnd: return "显示在末尾"
        case .hide: return "隐藏"
        }
    }
}

/// 应用范围:所有 / 仅前台 / 仅非前台
enum SwitcherAppsScope: String, Codable, CaseIterable, Hashable {
    case all
    case onlyActive
    case onlyNonActive

    var displayName: String {
        switch self {
        case .all: return "所有应用"
        case .onlyActive: return "仅当前应用"
        case .onlyNonActive: return "仅非当前应用"
        }
    }
}

/// Space 范围
enum SwitcherSpacesScope: String, Codable, CaseIterable, Hashable {
    case all
    case visible
    case nonVisible

    var displayName: String {
        switch self {
        case .all: return "所有桌面"
        case .visible: return "仅可见桌面"
        case .nonVisible: return "仅不可见桌面"
        }
    }
}

/// 屏幕范围
enum SwitcherScreensScope: String, Codable, CaseIterable, Hashable {
    case all
    case onlySwitcherScreen

    var displayName: String {
        switch self {
        case .all: return "所有屏幕"
        case .onlySwitcherScreen: return "仅切换器所在屏幕"
        }
    }
}

/// 分组方式:每个窗口一个条目 / 每个应用一个条目
enum SwitcherGroupingMode: String, Codable, CaseIterable, Hashable {
    case perWindow
    case perApp

    var displayName: String {
        switch self {
        case .perWindow: return "按窗口"
        case .perApp: return "按应用"
        }
    }
}

/// 排序方式
enum SwitcherSortOrder: String, Codable, CaseIterable, Hashable {
    case recentlyFocused
    case recentlyCreated
    case alphabetical
    case bySpace

    var displayName: String {
        switch self {
        case .recentlyFocused: return "最近聚焦"
        case .recentlyCreated: return "最近创建"
        case .alphabetical: return "字母顺序"
        case .bySpace: return "按桌面分组"
        }
    }
}

/// 切换器面板在哪个屏幕显示
enum SwitcherScreenChoice: String, Codable, CaseIterable, Hashable {
    case mouse
    case active
    case main

    var displayName: String {
        switch self {
        case .mouse: return "鼠标所在屏幕"
        case .active: return "活跃屏幕"
        case .main: return "主屏幕"
        }
    }
}

/// 外观样式 —— P2 我们做了缩略图,P3 设置项留扩展位
enum SwitcherAppearanceStyle: String, Codable, CaseIterable, Hashable {
    case thumbnails
    case appIcons
    case titles

    var displayName: String {
        switch self {
        case .thumbnails: return "缩略图"
        case .appIcons: return "仅图标"
        case .titles: return "仅标题"
        }
    }
}

// MARK: - 偏好结构体

/// 切换器所有用户可调节的设置。
///
/// 持久化路径:嵌在 AppPreferences.switcher 里走同一份 JSON,跟手势 / 窗口管理
/// 的偏好共享 `GestureStore.savePreferences()`。
///
/// 字段添加规则:**只能加,不能改类型/删字段**。`init(from:)` 用 decodeIfPresent
/// 兜底 nil → defaults,保证老用户升级时偏好不丢。
struct SwitcherPreferences: Codable, Equatable {
    /// 总开关。关掉后 Cmd+Tab 会还给系统原生 switcher。
    var enabled: Bool

    /// 触发快捷键。nil 表示用户没设(P3 默认 Cmd+Tab,见 defaults)。
    var triggerShortcut: Shortcut?

    // --- 过滤器(对应 alt-tab "筛选" 那个 tab 的 7 个下拉)---
    var appsToShow: SwitcherAppsScope
    var spacesToShow: SwitcherSpacesScope
    var screensToShow: SwitcherScreensScope
    var minimizedWindows: SwitcherShowMode
    var hiddenWindows: SwitcherShowMode
    var fullscreenWindows: SwitcherShowMode
    var windowlessApps: SwitcherShowMode

    // --- 排序与分组 ---
    var sortBy: SwitcherSortOrder
    var groupBy: SwitcherGroupingMode

    // --- 屏幕与外观 ---
    var showOnScreen: SwitcherScreenChoice
    var appearanceStyle: SwitcherAppearanceStyle

    static let defaults = SwitcherPreferences(
        enabled: true,
        // 默认 ⌘ + Tab。displayName 用户看到的格式跟 ShortcutSynthesizer 输出的对得上。
        triggerShortcut: Shortcut(
            keyCode: 48,                  // Tab key
            modifierFlags: UInt64(CGEventFlags.maskCommand.rawValue),
            displayName: "⌘⇥"
        ),
        appsToShow: .all,
        spacesToShow: .all,
        screensToShow: .all,
        minimizedWindows: .show,
        hiddenWindows: .hide,
        fullscreenWindows: .show,
        windowlessApps: .hide,
        sortBy: .recentlyFocused,
        groupBy: .perWindow,
        showOnScreen: .mouse,
        appearanceStyle: .thumbnails
    )

    init(
        enabled: Bool,
        triggerShortcut: Shortcut?,
        appsToShow: SwitcherAppsScope,
        spacesToShow: SwitcherSpacesScope,
        screensToShow: SwitcherScreensScope,
        minimizedWindows: SwitcherShowMode,
        hiddenWindows: SwitcherShowMode,
        fullscreenWindows: SwitcherShowMode,
        windowlessApps: SwitcherShowMode,
        sortBy: SwitcherSortOrder,
        groupBy: SwitcherGroupingMode,
        showOnScreen: SwitcherScreenChoice,
        appearanceStyle: SwitcherAppearanceStyle
    ) {
        self.enabled = enabled
        self.triggerShortcut = triggerShortcut
        self.appsToShow = appsToShow
        self.spacesToShow = spacesToShow
        self.screensToShow = screensToShow
        self.minimizedWindows = minimizedWindows
        self.hiddenWindows = hiddenWindows
        self.fullscreenWindows = fullscreenWindows
        self.windowlessApps = windowlessApps
        self.sortBy = sortBy
        self.groupBy = groupBy
        self.showOnScreen = showOnScreen
        self.appearanceStyle = appearanceStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        triggerShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .triggerShortcut) ?? d.triggerShortcut
        appsToShow = try c.decodeIfPresent(SwitcherAppsScope.self, forKey: .appsToShow) ?? d.appsToShow
        spacesToShow = try c.decodeIfPresent(SwitcherSpacesScope.self, forKey: .spacesToShow) ?? d.spacesToShow
        screensToShow = try c.decodeIfPresent(SwitcherScreensScope.self, forKey: .screensToShow) ?? d.screensToShow
        minimizedWindows = try c.decodeIfPresent(SwitcherShowMode.self, forKey: .minimizedWindows) ?? d.minimizedWindows
        hiddenWindows = try c.decodeIfPresent(SwitcherShowMode.self, forKey: .hiddenWindows) ?? d.hiddenWindows
        fullscreenWindows = try c.decodeIfPresent(SwitcherShowMode.self, forKey: .fullscreenWindows) ?? d.fullscreenWindows
        windowlessApps = try c.decodeIfPresent(SwitcherShowMode.self, forKey: .windowlessApps) ?? d.windowlessApps
        sortBy = try c.decodeIfPresent(SwitcherSortOrder.self, forKey: .sortBy) ?? d.sortBy
        groupBy = try c.decodeIfPresent(SwitcherGroupingMode.self, forKey: .groupBy) ?? d.groupBy
        showOnScreen = try c.decodeIfPresent(SwitcherScreenChoice.self, forKey: .showOnScreen) ?? d.showOnScreen
        appearanceStyle = try c.decodeIfPresent(SwitcherAppearanceStyle.self, forKey: .appearanceStyle) ?? d.appearanceStyle
    }
}
