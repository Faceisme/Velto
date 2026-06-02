import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// State machine that handles the right-click drawn gesture lifecycle:
/// `idle → pending → gesturing → (match | cancel) → idle`.
///
/// Designed to be driven exclusively from the event-tap runloop thread.
/// Timers run as `CFRunLoopTimer`s scheduled on that same runloop so we
/// never have to cross-thread synchronize state during a gesture.
/// `@unchecked Sendable`:实例由 `EventTapManager` 持有并在 tap 线程上独占,
/// 仅在 `runGesture` 经 `DispatchQueue.main.async` 短暂触及 recognizer 缓存
/// (那也是单线程序列化的)。
final class GestureEngine: @unchecked Sendable {
    /// Snapshot of preferences fields the engine actually reads. Decoupled
    /// from `AppPreferences` so the engine doesn't pull in unrelated fields.
    struct PreferencesSnapshot {
        var showTrail: Bool
        var recognitionThreshold: Double
        var gestureTimeoutSeconds: Double
        var scribbleCancelEnabled: Bool
        var gestureTargetPolicy: GestureTargetPolicy

        init(from preferences: AppPreferences) {
            self.showTrail = preferences.showTrail
            self.recognitionThreshold = preferences.recognitionThreshold
            self.gestureTimeoutSeconds = preferences.gestureTimeoutSeconds
            self.scribbleCancelEnabled = preferences.scribbleCancelEnabled
            self.gestureTargetPolicy = preferences.gestureTargetPolicy
        }
    }

    private enum InputState {
        case idle
        case pending
        case gesturing
        case cleanupAwaitingUp
    }

    var onGestureMatch: (@Sendable (GestureMatch?) -> Void)?
    var onStatusChange: (@Sendable (String) -> Void)?

    // `GestureRecognizer` / `GestureOverlayController` 都是 `@MainActor`,不能作为
    // default value 在 `@unchecked Sendable` 类里求值,统一在 `init` body 里构造。
    private let recognizer: GestureRecognizer
    private let overlay: GestureOverlayController

    private var preferences: PreferencesSnapshot
    private var gestures: [GestureCommand] = []
    private var gesturesVersion: UInt64 = 0

    private var state: InputState = .idle
    private var points: [CGPoint] = []
    private var displayPoints: [CGPoint] = []
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var lastArmedLocation = CGPoint.zero

    // MARK: 乱划检测 (scribble-to-cancel)
    //
    // 把手势按"腿"(leg) 切分:从 `scribbleLegStart` 起累积直线位移,达到
    // `scribbleLegMinLength` 就定一条腿的方向,把它相对上一条腿的转角累加到
    // `scribbleTurnAccumulator`。来回甩每次反向 ≈180°、转圈圈每圈 =360°,两种
    // "乱划"都靠总转角统一识别;直线/折线的正常手势总转角很小(实测 ≤176°),
    // 离阈值很远。累积转角到 `scribbleTurnThreshold` 即判为取消。
    //
    // 注:不做"笔直腿放电"。平滑大圈每条腿只转几度,一旦按角度门槛把它当笔直腿
    // 放电,转再多圈也会被清零(这正是早期版本对画圈完全失效的根因)。直接全量
    // 累加转角,靠阈值与正常手势之间约 2.5× 的余量区分,实测最稳。
    private var scribbleLegStart = CGPoint.zero
    private var scribbleLastLegDirection: CGVector?
    private var scribbleTurnAccumulator: CGFloat = 0

    // MARK: 调试轨迹记录 (仅"调试模式"开启时记录,不改变手势行为)
    //
    // 每次手势开始读一次 `DebugLog.isEnabled` 定本次是否记录(`debugThisSession`),
    // 关闭时 begin/append/flush 全不触发,零额外缓冲开销。`debugReason` 记录本次
    // 手势的终止方式(乱划取消/超时/松手放行…),松手时连同完整轨迹写一条 JSONL。
    private var debugThisSession = false
    private var debugReason = ""
    private var debugTrace = GestureTraceRecorder()

