import ApplicationServices
import Cocoa

/// 单个被切换器跟踪的窗口。
///
/// 同时记 AXUIElement 和 CGWindowID —— 一个负责 AX 操作(focus、minimize),
/// 一个负责 CGS 操作(z-order、Space 归属、ghost 检测)。两者用
/// `_AXUIElementGetWindow` 桥接。
///
/// `@unchecked Sendable`:可变字段只在 main 线程上改。
final class SwitcherWindow: @unchecked Sendable {
    /// 稳定 id,UI 列表里做 hashing 用。
    let id: String

    /// 所属 app。强引用 OK —— app 销毁时整个 window 也会被移除。
    let application: SwitcherApp

    /// CGS 视角的窗口 id。从 _AXUIElementGetWindow 读出来。
    let cgWindowId: CGWindowID

    /// 这个窗口是不是走 CGWindowList 兜底管线建的(富途牛牛这类对 Accessibility
    /// 零窗口暴露的 app)。为 true 时:axUiElement 只是 app 元素占位、不订阅窗口级
    /// AX 通知(没有真窗口 element 可订),raise 全靠 SLPS(只需 pid+wid)。
    let isCgOnly: Bool

    /// AX 视角的窗口句柄。focus / minimize / 读 title 都用它。
    /// 可变:app 重建 AX 树时(微信 4.x)同一个 wid 会换新 element,
    /// SwitcherWindowList.applyProbes 负责替换并重挂窗口级通知。主线程改。
    var axUiElement: AXUIElement

    // MARK: 主线程可变状态

    /// 用户能看到的标题(最佳努力:AX → CG → app 名)。
    var title: String

    /// 是否被 macOS minimize 到 Dock。
    var isMinimized: Bool

    /// 是否处于独占 Space 的 fullscreen 模式。
    var isFullscreen: Bool

    /// 窗口大小,跟 position 配套使用做屏幕命中判定。
    var size: CGSize?

    /// 该窗口所在的 Space id 列表。空数组 = WindowServer 不认识这个窗口
    /// = ghost / Electron 隐藏窗口的最强信号。
    var spaceIds: [CGSSpaceID]

    /// 窗口屏幕坐标(top-left,Quartz 坐标系)和尺寸。
    /// 主要给"屏幕过滤"用 —— 判断窗口在哪块 NSScreen 上。
    /// 为 nil 时(AX 没给出来,minimized 窗口常见)假设不限制屏幕。
    var position: CGPoint?

    /// ghost 检测的最终判定。详情见 SwitcherWindowList.refreshGhosts。
    /// 用户切换器里**永远不显示** isInvisible 为 true 的窗口。
    var isInvisible: Bool

    /// MRU 排序键 —— 越小越靠前。当前 focus 的窗口是 0,刚切走的是 1,以此类推。
    var lastFocusOrder: Int

    /// 连续多少次"扫描成功但本窗口没出现"。例行扫描用两阶段移除:一次 AX 扫描瞬时
    /// 缺字段 / 漏窗不立刻删窗,避免列表闪烁 / MRU 被打乱。明确关闭 / 最小化这类
    /// 窗口状态变化会用更激进的删除策略。每次被扫描到就清零。
    var missCount: Int = 0

    /// 当前缓存的缩略图。两种载体:
    ///   - `.pixelBuffer`:SCK 拿到的 CVPixelBuffer(走 IOSurface 零拷贝,首选)
    ///   - `.cgImage`:CGSHWCaptureWindowList 私有 API 兜底拿的(主要给最小化窗口用)
    ///
    /// Nil 表示从没抓过 / 抓失败 / 没权限,UI 端退化到只显示 app 图标。
    /// session 结束不主动清(下次召唤可以临时复用旧图当占位,跟 alt-tab 一致)。
    /// **写这个字段一律走 `setThumbnail`**,否则时效戳会失真。
    private(set) var thumbnail: CALayerContents?

    /// `thumbnail` 的抓取时刻(CFAbsoluteTime)。0 = 没有图。
    /// 用来判断"图还新不新" —— 抓过一次就永不刷新会让面板显示十分钟前的画面,
    /// 图和现实对不上是切换器最伤信任感的一件事。见 `SwitcherThumbnails.staleAfter`。
    private(set) var thumbnailCapturedAt: CFAbsoluteTime = 0

    /// 写缩略图的唯一入口 —— 顺手记时刻。传 nil 表示释放。
    func setThumbnail(_ contents: CALayerContents?) {
        thumbnail = contents
        thumbnailCapturedAt = contents == nil ? 0 : CFAbsoluteTimeGetCurrent()
    }

    /// 我们想在窗口本体上订阅的 AX 通知。app 级 observer 是同一个 AXObserver,
    /// 但要把这些通知挂到具体的 window AXUIElement 上,事件才会真触发。
    ///   - destroyed:窗口被关闭(没必要等下次 sync 才发现)
    ///   - miniaturized / deminiaturized:实时反映最小化状态,过滤器立刻生效
    ///   - title changed:实时更新 tile 上的标题
    static let observedNotifications: [String] = [
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification,
    ]

