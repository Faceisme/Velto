import ApplicationServices
import Cocoa

/// 把指定的窗口"切到前面"。这是切换器存在的意义 —— 公开 AppKit 只能激活 app
/// (NSRunningApplication.activate),没有"激活某 app 的特定窗口"的 API。
///
/// 实现路径有两条互补的:
///
/// 1. **私有 SLPS 字节流**:`_SLPSSetFrontProcessWithOptions` 让目标进程变 front,
///    然后投递一段精心构造的字节流让指定 wid 成为该进程的 key window。
///    这是从 Hammerspoon 反编译出来的魔法序列(见下面 `makeKeyWindow`)。
///
/// 2. **AX kAXRaiseAction** 作为兜底:即使私有 API 失效,标准 AX 至少能把窗口
///    抬到当前 app 的最前(但解决不了"切 app"的问题)。
///
/// 两条一起用,缺一个都不完整:私有 API 切 app + AX raise 抬窗口。
///
/// **必须从后台线程调** —— 这两个 API 都做跨进程 IPC,主线程会卡。
enum SwitcherFocus {
    /// 把这个窗口切到前台。线程要求:**后台线程**。内部不返回结果,失败默默
    /// 跳过(失败的话窗口压根没变,UI 会重新弹出来,用户重试一次就好)。
    nonisolated static func raise(window: SwitcherWindow) {
        // 路径 1:在某些场景下我们不应该用 SLPS —— 比如自己的 app(避免把自己
        // 当前焦点弄丢),或者窗口属于 windowless app(我们 P1 不处理)。
        // P1 阶段两个都不命中,留个 hook。
        AXCallQueue.shared.submitFocus {
            raiseUnsafe(
                pid: window.application.pid,
                cgWindowId: window.cgWindowId,
                axBox: SwitcherAxRefBox(element: window.axUiElement)
            )
        }
    }

    /// **只走 WindowServer** 把某个 wid 变成前台 key window —— 一次 AX 调用都不做。
    ///
    /// 除了切换器,手势路径也要用:AX 熔断期 `axWindow(matching:)` 直接返回 nil,
    /// 手上只剩 CGWindowList 那个 wid,而 `NSRunningApplication.activate` 只能
    /// 激活 app、选不中具体窗口 —— 观感就是「窗口上来了却没被选中」。SLPS 这两步
    /// 只跟 WindowServer 说话,不碰目标 app 的主线程,正好绕开熔断要躲的那笔开销。
    ///
    /// 与 `raise(window:)` 不同,这个是**同步**的:手势调完紧接着就要发快捷键,
    /// 异步排队会让按键先于 key window 落地。
    nonisolated static func raiseByWindowServer(pid: pid_t, cgWindowId: CGWindowID) {
        // 拿目标进程的 PSN(ProcessSerialNumber)—— 老式 Carbon 概念,但 SLPS 要这个。
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return }

        // 第一步:让目标进程在 WindowServer 心里变成 front process,并且告诉它
        // 当前活跃的是这个 wid(而不是该 app 上次激活的那个)
        _SLPSSetFrontProcessWithOptions(&psn, cgWindowId, SLPSMode.userGenerated.rawValue)

        // 第二步:投递魔法字节流,让指定 wid 成为该进程的 key window。
        // 不投递这步的话,WindowServer 会把"该 app 上次激活的窗口"重新拉回来
        // (比如 System Preferences 跨 Space 切的时候必现)
        makeKeyWindow(psn: &psn, cgWindowId: cgWindowId)
    }

    /// 实际干活的函数,必须在后台线程。
    private static func raiseUnsafe(pid: pid_t, cgWindowId: CGWindowID, axBox: SwitcherAxRefBox) {
        raiseByWindowServer(pid: pid, cgWindowId: cgWindowId)

        // 第三步:AX kAXRaiseAction 兜底,把窗口抬到该 app 内部的最顶层。
        // 单独这一步只能"在当前 app 里调换窗口",切不了 app —— 必须跟前两步配合。
        // 拿不到 PSN 时前两步会静默跳过,这一步就是唯一的退路。
        try? performAxRaise(axBox.element)
    }

    /// 这段字节流来源:https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
    ///
    /// 248 字节的缓冲区,几个 magic offset 决定 WindowServer 怎么解释这条事件:
    ///   - byte 0x04 = 0xf8 → 数据包总长度
    ///   - byte 0x3a = 0x10 → 类型标识
    ///   - byte 0x3c..0x40 → 目标 wid(4 字节小端)
    ///   - byte 0x20..0x30 → 全 0xff 填充(权限位之类的)
    ///   - byte 0x08 = 0x01 或 0x02 → 决定"标记 key" / "应用 key" 两阶段
    ///
    /// 投递两次,第一次 0x01 通知"我要把这个变 key",第二次 0x02 提交。
    /// 顺序反了或漏掉一次,key 状态都不会真正生效。
    ///
    /// 这是不公开协议,Apple 任何 macOS 版本都可能改。如果有一天用户反馈
    /// "切窗口偶尔切到错的那个",大概率是这套字节布局变了 —— 第一步看 alt-tab
    /// 仓库 issue 区,大概率有人遇到了同样的问题。
    private static func makeKeyWindow(psn: UnsafeMutablePointer<ProcessSerialNumber>, cgWindowId: CGWindowID) {
        var wid = cgWindowId
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: &wid) { widBytes in
            for i in 0..<MemoryLayout<CGWindowID>.size {
                bytes[0x3c + i] = widBytes[i]
            }
        }
        // 0x20..0x30 填 0xff
        for i in 0x20..<0x30 {
            bytes[i] = 0xff
        }
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { ptr in
            SLPSPostEventRecordTo(psn, ptr.baseAddress!)
        }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { ptr in
            SLPSPostEventRecordTo(psn, ptr.baseAddress!)
        }
    }

    private static func performAxRaise(_ axUiElement: AXUIElement) throws {
        let result = AXUIElementPerformAction(axUiElement, kAXRaiseAction as CFString)
        try axThrowIfNotSuccess(result)
    }
}