    private var frontmostApplicationAtGestureStart: NSRunningApplication?
    private var lastFrontmostApplication: NSRunningApplication?

    private var gestureTimeoutTimer: CFRunLoopTimer?
    private var safetyTimer: CFRunLoopTimer?
    private weak var runLoopOwner: AnyObject?
    private var tapRunLoop: CFRunLoop?

    /// cancel 时 warp 过去的位置。mouseUp 时如果 release 位置和这里一致,就不再
    /// 重复 warp —— 避免连续两次 warp 把 events suppression interval 叠成 1-2s 卡顿。
    private var lastWarpedPosition: CGPoint?

    /// `CGWarpMouseCursorPosition` 默认会引入一段 "events suppression interval"
    /// (系统偏好里默认 0.25s,macOS 26 上实测更长),期间鼠标移动事件被静默丢弃,
    /// 用户感受是"光标卡在原地一两秒才跟手"。
    /// 原代码靠 `CGAssociateMouseAndMouseCursorPosition(1)` 取消,但在 macOS 26 上
    /// 这条路径不稳定,需要直接把进程内所有相关 source 的 suppression interval
    /// 设为 0(老的 `CGSetLocalEventsSuppressionInterval` 在 macOS 26 SDK 里已经
    /// 标 unavailable,只能用 per-source 接口)。用 `static let` 保证只配一次。
    private static let didDisableWarpSuppression: Bool = {
        for stateID: CGEventSourceStateID in [.hidSystemState, .combinedSessionState, .privateState] {
            CGEventSource(stateID: stateID)?.localEventsSuppressionInterval = 0
        }
        return true
    }()

    private let movementThreshold: CGFloat = 10
    private let minimumRecordedPointDistance: CGFloat = 2
    private let timeoutRearmDistance: CGFloat = 8
    private let maximumGesturePointCount = 512
    private let safetyTimeout: TimeInterval = 8

    /// 一条"腿"成立所需的最小直线位移。太小会被手抖/微漂噪声带偏方向判断,
    /// 太大则小圈切不出腿。10px 在实测里既滤抖又能逐段累积小圈的转角。
    private let scribbleLegMinLength: CGFloat = 10
    /// 累积转角达到此值即判为乱划/转圈取消。2π = 360° ≈ 转满一圈,或来回甩两下。
    /// 实测正常手势总转角 ≤176°,仍留约 2× 余量;转圈动作约半秒内即触发。
    private let scribbleTurnThreshold: CGFloat = 2 * .pi       // 360°

    /// 最近邻命令与次近邻命令的差异度余量门槛(`GestureDirection.distance`,命令层面
    /// —— 每个命令已压成一条规范方向序列)。两者差值小于此值时,手势被判为"卡在两个
    /// 命令之间"而拒绝执行。在方向序列方案下,这种情形几乎只剩"两个命令配了同一条
    /// 序列"的真冲突(设置页会在配置期就用箭头提示),清晰手势的命令间余量通常 ≥0.5。
    /// `match` 调试日志记录每次的 runnerUp/margin/ambiguous,便于据实测微调。
    private let ambiguityMargin: CGFloat = 0.05
    private let syntheticMarker: Int64 = 0x4D474C524550

    /// `@MainActor` — 内部要构造 `GestureRecognizer` / `GestureOverlayController`,
    /// 两者都是 `@MainActor`。调用方 (`EventTapManager.init`) 已经在 main actor 上。
    @MainActor
    init(preferences: AppPreferences, gestures: [GestureCommand], gesturesVersion: UInt64) {
        self.preferences = PreferencesSnapshot(from: preferences)
        self.gestures = gestures
        self.gesturesVersion = gesturesVersion
        self.lastFrontmostApplication = NSWorkspace.shared.frontmostApplication
        self.recognizer = GestureRecognizer()
        self.overlay = GestureOverlayController()
        // 触发一次性的 suppression interval 配置 —— 不取这个值就不会执行。
        _ = Self.didDisableWarpSuppression
    }

