import Cocoa
import ApplicationServices

// MARK: - SkyLight private framework
//
// SkyLight 是 macOS 上 WindowServer 的私有框架,这里只声明我们需要的几个符号。
// 这些 API 都不在 SDK 公开头里,需要通过 @_silgen_name 让 Swift 在链接期解析,
// 同时在 Package.swift 里加 -framework SkyLight 让 ld 找到符号。
//
// 来源参考:alt-tab-macos / Hammerspoon。
// 路径:/System/Library/PrivateFrameworks/SkyLight.framework
//
// ⚠️ 这些是私有 API,Apple 可以在任何 macOS 版本里改动签名。alt-tab 已经踩了
//   10+ 年坑,目前(macOS 26 / Tahoe)依然可用。如果某天突然挂了,这里要重新核对。

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64
typealias ScreenUuid = CFString

/// 跟 WindowServer 的连接 ID,启动时拿一次就够。
let CGS_CONNECTION = CGSMainConnectionID()

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

// MARK: - 窗口枚举

struct CGSCopyWindowsOptions: OptionSet {
    let rawValue: Int
    static let invisible1 = CGSCopyWindowsOptions(rawValue: 1 << 0)
    /// 当 app 设置了 "Assign To: All Spaces" 或窗口在 ScreenSaver level 时拿到
    static let screenSaverLevel1000 = CGSCopyWindowsOptions(rawValue: 1 << 1)
    static let invisible2 = CGSCopyWindowsOptions(rawValue: 1 << 2)
}

struct CGSCopyWindowsTags: OptionSet {
    let rawValue: Int
    static let level0 = CGSCopyWindowsTags(rawValue: 1 << 0)
    static let noTitleMaybePopups = CGSCopyWindowsTags(rawValue: 1 << 1)
    static let mainMenuWindowAndDesktopIconWindow = CGSCopyWindowsTags(rawValue: 1 << 3)
}

/// 列出指定 Space 集合里的窗口 wid 数组,按 z 顺序排(顶在前)。
/// 这是 ghost 检测的核心:WindowServer 视角的"真实可见窗口"。
@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID, _ owner: Int, _ spaces: CFArray, _ options: Int, _ setTags: UnsafeMutablePointer<Int>, _ clearTags: UnsafeMutablePointer<Int>) -> CFArray

// MARK: - Space 查询

/// 用 SLS 命名是更现代的别名;实际跟 CGS 是同一个符号空间。
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
func CGSManagedDisplayGetCurrentSpace(_ cid: CGSConnectionID, _ displayUuid: ScreenUuid) -> CGSSpaceID

enum CGSSpaceMask: Int {
    case current = 5
    case other = 6
    case all = 7
}

/// 给一组窗口 wid,返回各自所在的 Space 数组。空数组意味着窗口"无 Space"
/// (ghost / Electron 隐藏窗口的典型特征之一)。
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: CGSSpaceMask.RawValue, _ wids: CFArray) -> CFArray

// MARK: - 窗口属性

@_silgen_name("CGSGetWindowLevel") @discardableResult
func CGSGetWindowLevel(_ cid: CGSConnectionID, _ wid: CGWindowID, _ level: UnsafeMutablePointer<CGWindowLevel>) -> CGError

@_silgen_name("CGSCopyWindowProperty") @discardableResult
func CGSCopyWindowProperty(_ cid: CGSConnectionID, _ wid: CGWindowID, _ property: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>) -> CGError

// MARK: - 屏幕

@_silgen_name("CGSCopyActiveMenuBarDisplayIdentifier")
func CGSCopyActiveMenuBarDisplayIdentifier(_ cid: CGSConnectionID) -> ScreenUuid

// MARK: - 符号热键(系统级 Cmd+Tab 等)

enum CGSSymbolicHotKey: Int, CaseIterable {
    case commandTab = 1
    case commandShiftTab = 2
    /// 同一 app 的窗口循环:⌘`(键码与输入源相关,这里走系统映射)
    case commandKeyAboveTab = 6
}

