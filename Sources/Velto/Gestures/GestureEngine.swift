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

    /// 逻辑光标已知同步到的位置。手势期间每个 rightMouseDragged 都被 HID tap
    /// 降级成 mouseMoved 投递(见 EventTapManager),窗口服务器的逻辑光标一路
    /// 跟手,投递即同步;收尾兜底 warp 也会更新它。收尾时位置一致就跳过 warp
    /// —— 冗余 warp 即使无害也是无谓 syscall,真撞上 suppression 还会卡 1-2s。
    private var lastSyncedCursorPosition: CGPoint?

    /// `CGWarpMouseCursorPosition` 默认会引入一段 "events suppression interval"
    /// (系统偏好里默认 0.25s,macOS 26 上实测更长),期间鼠标移动事件被静默丢弃,
    /// 用户感受是"光标卡在原地一两秒才跟手"。
    /// 注意:2026-06 水位计实测,这里设的 0 从未存住(`logWarpDiagnostics` 回读
    /// suppression 恒为 0.25)—— 临时 CGEventSource 实例上的配置不影响系统状态表。
    /// 真正抵消 suppression 的是每次 warp 后紧跟的
    /// `CGAssociateMouseAndMouseCursorPosition(1)`;此处保留只作 best-effort。
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
        lastSyncedCursorPosition = nil
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
            lastSyncedCursorPosition = location
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
            lastSyncedCursorPosition = location
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
            lastSyncedCursorPosition = location
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
            lastSyncedCursorPosition = nil
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

            // 收尾兜底 warp。手势期间 drag 已降级成 mouseMoved 投递,逻辑光标
            // 一路跟手,正常路径下 releasePoint 就是最后一个已投递位置,这里整段
            // 跳过;仅在"up 自带未经 drag 投递的新坐标"等错位边角才真 warp,并
            // 立即重新关联 —— warp 自带的事件抑制窗会把光标卡住(实测恒 0.25s,
            // didDisableWarpSuppression 并未真正生效,associate(1) 才是解药)。
            // 目标窗口已按 capturedTargetPoint(=手势起点)解析,warp 不影响快捷键派发。
            if releasePoint != .zero, !isCursorSynced(to: releasePoint) {
                CGWarpMouseCursorPosition(releasePoint)
                CGAssociateMouseAndMouseCursorPosition(1)
                logWarpDiagnostics(reason: "release", from: gestureStart, to: releasePoint)
            }
            lastSyncedCursorPosition = nil

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
            // cleanup 窗口内的 drag 同样以 mouseMoved 投递,逻辑光标持续跟手,
            // 正常路径下 releasePoint 与 lastSyncedCursorPosition 一致、跳过
            // warp,仅在 up 自带新坐标等错位场景兜底。去重不能省:冗余 warp 即使
            // suppression interval = 0 也是无谓 syscall,真撞上 suppression
            // (实测恒 0.25s)会直接卡 1-2s。
            if releasePoint != .zero, !isCursorSynced(to: releasePoint) {
                CGWarpMouseCursorPosition(releasePoint)
                CGAssociateMouseAndMouseCursorPosition(1)
                logWarpDiagnostics(reason: "cleanupUp", from: lastSyncedCursorPosition ?? .zero, to: releasePoint)
            }
            lastSyncedCursorPosition = nil
            return true

        case .idle:
            return false
        }
    }

    // MARK: - Gesture matching (main actor only)

    /// 匹配 + 执行链路全部在主线程上跑。`recognizer` 是 `@MainActor`,target
    /// 解析里有可能要查 AX(同步耗时操作),通过 `targetLookupQueue` 跑后台 + Task
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
            // `drawn` = 本次画出来的签名;`bestSeq` = 最近邻命令的规范签名。
            // 单段手势显示方向 + 弧向,多段折返只显示方向序列。
            // 两者并排,一眼就能看出"画成了什么 / 该命中谁",取代旧版只能看浮点距离。
            let candidate = GestureDirection.signature(from: points)
            let drawn = GestureDirection.displayString(candidate)
            let bestSeq = best.map { match -> String in
                let sig = recognizer.canonicalSignature(for: match.command)
                return GestureDirection.displayString(sig)
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

    /// 每次匹配执行自增。`windowUnderPointer` 的 AX 查找在 detached task 上跑,回主线程
    /// 前用它判断"我还是不是最新的那次手势"——若用户期间又画了新手势,旧的 AX 结果
    /// (尤其遇到慢/卡的 App、晚返回时)直接丢弃,避免"过一会儿才补发上一个手势"。
    /// 只在主线程读写。
    @MainActor private var gestureExecutionID: UInt64 = 0

    /// 手势目标 AX 查找专用串行队列(真线程,非协作池)。见 `resolveTargetAndExecute`。
    private static let targetLookupQueue = DispatchQueue(
        label: "com.velto.gesture.target-lookup",
        qos: .userInitiated
    )

    @MainActor
    private func resolveTargetAndExecute(
        shortcut: Shortcut,
        targetPoint: CGPoint,
        policy: GestureTargetPolicy,
        frontmostApplicationAtGestureStart: NSRunningApplication?
    ) {
        gestureExecutionID &+= 1
        let executionID = gestureExecutionID

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
            // AX 查找是**同步阻塞**的跨进程 RPC,完成后切回主线程。
            //
            // 这里必须用真线程的串行队列,不能用 Task.detached:detached task 跑在
            // Swift 协作线程池上,池宽度 ≈ 核心数,而阻塞式 IPC 会把线程整根占住
            // (协作池不会像 GCD 那样补线程)。手势连画时旧的 AX 查找并不会被取消
            // (executionID 只丢弃**结果**),几次就能把池占满,进而卡住全 app 的
            // await —— 包括回主线程那一跳。串行队列同时也天然把并发 AX 压成 1,
            // 与切换器的 AXCallQueue 同一思路。
            Self.targetLookupQueue.async { [weak self] in
                let target = GestureTargetController.executionTarget(
                    at: targetPoint,
                    policy: policy,
                    frontmostApplicationAtGestureStart: nil
                )
                Task { @MainActor in
                    guard let self else { return }
                    // 期间又有新手势触发 → 这次 AX 结果已过期,丢弃。
                    guard executionID == self.gestureExecutionID else {
                        if DebugLog.isEnabled {
                            DebugLog.event("exec", ["dropped": "stale", "id": Double(executionID)])
                        }
                        return
                    }
                    self.executeMatchedGesture(
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

            // 快捷键是 post 到 session tap 的 —— 谁在前台就打给谁。目标定位对了不代表
            // 按键落对地方(AX 熔断期只能靠 activate/SLPS 把 app 拱到前台,拱没拱上去
            // 日志里原本看不见)。落一行前台快照,下次「按了没反应」一眼能分清是
            // 「按键打偏了」还是「打对了但 app 自己不认」。
            let front = NSWorkspace.shared.frontmostApplication
            // 手势的右键 down/up 都被 tap 吞了,但物理按键状态是 HID 层独立记的 ——
            // 真按下去的那一下抬没抬起来,这里才看得见。若发 ⌘W 时右键仍记为按下,
            // 走 mouse tracking loop 的 app(Telegram)会把键盘事件排到 loop 之后,
            // 表现就是「按了没反应」。残留修饰键同理:⌘W 会变成 ⌘⌥W 之类而失效。
            let rightStillDown = CGEventSource.buttonState(.combinedSessionState, button: .right)
            let liveFlags = CGEventSource.flagsState(.combinedSessionState).rawValue & 0xFFFF_0000
            WindowManagementDebugLog.log(
                "  ⌨️ 发 \(shortcut.displayName) → 目标 pid=\(target.pid.map(String.init) ?? "?") "
                + "当前前台 pid=\(front?.processIdentifier.description ?? "?") app=\"\(front?.localizedName ?? "?")\" "
                + "右键仍按下=\(rightStillDown) 实时修饰键=0x\(String(liveFlags, radix: 16))"
            )
            // 「按了没反应」到底是哪几次,以前只能靠用户口头说 —— 日志里 135 次
            // 手势分不出成败,排查就只能靠猜。发完隔 250ms 再数一次目标 app 的
            // 在屏窗口:关窗类快捷键生效就一定会掉一个,不掉就是这次真没生效。
            let watchPid = target.pid
            let winsBefore = watchPid.map(Self.onScreenWindowCount(pid:)) ?? -1
            ShortcutSynthesizer.send(shortcut)
            if let watchPid {
                Task { @MainActor in
                    // 800ms 不是拍脑袋:Telegram 收到 ⌘W 到窗口真正从 WindowServer
                    // 消失实测 320~367ms,一开始设的 250ms 把 20 次全判成「没生效」,
                    // 白白造了一批假信号。留足三倍余量。
                    try? await Task.sleep(for: .milliseconds(800))
                    let after = Self.onScreenWindowCount(pid: watchPid)
                    WindowManagementDebugLog.log(
                        "  ↳ 发完 800ms:pid=\(watchPid) 在屏窗口 \(winsBefore)→\(after) "
                        + (after < winsBefore ? "✅ 窗口少了一个" : "窗口数没变")
                    )
                }
            }

            if restoresOriginalFrontmostApplication {
                try? await Task.sleep(for: .milliseconds(120))
                GestureTargetController.restoreFrontmostApplication(frontmostApplicationAtGestureStart)
            }
        }
    }

    /// 目标 app 当前有几个 layer0 在屏窗口 —— 用来判定关窗快捷键有没有真的生效。
    static func onScreenWindowCount(pid: pid_t) -> Int {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return list.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }.count
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

        // 手势期间 drag 已降级成 mouseMoved 投递,逻辑光标一路跟手;取消时
        // endPosition(最后一个 drag 位置)通常就是 lastSyncedCursorPosition,
        // 下面的 warp 整段跳过,仅在错位边角兜底。真 warp 后立即重新关联 ——
        // warp 自带的事件抑制窗(实测恒 0.25s,didDisableWarpSuppression 并未
        // 真正生效)否则会把光标卡住。
        if endPosition != .zero, endPosition != startPoint {
            if !isCursorSynced(to: endPosition) {
                CGWarpMouseCursorPosition(endPosition)
                CGAssociateMouseAndMouseCursorPosition(1)
                logWarpDiagnostics(reason: "cancel", from: startPoint, to: endPosition)
            }
            lastSyncedCursorPosition = endPosition
        } else {
            lastSyncedCursorPosition = nil
        }
    }

    /// 收尾 warp 的去重判定。up 事件的坐标被系统整数化,而 drag 坐标带小数,
    /// 逐位相等永远判不出"同一位置"(日志实测 release warp 因此每次都触发);
    /// 1px 内视为已同步 —— 亚像素 warp 本身也毫无意义。
    private func isCursorSynced(to point: CGPoint) -> Bool {
        guard let synced = lastSyncedCursorPosition else { return false }
        return distance(synced, point) < 1.0
    }

    /// 水位计:记录每次 warp 的时机、起止点,并回读三个 event source 状态表的
    /// suppression interval。`didDisableWarpSuppression` 启动时把它们设成了 0;
    /// 若这里读回非 0,说明配置没存住(macOS 26 上该路径本就不稳),warp 后的
    /// 0.25s+ 事件抑制窗就是"手势期间光标粘在起手点、松手才跳过去"的直接来源。
    private func logWarpDiagnostics(reason: String, from: CGPoint, to: CGPoint) {
        guard DebugLog.isEnabled else { return }
        let stateIDs: [CGEventSourceStateID] = [.hidSystemState, .combinedSessionState, .privateState]
        let suppression = stateIDs.map {
            CGEventSource(stateID: $0)?.localEventsSuppressionInterval ?? -1
        }
        DebugLog.event("warp", [
            "reason": reason,
            "fromX": Double(from.x), "fromY": Double(from.y),
            "toX": Double(to.x), "toY": Double(to.y),
            "suppression": suppression
        ])
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
