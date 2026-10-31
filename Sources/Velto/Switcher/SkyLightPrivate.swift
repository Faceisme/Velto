import Cocoa
import ApplicationServices

// MARK: - SkyLight private framework
//
// SkyLight 是 macOS 上 WindowServer 的私有框架,这里只声明我们需要的几个符号。
// 这些 API 都不在 SDK 公开头里,一律运行时用 dlsym 查找,不能在链接期绑定:绑定的
// 符号一旦被某次系统更新移除,dyld 启动时就直接失败,Velto 所有功能一起不可用。
// 现在缺了哪个符号只影响用到它的功能,下面的包装函数返回失败值。
//
// 返回 CF 对象的一律声明成 Unmanaged:函数指针的返回值所有权 Swift 不知道,这些
// 都是 Copy / Create 语义(+1),由包装函数 takeRetainedValue。
//
// 来源参考:alt-tab-macos / Hammerspoon。
// 路径:/System/Library/PrivateFrameworks/SkyLight.framework
//
// ⚠️ 这些是私有 API,Apple 可以在任何 macOS 版本里改动签名。alt-tab 已经踩了
//   10+ 年坑,目前(macOS 27)依然可用。如果某天突然挂了,这里要重新核对。

private enum PrivateSymbol: String, CaseIterable {
    case mainConnectionID = "CGSMainConnectionID"
    case copyWindowsWithOptionsAndTags = "CGSCopyWindowsWithOptionsAndTags"
    case copyManagedDisplaySpaces = "CGSCopyManagedDisplaySpaces"
    case moveWindow = "SLSMoveWindow"
    case setSymbolicHotKeyEnabled = "CGSSetSymbolicHotKeyEnabled"
    case setFrontProcessWithOptions = "_SLPSSetFrontProcessWithOptions"
    case postEventRecordTo = "SLPSPostEventRecordTo"
    case getWindow = "_AXUIElementGetWindow"
    case createWithRemoteToken = "_AXUIElementCreateWithRemoteToken"
    case getProcessForPID = "GetProcessForPID"
    case hwCaptureWindowList = "CGSHWCaptureWindowList"

    func function<Function>() -> Function? {
        SkyLightPrivate.address(of: rawValue).map { unsafeBitCast($0, to: Function.self) }
    }
}

enum SkyLightPrivate {
    /// AppKit 本来就会把 SkyLight 带进进程,这里显式打开一次,不依赖这层间接关系。
    private static let frameworkLoaded = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
    ) != nil

    static func address(of symbol: String) -> UnsafeMutableRawPointer? {
        _ = frameworkLoaded
        // -2 就是 RTLD_DEFAULT(搜索全部已加载镜像),这个宏带类型转换,Swift 导入不了。
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol)
    }

    /// 当前系统上找不到的私有符号。启动时记一笔,出问题时能一眼看到是哪个没了。
    static var missingSymbols: [String] {
        PrivateSymbol.allCases.map(\.rawValue).filter { address(of: $0) == nil }
    }
}

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

/// 跟 WindowServer 的连接 ID,启动时拿一次就够。
let CGS_CONNECTION = CGSMainConnectionID()

private let mainConnectionID: (@Sendable @convention(c) () -> CGSConnectionID)? =
    PrivateSymbol.mainConnectionID.function()

func CGSMainConnectionID() -> CGSConnectionID {
    mainConnectionID?() ?? 0
}

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
func CGSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID, _ owner: Int, _ spaces: CFArray, _ options: Int, _ setTags: UnsafeMutablePointer<Int>, _ clearTags: UnsafeMutablePointer<Int>) -> CFArray {
    copyWindowsWithOptionsAndTags?(cid, owner, spaces, options, setTags, clearTags)?.takeRetainedValue() ?? [] as CFArray
}

private let copyWindowsWithOptionsAndTags: (@Sendable @convention(c) (CGSConnectionID, Int, CFArray, Int, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>) -> Unmanaged<CFArray>?)? =
    PrivateSymbol.copyWindowsWithOptionsAndTags.function()

// MARK: - Space 查询

/// 用 SLS 命名是更现代的别名;实际跟 CGS 是同一个符号空间。
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray {
    copyManagedDisplaySpaces?(cid)?.takeRetainedValue() ?? [] as CFArray
}

private let copyManagedDisplaySpaces: (@Sendable @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?)? =
    PrivateSymbol.copyManagedDisplaySpaces.function()

// MARK: - 窗口操作