    /// Called once on the tap thread right after the runloop is up.
    func attach(runLoop: CFRunLoop) {
        tapRunLoop = runLoop
    }

    func detach() {
        invalidateTimer(&gestureTimeoutTimer)
        invalidateTimer(&safetyTimer)
        tapRunLoop = nil
        resetTracking()
    }

    func updatePreferences(_ preferences: AppPreferences) {
        self.preferences = PreferencesSnapshot(from: preferences)
    }

    func updateGestures(_ gestures: [GestureCommand], version: UInt64) {
        self.gestures = gestures
        self.gesturesVersion = version
    }

    func updateLastFrontmostApplication(_ application: NSRunningApplication) {
        if state == .idle {
            lastFrontmostApplication = application
        }
    }

    // MARK: - Tap callback entry points (called on tap thread)

    /// `true` if the engine is mid-gesture and should swallow the right-click
    /// event so the system menu doesn't pop up.
    var isHandlingRightMouse: Bool {
        state != .idle
    }

    /// tap 被系统禁用再重启时调用:被禁用期间发生的 `rightMouseUp` 会丢失,引擎若停在
    /// `.gesturing` / `.pending` 半路,之后每个新手势都会把它判为 abandoned、连环失灵。
    /// 这里强制收尾回到 idle(不执行任何手势)。tap 线程调用。
    func abortForTapRestart() {
        guard state != .idle else { return }
        if debugThisSession {
            debugTrace.flush(reason: "tapRestart")
            debugThisSession = false
        }
        resetTracking()
    }

    /// Returns whether the engine consumed the event. Tap thread.
    func handleRightMouseDown(at location: CGPoint) -> Bool {
        if state != .idle {
            if debugThisSession { debugTrace.flush(reason: "abandoned") }
            resetTracking()
        }

        debugThisSession = DebugLog.isEnabled
        if debugThisSession {
            debugReason = ""
            debugTrace.begin(at: location)
        }

        state = .pending
        frontmostApplicationAtGestureStart = lastFrontmostApplication ?? NSWorkspace.shared.frontmostApplication
        startPoint = location
        lastPoint = location
        points = [location]
        // displayPoints 仅在 showTrail 打开时维护,关闭时省掉每次 drag 的坐标换算
        // 和数组分配。手势进行中切换 showTrail 不会回填本次轨迹(低频边界)。
        displayPoints = preferences.showTrail
            ? [DisplayCoordinateConverter.eventLocationToOverlayPoint(location)]
            : []
        armSafetyTimer()
        return true
    }

    func handleRightMouseDragged(at location: CGPoint) -> Bool {
        if debugThisSession, state != .idle { debugTrace.append(at: location) }
        switch state {
        case .pending:
            _ = appendPoint(location)
            if distance(startPoint, location) >= movementThreshold {
                state = .gesturing
                armGestureTimeoutTimer()
                lastArmedLocation = location
                resetScribbleTracking(at: location)
                if preferences.showTrail {
                    overlay.show(points: displayPoints)
                }
            }
            return true

        case .gesturing:
            let appended = appendPoint(location)
            if appended {
                // Only re-arm the cancellation countdown when the cursor has
                // actually moved a meaningful distance since the last arm.
                // appendPoint accepts 2px movement (so the trail/recognizer
                // get smooth data), but using that same threshold to reset the
                // timeout means mouse tremor, micro-drift, or rapid phantom
                // drag events (macOS sometimes emits these while we're
                // suppressing right-mouse events) keep the countdown alive
                // forever — the user-configured timeout never elapses.
                if distance(lastArmedLocation, location) >= timeoutRearmDistance {
                    armGestureTimeoutTimer()
                    lastArmedLocation = location
                }
                if preferences.showTrail {
                    overlay.update(points: displayPoints)
                }
            }
            // 乱划检测吃原始拖动点(含 <2px 的微动累积),独立于轨迹采样。
            if preferences.scribbleCancelEnabled, updateScribbleDetection(at: location) {
                cancelGestureByScribble()
            }
            return true

        case .cleanupAwaitingUp:
            lastPoint = location
            return true

        case .idle:
            return false
        }
    }

