import Cocoa
import Synchronization

/// 封装所有 SkyLight 的 Space / 窗口可见性查询。
///
/// 这些 API 都是同步阻塞 + 跨进程 IPC,**不能在主线程频繁调** —— 列出所有
/// space 是廉价的(几 ms),列出所有 wid 是较重的(可能 10+ ms,空闲下来才调)。
enum SwitcherSpaces {
    /// 当前所有 Space 的 id 列表(已排序,index 即 Mission Control 里的序号)。
    static func allSpaceIds() -> [CGSSpaceID] {
        guard let displays = CGSCopyManagedDisplaySpaces(CGS_CONNECTION) as? [[String: Any]] else {
            return []
        }
        var ids: [CGSSpaceID] = []
        for display in displays {
            if let spaces = display["Spaces"] as? [[String: Any]] {
                for space in spaces {
                    if let id = space["id64"] as? CGSSpaceID {
                        ids.append(id)
                    }
                }
            }
        }
        return ids
    }

    /// 当前每个屏幕上"露出来的那个 Space"的 id 集合。
    static func visibleSpaceIds() -> Set<CGSSpaceID> {
        guard let displays = CGSCopyManagedDisplaySpaces(CGS_CONNECTION) as? [[String: Any]] else {
            return []
        }
        var ids = Set<CGSSpaceID>()
        for display in displays {
            if let current = display["Current Space"] as? [String: Any],
               let id = current["id64"] as? CGSSpaceID
            {
                ids.insert(id)
            }
        }
        return ids
    }

    /// 给一组 wid,返回每个 wid 所属的 Space id 数组。
    /// 空数组意味着 WindowServer 不认这个 wid 在任何 Space 上 —— 强 ghost 信号。
    ///
    /// 实现注解:**不能** `CGSCopySpacesForWindows(... wids ...)` 一次性传一堆
    /// wid 然后期待返回 `[[CGSSpaceID]]`。实测它返回一维 CFArray,跟 alt-tab
    /// 源码注释一致:"queries one space at a time and inverts the result"。
    /// 所以这里改成反向遍历:对每个 Space 问"它里头有哪些 wid",再反转成 map。
    /// N 个窗口 × M 个 Space → 从 N 次 IPC 缩到 M 次,再由下面的缓存缩到"每
    /// 200ms M 次"。
    static func spaces(forWindowIds wids: [CGWindowID]) -> [CGWindowID: [CGSSpaceID]] {
        guard !wids.isEmpty else { return [:] }
        let wanted = Set(wids)
        var map = [CGWindowID: [CGSSpaceID]]()
        for (spaceId, spaceWids) in windowsBySpaceCached() {
            for wid in wanted where spaceWids.contains(wid) {
                map[wid, default: []].append(spaceId)
            }
        }
        return map
    }

    private struct SpaceWindows: Sendable {
        let stamp: CFAbsoluteTime
        let bySpace: [CGSSpaceID: Set<CGWindowID>]
    }

    private static let spaceWindowsTTL: CFAbsoluteTime = 0.2
    private static let spaceWindowsCache = Mutex<SpaceWindows?>(nil)

    /// 每个 Space 上的全部 wid(含 invisible 桶),带 200ms TTL。
    ///
    /// 为什么要缓存:sync 路径**每扫完一个 app 就调一次** `spaces(forWindowIds:)`,
    /// 而它要按 Space 逐个问 CGS —— 启动时是 N 个 app × M 个 Space 次 IPC,问到的
    /// 却是同一份映射(12 个 app / 4 个 Space = 48 次)。全排在 AX 队列上就是纯等。
    ///
    /// TTL 取 200ms:远短于用户切 Space 的反应时间,又够覆盖一轮 sync。真拿到过期
    /// 映射,最坏也只是把刚挪走的窗口仍算在原 Space —— ghost 判定第 4 步的结论
    /// 不变(照样"在别的 Space,不是 ghost"),后续 sync 会接着对账。
    ///
    /// ponytail: 惊群没管 —— 并发线程同时 miss 会各做一轮 IPC。锁外做 IPC 是故意
    /// 的(单次可能 10+ms,占着锁会把并发的 AX 队列线程全堵住),几轮也远少于 N 轮。
    private static func windowsBySpaceCached() -> [CGSSpaceID: Set<CGWindowID>] {
        let now = CFAbsoluteTimeGetCurrent()
        if let hit = spaceWindowsCache.withLock({ $0 }), now - hit.stamp < spaceWindowsTTL {
            return hit.bySpace
        }
        var fresh = [CGSSpaceID: Set<CGWindowID>]()
        for spaceId in allSpaceIds() {
            // 包含 invisible 桶 —— 我们想知道 ghost 候选到底有没有 Space 归属
            fresh[spaceId] = Set(windowsInSpaces([spaceId], includeInvisible: true))
        }
        spaceWindowsCache.withLock { $0 = SpaceWindows(stamp: now, bySpace: fresh) }
        return fresh
    }