/// 直接让 WindowServer 挪窗口,**只需要 wid,不需要目标 app 配合**。
/// 给 Telegram / 微信 / 富途这种对 `kAXWindows` 恒返回 0 的 app 兜底拖拽用
/// (实测跨进程有效,不需要动 SIP)。`origin` 与 CGWindowList bounds 同坐标系
/// (y-down、左上原点)。只管位置;改大小要走 AX,SkyLight 改 shape 不会通知
/// app 重新布局,拉出来是花的。
@discardableResult
func SLSMoveWindow(_ cid: CGSConnectionID, _ wid: CGWindowID, _ origin: UnsafePointer<CGPoint>) -> CGError {
    moveWindow?(cid, wid, origin) ?? .failure
}

private let moveWindow: (@Sendable @convention(c) (CGSConnectionID, CGWindowID, UnsafePointer<CGPoint>) -> CGError)? =
    PrivateSymbol.moveWindow.function()

// MARK: - 符号热键(系统级 Cmd+Tab 等)

enum CGSSymbolicHotKey: Int, CaseIterable {
    case commandTab = 1
    case commandShiftTab = 2
    /// 同一 app 的窗口循环:⌘`(键码与输入源相关,这里走系统映射)
    case commandKeyAboveTab = 6
}

/// 打开/关闭系统级热键。我们接管 Cmd+Tab 时要关掉系统这个,退出 app 时必须再开回去。
/// 注意:**effect 持续到下次开机**,即使我们 crash 了系统 Cmd+Tab 也不会自动恢复。
@discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: CGSSymbolicHotKey.RawValue, _ isEnabled: Bool) -> CGError {
    setSymbolicHotKeyEnabled?(hotKey, isEnabled) ?? .failure
}

private let setSymbolicHotKeyEnabled: (@Sendable @convention(c) (CGSSymbolicHotKey.RawValue, Bool) -> CGError)? =
    PrivateSymbol.setSymbolicHotKeyEnabled.function()

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
@discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: SLPSMode.RawValue) -> CGError {
    setFrontProcessWithOptions?(psn, wid, mode) ?? .failure
}

private let setFrontProcessWithOptions: (@Sendable @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, SLPSMode.RawValue) -> CGError)? =
    PrivateSymbol.setFrontProcessWithOptions.function()

/// 给 WindowServer 投递一段原始事件字节流。配合下面 SwitcherFocus.makeKeyWindow
/// 的字节排布,让指定 wid 变成那个进程的 key window。
/// 这是从 Hammerspoon 反编译来的魔法序列。
@discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError {
    postEventRecordTo?(psn, bytes) ?? .failure
}

private let postEventRecordTo: (@Sendable @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError)? =
    PrivateSymbol.postEventRecordTo.function()

// MARK: - AX → CGWindowID

/// 从 AXUIElement 拿到对应的 CGWindowID。公开 SDK 里只能反过来:有 wid 没法拿 AXUIElement。
/// 这是 alt-tab 整个 Window 模型能把 AX 和 CGS 两个世界打通的关键。
@discardableResult
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError {
    getWindow?(axUiElement, wid) ?? .failure
}

private let getWindow: (@Sendable @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? =
    PrivateSymbol.getWindow.function()

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
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>? {
    createWithRemoteToken?(data)
}

private let createWithRemoteToken: (@Sendable @convention(c) (CFData) -> Unmanaged<AXUIElement>?)? =
    PrivateSymbol.createWithRemoteToken.function()

// MARK: - Carbon Process Manager(SLPS 需要)

/// `_SLPSSetFrontProcessWithOptions` 需要 ProcessSerialNumber,但拿 PSN 的
/// `GetProcessForPID` 是 Carbon API,从 macOS 10.9 起被标 unavailable in Swift。
/// 自己声明一下绕过 availability 检查 —— symbol 在 CoreServices/ApplicationServices
/// 里仍然存在并且能用。Apple 没真的删,只是没给 Swift binding。
@discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus {
    getProcessForPID?(pid, psn) ?? -1
}

private let getProcessForPID: (@Sendable @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus)? =
    PrivateSymbol.getProcessForPID.function()

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
func CGSHWCaptureWindowList(_ cid: CGSConnectionID, _ windowList: UnsafeMutablePointer<CGWindowID>, _ windowCount: UInt32, _ options: CGSWindowCaptureOptions) -> Unmanaged<CFArray>? {
    hwCaptureWindowList?(cid, windowList, windowCount, options.rawValue)
}

private let hwCaptureWindowList: (@Sendable @convention(c) (CGSConnectionID, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32) -> Unmanaged<CFArray>?)? =
    PrivateSymbol.hwCaptureWindowList.function()