    init(application: SwitcherApp,
         cgWindowId: CGWindowID,
         axUiElement: AXUIElement,
         title: String,
         isMinimized: Bool,
         isFullscreen: Bool,
         spaceIds: [CGSSpaceID],
         position: CGPoint?,
         size: CGSize?,
         isCgOnly: Bool = false)
    {
        self.id = "wid-\(cgWindowId)"
        self.application = application
        self.cgWindowId = cgWindowId
        self.isCgOnly = isCgOnly
        self.axUiElement = axUiElement
        self.title = title
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.spaceIds = spaceIds
        self.position = position
        self.size = size
        self.isInvisible = false
        self.lastFocusOrder = Int.max
        self.thumbnail = nil
        self.thumbnailCapturedAt = 0
    }

    /// 这个窗口是不是落在指定屏幕上(几何相交即算)。
    /// position/size 为 nil 时返回 true —— 给不出来的窗口(常见于最小化)
    /// 默认不限制,免得用户把它们误过滤掉。
    func isOnScreen(_ screen: NSScreen) -> Bool {
        guard let position, let size else { return true }
        // NSScreen.frame 是 Cocoa 坐标(y 朝上,原点左下)。
        // AX 给的 position 是 Quartz 坐标(y 朝下,原点左上,基于第一屏)。
        // 转换一下:把 screen.frame 翻成 Quartz 坐标。
        guard let primaryScreen = NSScreen.screens.first else { return true }
        var screenFrame = screen.frame
        screenFrame.origin.y = primaryScreen.frame.maxY - screenFrame.maxY
        let windowRect = CGRect(origin: position, size: size)
        return windowRect.intersects(screenFrame)
    }

    /// 当前是不是这个 app 的 hidden 状态(读自 NSRunningApplication 而不是 AX)。
    /// hidden 是 app 维度,不是窗口维度。
    var isAppHidden: Bool { application.isHidden }

    /// 这个窗口现在能给用户看吗?组合所有可见性维度的最终判定。
    /// 跟 ghost 检测的 isInvisible 是两个事:
    ///   - isInvisible:WindowServer 都不认它(我们检测到的)
    ///   - isAppHidden/isMinimized/isFullscreen:状态正常,用户配置决定要不要显示
    var isHiddenByState: Bool {
        isAppHidden || isMinimized
    }
}

// MARK: - AX 读取的纯函数辅助

enum SwitcherAxRead {
    /// AX 多属性一次读取 —— 比 N 次单读快很多。
    /// 在**后台线程**调,主线程会卡。
    static func multiAttributes(
        _ axUiElement: AXUIElement,
        _ keys: [String]
    ) -> [String: CFTypeRef] {
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            axUiElement,
            keys as CFArray,
            [],
            &values
        )
        guard result == .success, let array = values as? [CFTypeRef] else {
            return [:]
        }
        var dict = [String: CFTypeRef]()
        for (i, key) in keys.enumerated() where i < array.count {
            let v = array[i]
            // .axError 会被以 placeholder 形式返回,过滤掉
            if CFGetTypeID(v) == AXValueGetTypeID(),
               AXValueGetType(v as! AXValue) == .axError
            {
                continue
            }
            dict[key] = v
        }
        return dict
    }

    static func axValuePoint(_ ref: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let v = ref as! AXValue
        guard AXValueGetType(v) == .cgPoint else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(v, .cgPoint, &p)
        return p
    }

    static func axValueSize(_ ref: CFTypeRef) -> CGSize? {
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let v = ref as! AXValue
        guard AXValueGetType(v) == .cgSize else { return nil }
        var s = CGSize.zero
        AXValueGetValue(v, .cgSize, &s)
        return s
    }

    static func cgWindowId(of axUiElement: AXUIElement) -> CGWindowID? {
        var wid = CGWindowID(0)
        let result = _AXUIElementGetWindow(axUiElement, &wid)
        guard result == .success, wid != 0 else { return nil }
        return wid
    }

    /// AX 给空 / 给不出来时,从 CG 兜底拿一次。仍空就用 app 名。
    static func bestEffortTitle(
        axTitle: String?,
        cgTitle: String?,
        appLocalizedName: String?
    ) -> String {
        if let t = nonEmptyTitle(axTitle) { return t }
        if let t = nonEmptyTitle(cgTitle) { return t }
        return appLocalizedName ?? ""
    }

    static func cgTitle(for wid: CGWindowID) -> String? {
        let opts: CGWindowListOption = [.optionIncludingWindow]
        guard let arr = CGWindowListCopyWindowInfo(opts, wid) as? [[String: Any]] else {
            return nil
        }
        return arr.first?[kCGWindowName as String] as? String
    }

    private static func nonEmptyTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
}