    /// 给定一组 Space,列出这些 Space 上所有 wid。
    /// `includeInvisible`:打开后 ghost 窗口也会出现在结果里 —— 我们用这个差集
    /// 来分辨"窗口存在但不可见" vs "窗口压根不存在"。
    static func windowsInSpaces(_ spaceIds: [CGSSpaceID], includeInvisible: Bool) -> [CGWindowID] {
        guard !spaceIds.isEmpty else { return [] }
        let spaceArray = spaceIds as CFArray
        var setTags = 0
        var clearTags = 0
        let options: CGSCopyWindowsOptions = includeInvisible
            ? [.invisible1, .invisible2, .screenSaverLevel1000]
            : [.screenSaverLevel1000]
        let result = CGSCopyWindowsWithOptionsAndTags(
            CGS_CONNECTION,
            0,
            spaceArray,
            options.rawValue,
            &setTags,
            &clearTags
        )
        return (result as? [CGWindowID]) ?? []
    }
}

// MARK: - Ghost 检测 / Electron 隐藏窗口的关键代码

/// 我们对单个窗口可见性的判定结论。
struct WindowVisibilityProbe: Sendable {
    /// WindowServer 视角下"可见"的 wid 集合(visible bucket)
    let visibleWids: Set<CGWindowID>
    /// WindowServer 视角下**全部认识**的 wid 集合(visible + invisible 桶)
    let allWids: Set<CGWindowID>
}

enum SwitcherGhostDetector {
    /// 在**后台线程**调,做完一次完整的 CGS 双查,返回探针结果给主线程对比。
    static func probe(across spaceIds: [CGSSpaceID]) -> WindowVisibilityProbe {
        let visible = Set(SwitcherSpaces.windowsInSpaces(spaceIds, includeInvisible: false))
        let all = Set(SwitcherSpaces.windowsInSpaces(spaceIds, includeInvisible: true))
        return WindowVisibilityProbe(visibleWids: visible, allWids: all)
    }

    /// 给一个窗口的当前状态 + 探针,判定 isInvisible。
    /// 这是 ghost 检测的全部逻辑,源自 alt-tab `Applications.computeIsInvisible`,
    /// **这里是 Electron `show:false` / `BrowserWindow.hide()` 修复的核心。**
    ///
    /// 判定顺序很重要,改之前先看完所有分支:
    ///   1. wid 完全不在 CGS 任何桶 → 100% ghost(典型:Joplin / Sprig /
    ///      Electron show:false)。这是最强信号。
    ///   2. wid 在 visible 桶 → 不是 ghost。
    ///   3. 窗口处于 minimized / app hidden / tabbed → 合法的"看不到"
    ///      (Cmd+H、最小化、tab group 后面的 tab),不算 ghost。
    ///   4. 窗口报告自己有 spaceIds 但**没一个跟当前可见 Space 重叠** →
    ///      合法的"在其他 Space",不算 ghost。
    ///   5. **当前聚焦的窗口** → 不算 ghost。Electron app(Slack / Telegram)从
    ///      Dock 唤回后窗口已经在屏且聚焦了,CGS 还会继续给它打 invisible 标记
    ///      好几秒 —— 正好是用户点完 Dock 想 ⌥Tab 回去的那几秒(alt-tab #5849)。
    ///      注意位置:必须在第 1 步**之后** —— CGS 完全不认这个 wid 是最强信号,
    ///      聚焦态不能推翻它,只能推翻第 6 步那个弱信号。
    ///   6. 都不符合 → 还是 ghost(典型:Outlook 提醒 alpha=0、某些 Electron
    ///      app 用 `setIgnoreMouseEvents` 弄出来的 overlay)
    static func isInvisible(
        wid: CGWindowID,
        isMinimized: Bool,
        isAppHidden: Bool,
        isTabbed: Bool,
        isFocused: Bool,
        windowSpaceIds: [CGSSpaceID],
        visibleSpaceIds: Set<CGSSpaceID>,
        probe: WindowVisibilityProbe
    ) -> Bool {
        // 1. CGS 完全不认这个 wid:Electron 隐藏窗口 / show:false 的最强信号
        if !probe.allWids.contains(wid) { return true }
        // 2. 在 visible 桶 → 必定可见
        if probe.visibleWids.contains(wid) { return false }
        // 3. 合法的"看不到":系统 minimize / Cmd+H / tabbed
        if isMinimized || isAppHidden || isTabbed { return false }
        // 4. 在别的 Space 上(但 CGS 还认它),这是合法的跨 Space 窗口
        if !windowSpaceIds.isEmpty,
           !windowSpaceIds.contains(where: { visibleSpaceIds.contains($0) })
        {
            return false
        }
        // 5. 用户此刻正看着它 —— CGS 的 invisible 标记还没跟上,信它不信标记
        if isFocused { return false }
        // 6. 都不符合 → ghost
        return true
    }
}