/// 打开/关闭系统级热键。我们接管 Cmd+Tab 时要关掉系统这个,退出 app 时必须再开回去。
/// 注意:**effect 持续到下次开机**,即使我们 crash 了系统 Cmd+Tab 也不会自动恢复。
@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: CGSSymbolicHotKey.RawValue, _ isEnabled: Bool) -> CGError

func setNativeCommandTabEnabled(_ isEnabled: Bool, _ hotkeys: [CGSSymbolicHotKey] = CGSSymbolicHotKey.allCases) {
    for hk in hotkeys {
        CGSSetSymbolicHotKeyEnabled(hk.rawValue, isEnabled)
    }
}

// MARK: - 焦点切换(P1-5 的核心)

enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

/// 把指定 wid 所属的进程置为前台。和 NSRunningApplication.activate 的区别:
/// 这个 API **能指向某个具体窗口**,而 NSRunningApplication 只能"激活 app"。
@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: SLPSMode.RawValue) -> CGError

/// 给 WindowServer 投递一段原始事件字节流。配合下面 SwitcherFocus.makeKeyWindow
/// 的字节排布,让指定 wid 变成那个进程的 key window。
/// 这是从 Hammerspoon 反编译来的魔法序列。
@_silgen_name("SLPSPostEventRecordTo") @discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

// MARK: - AX → CGWindowID

/// 从 AXUIElement 拿到对应的 CGWindowID。公开 SDK 里只能反过来:有 wid 没法拿 AXUIElement。
/// 这是 alt-tab 整个 Window 模型能把 AX 和 CGS 两个世界打通的关键。
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// AXUIElement 的进程内 ID。每个进程独立自增,大致代表"这是第几个 UI 元素"。
/// 暴力枚举跨 Space 窗口时用得着。
typealias AXUIElementID = UInt64

/// 用 (pid, axUiElementId) 反查 AXUIElement。这是绕过 `kAXWindowsAttribute` 只能
/// 拿到当前 Space 窗口限制的**唯一**手段 —— 标准 AX API 不会返回跨 Space 窗口,
/// 但 `_AXUIElementCreateWithRemoteToken` 直接通过远程 token 构造 AXUIElement,
/// 拿出来的就是真窗口,不在乎 Space。
///
/// remoteToken 是 20 字节,布局:
///   - bytes 0..4 (UInt32): pid
///   - bytes 4..8: 0(保留)
///   - bytes 8..12 (Int32): magic 0x636f636f("coco" ASCII)
///   - bytes 12..20 (UInt64): axUiElementId
///
/// 不公开,alt-tab 用了多年依然稳定。
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

// MARK: - Carbon Process Manager(SLPS 需要)

/// `_SLPSSetFrontProcessWithOptions` 需要 ProcessSerialNumber,但拿 PSN 的
/// `GetProcessForPID` 是 Carbon API,从 macOS 10.9 起被标 unavailable in Swift。
/// 自己声明一下绕过 availability 检查 —— symbol 在 CoreServices/ApplicationServices
/// 里仍然存在并且能用。Apple 没真的删,只是没给 Swift binding。
@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

// MARK: - 私有窗口截图(最小化窗口的最后一帧)

struct CGSWindowCaptureOptions: OptionSet {
    let rawValue: UInt32
    static let ignoreGlobalClipShape = CGSWindowCaptureOptions(rawValue: 1 << 11)
    static let nominalResolution = CGSWindowCaptureOptions(rawValue: 1 << 9)
    static let bestResolution = CGSWindowCaptureOptions(rawValue: 1 << 8)
    /// Stage Manager 开启时,常规截图会被斜切;这个选项强制原尺寸输出
    static let fullSize = CGSWindowCaptureOptions(rawValue: 1 << 19)
}

/// **能抓最小化窗口的最后一帧**。SCK 抓最小化窗口会失败或返回空,这是唯一可靠
/// 的兜底路径。
/// 接口能传多个 wid,实测系统只返回第一个的图(alt-tab 也踩过这个坑)。
@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(_ cid: CGSConnectionID, _ windowList: UnsafeMutablePointer<CGWindowID>, _ windowCount: UInt32, _ options: CGSWindowCaptureOptions) -> Unmanaged<CFArray>