    func handleRightMouseUp(at location: CGPoint) -> Bool {
        // 本次 release 轨迹的 seq —— 仅 .gesturing 才会进入匹配,把它带给 runGesture,
        // 让匹配判定日志与轨迹日志共享同一个 seq 互相对应。
        var debugSeq: Int?
        if debugThisSession, state != .idle {
            debugTrace.append(at: location)
            let reason: String
            switch state {
            case .pending: reason = "click"
            case .gesturing: reason = debugReason.isEmpty ? "release" : debugReason
            case .cleanupAwaitingUp: reason = debugReason.isEmpty ? "cancel" : debugReason
            case .idle: reason = "idle"
            }
            debugSeq = debugTrace.flush(reason: reason)
            debugThisSession = false
        }
        switch state {
        case .pending:
            let point = startPoint
            resetTracking()
            replayRightClickAsync(at: point)
            return true

        case .gesturing:
            _ = appendPoint(location)
            let capturedPoints = points
            let capturedTargetPoint = startPoint
            let capturedFrontmostApplication = frontmostApplicationAtGestureStart
            let capturedVersion = gesturesVersion
            let capturedGestures = gestures
            let capturedPreferences = preferences
            let capturedDebugSeq = debugSeq
            let releasePoint = location
            let gestureStart = startPoint
            resetTracking()

            // 把逻辑光标 warp 到松手处 —— 与 cancel / cleanupAwaitingUp 收尾一致。
            // 手势进行中我们在 HID tap 吞掉了 rightMouseDragged,视觉光标跟手走了,但
            // 窗口服务器的逻辑光标还停在 startPoint;手势一结束它就把视觉光标snap回那个
            // 旧位置 —— 用户看到的就是"卡一下又跳回起点"(手势越长跳得越远越明显)。这里
            // 主动 warp 到松手处并立即重新关联,配合 didDisableWarpSuppression 消除卡顿。
            // 目标窗口已按 capturedTargetPoint(=手势起点)解析,warp 不影响快捷键派发。
            if releasePoint != .zero, releasePoint != gestureStart {
                CGWarpMouseCursorPosition(releasePoint)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            lastWarpedPosition = nil

            Task { @MainActor [weak self] in
                self?.runGesture(
                    points: capturedPoints,
                    targetPoint: capturedTargetPoint,
                    frontmostApplicationAtGestureStart: capturedFrontmostApplication,
                    gestures: capturedGestures,
                    gesturesVersion: capturedVersion,
                    preferences: capturedPreferences,
                    debugSeq: capturedDebugSeq
                )
            }
            return true

        case .cleanupAwaitingUp:
            let releasePoint = lastPoint
            resetTracking()
            // The user may have moved more after cancellation while still
            // holding the button — same logical/visual divergence accrues
            // during the cleanup window. Resync once on release so the next
            // mouseMoved event doesn't snap the cursor to a stale position.
            // 但要避开 cancel 时已经 warp 过同一个位置的 no-op warp:连续两次
            // warp 即使 suppression interval = 0 也是无谓 syscall,而且如果哪天
            // suppression 又被系统加回来,redundant warp 会直接卡 1-2s。
            if releasePoint != .zero, releasePoint != lastWarpedPosition {
                CGWarpMouseCursorPosition(releasePoint)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            lastWarpedPosition = nil
            return true

        case .idle:
            return false
        }
    }

    // MARK: - Gesture matching (main actor only)

    /// 匹配 + 执行链路全部在主线程上跑。`recognizer` 是 `@MainActor`,target
    /// 解析里有可能要查 AX(同步耗时操作),通过 `Task.detached` 跑后台 + Task
    /// `@MainActor` 回主线程发送快捷键。
    @MainActor
    private func runGesture(
        points: [CGPoint],
        targetPoint: CGPoint,
        frontmostApplicationAtGestureStart: NSRunningApplication?,
        gestures: [GestureCommand],
        gesturesVersion: UInt64,
        preferences: PreferencesSnapshot,
        debugSeq: Int?
    ) {
        let threshold = CGFloat(preferences.recognitionThreshold)
        let candidates = recognizer.bestCandidates(points: points, commands: gestures, version: gesturesVersion)
        let best = candidates?.best
        let runnerUp = candidates?.runnerUpDistance

        // 余量判据:次近 - 最近 < ambiguityMargin 即判为"模糊手势"。只有一个候选
        // (runnerUp 为 nil)时不存在歧义。命中要求:差异度 ≤ 阈值 且 不模糊。
        let margin = best.flatMap { b in runnerUp.map { $0 - b.distance } }
        let ambiguous = margin.map { $0 < ambiguityMargin } ?? false
        let match = best.flatMap { ($0.distance <= threshold && !ambiguous) ? $0 : nil }

        // 与同 seq 的 `gesture` 轨迹日志对应:记录最近邻命令、距离、次近距离、余量、
        // 阈值、是否模糊与是否命中。`best` 为 nil 表示轨迹太短/无法归一化,没参与
        // 匹配;`ambiguous=true & hit=false` 表示卡在两命令之间被余量判据拦下。
        // 缺省值用 -1 占位。`DebugLog.event` 内部再判一次开关,关掉即不写。
        if let debugSeq {
            // `drawn` = 本次画出来的签名(方向 + 弧向);`bestSeq` = 最近邻命令的规范签名。
            // 两者并排,一眼就能看出"画成了什么 / 该命中谁",取代旧版只能看浮点距离。
            let candidate = GestureDirection.signature(from: points)
            let drawn = GestureDirection.arrows(candidate.sequence) + GestureDirection.bowGlyph(candidate.bowSign)
            let bestSeq = best.map { match -> String in
                let sig = recognizer.canonicalSignature(for: match.command)
                return GestureDirection.arrows(sig.sequence) + GestureDirection.bowGlyph(sig.bowSign)
            } ?? ""
            DebugLog.event("match", [
                "seq": debugSeq,
                "drawn": drawn,
                "best": best?.command.name ?? "<无候选>",
                "bestSeq": bestSeq,
                "shortcut": best?.command.shortcut?.displayName ?? "",
                "distance": best.map { Double($0.distance) } ?? -1,
                "runnerUp": runnerUp.map { Double($0) } ?? -1,
                "margin": margin.map { Double($0) } ?? -1,
                "threshold": Double(threshold),
                "ambiguous": ambiguous,
                "hit": match != nil
            ])
        }

        onGestureMatch?(match)

        if let match {
            guard let shortcut = match.command.shortcut else { return }
            resolveTargetAndExecute(
                shortcut: shortcut,
                targetPoint: targetPoint,
                policy: preferences.gestureTargetPolicy,
                frontmostApplicationAtGestureStart: frontmostApplicationAtGestureStart
            )
        }
    }

    @MainActor
    private func resolveTargetAndExecute(
        shortcut: Shortcut,
        targetPoint: CGPoint,
        policy: GestureTargetPolicy,
        frontmostApplicationAtGestureStart: NSRunningApplication?
    ) {
        switch policy {
        case .activeWindow:
            let target = GestureTargetController.executionTarget(
                at: targetPoint,
                policy: policy,
                frontmostApplicationAtGestureStart: frontmostApplicationAtGestureStart
            )
            executeMatchedGesture(
                shortcut: shortcut,
                target: target,
                frontmostApplicationAtGestureStart: frontmostApplicationAtGestureStart
            )

        case .windowUnderPointer:
            // AX 查找可能阻塞,在 detached task 上跑,完成后切回主线程。
            Task.detached(priority: .userInitiated) { [weak self] in
                let target = GestureTargetController.executionTarget(
                    at: targetPoint,
                    policy: policy,
                    frontmostApplicationAtGestureStart: nil
                )
                await MainActor.run {
                    self?.executeMatchedGesture(
                        shortcut: shortcut,
                        target: target,
                        frontmostApplicationAtGestureStart: frontmostApplicationAtGestureStart
                    )
                }
            }
        }
    }

    @MainActor
    private func executeMatchedGesture(
        shortcut: Shortcut,
        target: GestureExecutionTarget,
        frontmostApplicationAtGestureStart: NSRunningApplication?
    ) {
        GestureTargetController.prepareForExecution(target)

        // 等目标 App 完成激活后再发送快捷键 / 关窗。两段 sleep 都跑在 main actor 上,
        // 因为 `restoreFrontmostApplication` 走 `NSRunningApplication.activate`
        // (`@MainActor`)。
        let delay = target.deliveryDelay
        let restoresOriginalFrontmostApplication = target.restoresOriginalFrontmostApplication
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))

            if restoresOriginalFrontmostApplication {
                GestureTargetController.restoreFrontmostApplication(frontmostApplicationAtGestureStart)
            }

            if GestureTargetController.performDirectWindowCloseIfAvailable(for: target, shortcut: shortcut) {
                return
            }

            ShortcutSynthesizer.send(shortcut)

            if restoresOriginalFrontmostApplication {
                try? await Task.sleep(for: .milliseconds(120))
                GestureTargetController.restoreFrontmostApplication(frontmostApplicationAtGestureStart)
            }
        }
    }

    // MARK: - Right-click replay

    private func replayRightClickAsync(at point: CGPoint) {
        DispatchQueue.global(qos: .userInteractive).async { [marker = syntheticMarker] in
            guard let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .rightMouseDown,
                mouseCursorPosition: point,
                mouseButton: .right
            ), let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .rightMouseUp,
                mouseCursorPosition: point,
                mouseButton: .right
            ) else { return }
            down.setIntegerValueField(.eventSourceUserData, value: marker)
            up.setIntegerValueField(.eventSourceUserData, value: marker)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    /// Mark indicating events we synthesized ourselves so the tap can let them
    /// pass through without re-entering gesture logic.
    var rightClickSyntheticMarker: Int64 { syntheticMarker }

    // MARK: - Point buffer

    @discardableResult
    private func appendPoint(_ point: CGPoint) -> Bool {
        lastPoint = point
        let recordTrail = preferences.showTrail
        guard let previous = points.last else {
            points = [point]
            displayPoints = recordTrail
                ? [DisplayCoordinateConverter.eventLocationToOverlayPoint(point)]
                : []
            return true
        }

        guard distance(previous, point) >= minimumRecordedPointDistance else {
            return false
        }

        if points.count >= maximumGesturePointCount {
            points[points.count - 1] = point
            if recordTrail, !displayPoints.isEmpty {
                displayPoints[displayPoints.count - 1] = DisplayCoordinateConverter.eventLocationToOverlayPoint(point)
            }
        } else {
            points.append(point)
            if recordTrail {
                displayPoints.append(DisplayCoordinateConverter.eventLocationToOverlayPoint(point))
            }
        }
        return true
    }

    // MARK: - State reset

    private func resetTracking() {
        state = .idle
        gestureTimeoutTimer.map { CFRunLoopTimerSetNextFireDate($0, .greatestFiniteMagnitude) }
        safetyTimer.map { CFRunLoopTimerSetNextFireDate($0, .greatestFiniteMagnitude) }
        points = []
        displayPoints = []
        frontmostApplicationAtGestureStart = nil
        startPoint = .zero
        lastPoint = .zero
        lastArmedLocation = .zero
        resetScribbleTracking(at: .zero)
        overlay.hide()
    }

    // MARK: - 乱划检测

    private func resetScribbleTracking(at location: CGPoint) {
        scribbleLegStart = location
        scribbleLastLegDirection = nil
        scribbleTurnAccumulator = 0
    }

    /// 喂入一个拖动点。返回 `true` 表示本次手势已判定为乱划/转圈,调用方应取消。
    private func updateScribbleDetection(at location: CGPoint) -> Bool {
        let dx = location.x - scribbleLegStart.x
        let dy = location.y - scribbleLegStart.y
        let legLength = hypot(dx, dy)
        // 位移还不够一条腿,继续累积,方向待定。
        guard legLength >= scribbleLegMinLength else { return false }

        let direction = CGVector(dx: dx / legLength, dy: dy / legLength)
        defer {
            scribbleLastLegDirection = direction
            scribbleLegStart = location
        }

        // 第一条腿没有参照方向,只记录不判定。
        guard let previous = scribbleLastLegDirection else { return false }

        // 两条腿夹角(无向, 0...π),全量累加:来回甩每次 ≈π,转圈每段是稳定
        // 的小转角,都老老实实攒进去。
        let dot = max(-1, min(1, previous.dx * direction.dx + previous.dy * direction.dy))
        scribbleTurnAccumulator += acos(dot)
        return scribbleTurnAccumulator >= scribbleTurnThreshold
    }

    /// 在 tap 线程上调用 —— 和超时取消同一条收尾链路。
    private func cancelGestureByScribble() {
        if debugThisSession { debugReason = "scribbleCancel" }
        cancelGestureAndWaitForRightMouseUp()
        onGestureMatch?(nil)
        onStatusChange?("本次手势已取消")
    }

    private func cancelGestureAndWaitForRightMouseUp() {
        let endPosition = lastPoint

        state = .cleanupAwaitingUp
        gestureTimeoutTimer.map { CFRunLoopTimerSetNextFireDate($0, .greatestFiniteMagnitude) }
        safetyTimer.map { CFRunLoopTimerSetNextFireDate($0, .greatestFiniteMagnitude) }
        points = []
        displayPoints = []
        frontmostApplicationAtGestureStart = nil
        overlay.hide()

        // While we were suppressing rightMouseDragged at the HID tap, the
        // on-screen cursor (driven by HID) tracked the actual mouse but the
        // window server's logical cursor position stayed at startPoint. The
        // instant we let the gesture lifecycle wind down, the window server
        // snaps the visual cursor back to that stale logical position. Warp
        // the logical position to where the user actually is so the snap
        // doesn't happen. Re-associate immediately to avoid the cursor freeze
        // that CGWarpMouseCursorPosition can otherwise introduce —— 配合
        // `didDisableWarpSuppression` 把 suppression interval 设为 0,
        // 两层防线共同消除"光标卡 1-2 秒"。
        if endPosition != .zero, endPosition != startPoint {
            CGWarpMouseCursorPosition(endPosition)
            CGAssociateMouseAndMouseCursorPosition(1)
            lastWarpedPosition = endPosition
        } else {
            lastWarpedPosition = nil
        }
    }

    // MARK: - Timers (CFRunLoopTimer on tap runloop)

    private func armSafetyTimer() {
        let timeout = max(safetyTimeout, preferences.gestureTimeoutSeconds + 2)
        let nextFire = CFAbsoluteTimeGetCurrent() + timeout

        if let timer = safetyTimer {
            CFRunLoopTimerSetNextFireDate(timer, nextFire)
            return
        }
        safetyTimer = makeTimer(fireDate: nextFire) { [weak self] in
            self?.fireSafetyTimer()
        }
    }

    private func armGestureTimeoutTimer() {
        let timeout = max(0.5, preferences.gestureTimeoutSeconds)
        let nextFire = CFAbsoluteTimeGetCurrent() + timeout

        if let timer = gestureTimeoutTimer {
            CFRunLoopTimerSetNextFireDate(timer, nextFire)
            return
        }
        gestureTimeoutTimer = makeTimer(fireDate: nextFire) { [weak self] in
            self?.fireGestureTimeoutTimer()
        }
    }

    private func fireSafetyTimer() {
        guard state != .idle else { return }
        if debugThisSession { debugReason = "safetyCancel" }
        cancelGestureAndWaitForRightMouseUp()
    }

    private func fireGestureTimeoutTimer() {
        guard state == .gesturing else { return }
        if debugThisSession { debugReason = "timeoutCancel" }
        cancelGestureAndWaitForRightMouseUp()
        // callback 是 `@Sendable`,从 tap runloop 直接调用即可,
        // 调用方 (AppDelegate) 自己把 UI 更新 hop 到 main actor。
        onGestureMatch?(nil)
        onStatusChange?("本次手势超时,已取消")
    }

    private func makeTimer(fireDate: CFAbsoluteTime, handler: @escaping () -> Void) -> CFRunLoopTimer? {
        guard let runLoop = tapRunLoop else { return nil }

        let box = Unmanaged.passRetained(TimerBox(handler: handler)).toOpaque()
        var context = CFRunLoopTimerContext(
            version: 0,
            info: box,
            retain: { ptr in
                guard let ptr else { return nil }
                _ = Unmanaged<TimerBox>.fromOpaque(ptr).retain()
                return ptr
            },
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<TimerBox>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            fireDate,
            // CFRunLoopTimerCreate auto-invalidates the timer on first fire if
            // interval is 0, after which CFRunLoopTimerSetNextFireDate becomes
            // a no-op. Use a large interval so the timer stays valid; we drive
            // all firing manually via SetNextFireDate.
            .greatestFiniteMagnitude,
            0,
            0,
            { _, info in
                guard let info else { return }
                let box = Unmanaged<TimerBox>.fromOpaque(info).takeUnretainedValue()
                box.handler()
            },
            &context
        )

        // CFRunLoopTimerContext.retain was invoked by CFRunLoopTimerCreate; release
        // our own +1 here so the box is only retained by the timer itself.
        Unmanaged<TimerBox>.fromOpaque(box).release()

        if let timer {
            CFRunLoopAddTimer(runLoop, timer, .commonModes)
        }
        return timer
    }

    private func invalidateTimer(_ timer: inout CFRunLoopTimer?) {
        if let timer {
            CFRunLoopTimerInvalidate(timer)
        }
        timer = nil
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

private final class TimerBox {
    let handler: () -> Void
    init(handler: @escaping () -> Void) {
        self.handler = handler
    }
}

/// 手势轨迹调试记录器(仅"调试模式"开启时被 `GestureEngine` 喂数据)。一次手势
/// (按下→松开)攒一条记录,松手时经 `DebugLog` 落一行 JSONL:含相对毫秒时间戳的
/// 原始轨迹点 `pts:[[t,x,y],…]`、点数与终止原因 `reason`。坐标取整以压缩体积。
private struct GestureTraceRecorder {
    private var start: CFAbsoluteTime = 0
    private var samples: [[Int]] = []
    private var seq = 0
    private let maxSamples = 6000

    mutating func begin(at p: CGPoint) {
        start = CFAbsoluteTimeGetCurrent()
        samples = [[0, Int(p.x.rounded()), Int(p.y.rounded())]]
    }

    mutating func append(at p: CGPoint) {
        guard samples.count < maxSamples else { return }
        let t = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        samples.append([t, Int(p.x.rounded()), Int(p.y.rounded())])
    }

    /// 返回本条轨迹的 `seq`,供调用方把同 `seq` 的匹配判定日志关联上;无样本时返回 `nil`。
    @discardableResult
    mutating func flush(reason: String) -> Int? {
        guard !samples.isEmpty else { return nil }
        seq += 1
        DebugLog.event("gesture", [
            "seq": seq,
            "reason": reason,
            "durationMs": samples.last?.first ?? 0,
            "count": samples.count,
            "pts": samples
        ])
        samples = []
        return seq
    }
}
