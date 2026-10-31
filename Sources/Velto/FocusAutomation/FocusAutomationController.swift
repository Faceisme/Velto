import AppKit
import CoreGraphics
import IOKit.pwr_mgt

/// 专注自动化:每秒检查指定 App 的窗口 / 载入文件 / 播放状态,有 App 在用时跑「打开」快捷指令,
/// 全部结束后跑「关闭」快捷指令。单例,AppDelegate 启停。
///
/// 只关自己打开的:我们没跑过「打开」(用户手动开的勿扰)就不跑「关闭」。
@MainActor @Observable
final class FocusAutomationController {
  static let shared = FocusAutomationController()

  /// 当前算「在用」的 App(bundle id)。
  private(set) var activeBundleIDs: [String] = []
  /// 「打开」快捷指令已由我们跑过,还没跑「关闭」。
  private(set) var focusApplied = false
  /// 最近一次开关勿扰失败的原因;成功后清空。
  private(set) var lastError: String?
  /// 最近一次开关勿扰用的方式(系统快捷键 / 快捷指令)。
  private(set) var lastMethod: String?
  /// 「快捷指令」App 里已有的快捷指令名;nil = 还没读到。
  private(set) var shortcutNames: [String]?

  @ObservationIgnored private var timer: Timer?
  /// 这一轮「在用」已经试过跑「打开」。失败时 focusApplied 回落,不每 2 秒重试,
  /// 而是到 onRetryAt 再试(比如先开着视频、后建的快捷指令)。
  @ObservationIgnored private var attemptedOn = false
  @ObservationIgnored private var onRetryAt: Date?
  /// 每个 App 上一次的判断依据,变了才写日志。
  @ObservationIgnored private var lastDiagnosis: [String: String] = [:]
  @ObservationIgnored private var running = false
  /// 跑快捷指令是阻塞调用,放串行队列保证「打开」「关闭」按顺序执行。
  @ObservationIgnored private let shortcutQueue = DispatchQueue(label: "com.velto.focus.shortcuts")
  /// 只在 shortcutQueue 上用。
  @ObservationIgnored private let dndSwitch = DoNotDisturbSwitch()

  private static let pollInterval: TimeInterval = 1
  private static let retryDelay: TimeInterval = 30
  /// 退出时最多等关勿扰这么久:系统快捷键确认最长 1.5s,再加一次快捷指令。
  private static let quitWaitSeconds: TimeInterval = 3
  /// 单次 `shortcuts` 命令的上限。快捷指令卡住(比如弹了要确认的对话框)时不能一直等。
  nonisolated private static let shortcutsTimeout: TimeInterval = 15
  /// 小于这个尺寸的窗口(工具条、浮动面板)不算。
  private static let minWindowSide: CGFloat = 200
  /// 主线程上的 AX 读取,目标 App 卡死时最多拖这么久。
  private static let axTimeout: Float = 0.25
  /// 播放器防止显示器睡眠时持有的断言类型(Movist Pro 叫 "Movist Playing")。
  private static let playbackAssertionTypes: Set<String> = [
    kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
    kIOPMAssertionTypeNoDisplaySleep as String,
  ]

  private init() {}

  private var prefs: FocusAutomationPreferences { GestureStore.shared.preferences.focusAutomation }

  // MARK: - 生命周期

  func start() {
    guard !running else { return }
    running = true
    FocusAutomationDebugLog.setEnabled(prefs.debugLoggingEnabled)
    NotificationCenter.default.addObserver(
      self, selector: #selector(preferencesChanged),
      name: .gestureStoreDidChange, object: GestureStore.shared
    )
    // App 退出时立刻评估,不等下一次轮询。
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(appTerminated),
      name: NSWorkspace.didTerminateApplicationNotification, object: nil
    )
    // 上次是 Velto 开的勿扰、没来得及关就被重装 / 强退:接着认领。第一次评估时
    // App 还在用就等用完再关,已经不在用了就马上关。
    let dnd = dndSwitch
    if shortcutQueue.sync(execute: { dnd.restoreOwnership() }) {
      FocusAutomationDebugLog.log("沿用重启前由 Velto 打开的勿扰")
      attemptedOn = true
      focusApplied = true
    }
    // 切到别的 App 立刻放开程序坞,不等下一次轮询。
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(appActivated),
      name: NSWorkspace.didActivateApplicationNotification, object: nil
    )
    applyPreferences()
  }

  /// 退出 Velto 时调用:等「关闭」跑完,避免勿扰一直开着。等待有上限:快捷指令卡住时
  /// 宁可留着勿扰,也不能让 Velto 退不出去,后面的清理也还没做。
  func stop() {
    guard running else { return }
    running = false
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    timer?.invalidate()
    timer = nil
    DockRevealGuard.shared.setRegion(nil)
    activeBundleIDs = []
    attemptedOn = false
    onRetryAt = nil
    if focusApplied {
      focusApplied = false
      let p = prefs
      let dnd = dndSwitch
      let finished = DispatchSemaphore(value: 0)
      shortcutQueue.async {
        _ = dnd.turnOff(preferKeyboard: p.preferSystemHotkey, shortcut: p.offShortcutName)
        finished.signal()
      }
      if finished.wait(timeout: .now() + Self.quitWaitSeconds) == .timedOut {
        FocusAutomationDebugLog.log("退出时关勿扰超过 \(Self.quitWaitSeconds)s,不再等")
      }
    }
  }

  @objc private func preferencesChanged() {
    FocusAutomationDebugLog.setEnabled(prefs.debugLoggingEnabled)
    // 改了设置(比如换了快捷指令名)就允许失败的「打开」再试一次。
    if !focusApplied {
      attemptedOn = false
      onRetryAt = nil
    }
    applyPreferences()
  }

  @objc private func appTerminated() {
    if timer != nil { evaluate() }
  }

  @objc private func appActivated() {
    updateDockGuard()
  }

  private func applyPreferences() {
    let p = prefs
    let shouldPoll = p.enabled && !p.apps.isEmpty
    if shouldPoll, timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
        MainActor.assumeIsolated { FocusAutomationController.shared.evaluate() }
      }
      timer?.tolerance = 0.5
      FocusAutomationDebugLog.log("开始轮询 apps=\(p.apps.map(\.bundleID))")
    } else if !shouldPoll, let t = timer {
      t.invalidate()
      timer = nil
      FocusAutomationDebugLog.log("停止轮询")
    }
    evaluate()
  }

  // MARK: - 评估

  private func evaluate() {
    let p = prefs
    let logging = FocusAutomationDebugLog.isEnabled
    var active: [String] = []
    var diagnosis: [String: String] = [:]
    if p.enabled {
      var assertionPIDs: Set<pid_t>?
      func playing(_ pids: Set<pid_t>) -> Bool {
        if assertionPIDs == nil { assertionPIDs = Self.playbackAssertionPIDs() }
        return !pids.isDisjoint(with: assertionPIDs ?? [])
      }
      for app in p.apps {
        let pids = Set(
          NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .map(\.processIdentifier))
        guard !pids.isEmpty else {
          if logging { diagnosis[app.bundleID] = "未运行" }
          continue
        }
        let windowed = Self.hasWindow(pids: pids)
        let inSession = activeBundleIDs.contains(app.bundleID)
        var loaded: String?
        func mediaLoaded() -> Bool {
          // 不能用 lazy.compactMap(...).first:同一个 pid 会问两次 AX,第二次变 nil 就崩(见 firstNonNil)。
          if loaded == nil { loaded = pids.firstNonNil(Self.loadedMediaName) ?? "" }
          return !(loaded ?? "").isEmpty
        }
        let inUse = switch app.trigger {
        case .window: windowed
        // 窗口载入了视频或开始播放就算在用;暂停后只要窗口还在仍算,窗口关掉才结束。
        // 不能只等播放断言:Movist Pro 开始播放 5~6 秒后才申请,载入文件是立刻的。
        case .playing: playing(pids) || (windowed && (inSession || mediaLoaded()))
        }
        // 只在开了调试日志时把各项都查一遍,方便看清没判成在用的原因。
        if logging {
          let media = app.trigger == .playing && windowed && mediaLoaded() ? loaded ?? "" : "无"
          diagnosis[app.bundleID] =
            "pid=\(pids.sorted()) 窗口=\(windowed ? "有" : "无") 文件=\(media) 播放=\(playing(pids) ? "是" : "否")"
        }
        if inUse { active.append(app.bundleID) }
      }
    }

    if logging, diagnosis != lastDiagnosis {
      for (bundleID, note) in diagnosis.sorted(by: { $0.key < $1.key }) where lastDiagnosis[bundleID] != note {
        FocusAutomationDebugLog.log("\(bundleID): \(note)")
      }
    }
    lastDiagnosis = diagnosis
    updateDockGuard()
    if active != activeBundleIDs {
      FocusAutomationDebugLog.log("在用 App: \(activeBundleIDs) -> \(active)")
      activeBundleIDs = active
    }
    let retryDue = !focusApplied && (onRetryAt.map { Date() >= $0 } ?? false)
    if !active.isEmpty, !attemptedOn || retryDue {
      if retryDue { FocusAutomationDebugLog.log("上次打开失败,重试") }
      attemptedOn = true
      onRetryAt = nil
      focusApplied = true
      switchFocus(on: true)
    } else if active.isEmpty, attemptedOn {
      attemptedOn = false
      onRetryAt = nil
      if focusApplied {
        focusApplied = false
        switchFocus(on: false)
      }
    }
  }

  /// 列表里的 App 在最前面且窗口铺满屏幕时,挡住程序坞那条边。
  private func updateDockGuard() {
    let p = prefs
    var region: DockRevealGuard.Region?
    if p.enabled, p.blockDockInFullScreen,
       let front = NSWorkspace.shared.frontmostApplication,
       let bundleID = front.bundleIdentifier,
       p.apps.contains(where: { $0.bundleID == bundleID }),
       let display = DockRevealGuard.fullScreenDisplay(pid: front.processIdentifier) {
      let edge = DockRevealGuard.dockEdge()
      if DockRevealGuard.edgeIsOuter(edge, of: display, among: DockRevealGuard.activeDisplayBounds()) {
        region = .init(displayBounds: display, edge: edge)
      }
    }
    if DockRevealGuard.shared.setRegion(region) {
      FocusAutomationDebugLog.log(region.map { "挡住程序坞: 屏幕 \($0.displayBounds) \($0.edge.rawValue) 边" } ?? "放开程序坞")
    }
  }

  /// 指定进程有没有像样的普通窗口:在屏幕上的,或被最小化到程序坞的。
  ///
  /// 不能只看 CGWindowList:关掉后被 App 藏起来复用的窗口(Movist Pro 就有一个
  /// 500×500 的)和最小化的窗口一样都是 onscreen=false、alpha=1,分不出来。
  /// 所以屏幕上没有时,再用辅助功能问一次有没有 AXMinimized 的窗口。
  /// 别的桌面空间(比如全屏播放所在的空间)上的窗口不算;播放中由播放状态兜着。
  private static func hasWindow(pids: Set<pid_t>) -> Bool {
    hasOnScreenWindow(pids: pids, in: .onScreen()) || pids.contains(where: hasMinimizedWindow)
  }

  /// 屏幕上有没有够大的窗口。置顶浮动窗口也算:Movist Pro「播放时置顶」一开播就把
  /// 窗口提到 layer 3,只认 layer 0 会判成「窗口=无」,刚开的勿扰两秒后又被关掉
  /// (2026-10-29;之前没露馅是因为它的「通用」设置窗口一直开着撑住了 layer 0)。
  static func hasOnScreenWindow(pids: Set<pid_t>, in snapshot: WindowSnapshot) -> Bool {
    snapshot.windows.contains {
      pids.contains($0.pid) && $0.isAppWindow
        && $0.bounds.width >= minWindowSide && $0.bounds.height >= minWindowSide
    }
  }

  private static func hasMinimizedWindow(pid: pid_t) -> Bool {
    guard let windows = AXClient.windows(ofPid: pid, timeout: axTimeout) else { return false }
    return windows.contains { AXClient.bool(kAXMinimizedAttribute, of: $0) == true }
  }

  /// 窗口里载入的文件名;没有返回 nil。优先读 AXDocument(文件 URL),App 没提供时
  /// 退回看窗口标题:Movist Pro 空播放窗口标题是 App 名,载入后是文件名。
  private static func loadedMediaName(pid: pid_t) -> String? {
    guard let appName = NSRunningApplication(processIdentifier: pid)?.localizedName,
          let windows = AXClient.windows(ofPid: pid, timeout: axTimeout)
    else { return nil }
    for window in windows {
      if let document = AXClient.string(kAXDocumentAttribute, of: window), !document.isEmpty {
        return URL(string: document)?.lastPathComponent ?? document
      }
      if AXClient.string(kAXSubroleAttribute, of: window) == kAXStandardWindowSubrole as String,
         let title = AXClient.string(kAXTitleAttribute, of: window), !title.isEmpty, title != appName {
        return title
      }
    }
    return nil
  }

  /// 持有「防止显示器睡眠」断言的进程 —— 视频播放器播放时会持有,暂停后释放。
  private static func playbackAssertionPIDs() -> Set<pid_t> {
    var ref: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess,
          let byPID = ref?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
    else { return [] }
    var result = Set<pid_t>()
    for (pid, assertions) in byPID
    where assertions.contains(where: {
      ($0[kIOPMAssertionTypeKey] as? String).map(playbackAssertionTypes.contains) ?? false
    }) {
      result.insert(pid.int32Value)
    }
    return result
  }

  // MARK: - 开关勿扰

  private func switchFocus(on: Bool) {
    let p = prefs
    let dnd = dndSwitch
    FocusAutomationDebugLog.log(on ? "打开勿扰" : "关闭勿扰")
    shortcutQueue.async {
      let outcome = on
        ? dnd.turnOn(preferKeyboard: p.preferSystemHotkey, shortcut: p.onShortcutName)
        : dnd.turnOff(preferKeyboard: p.preferSystemHotkey, shortcut: p.offShortcutName)
      FocusAutomationDebugLog.log("\(on ? "打开" : "关闭")勿扰结果: \(outcome)")
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          FocusAutomationController.shared.handle(outcome, turningOn: on)
        }
      }
    }
  }

  private func handle(_ outcome: DoNotDisturbSwitch.Outcome, turningOn: Bool) {
    switch outcome {
    case .done(let via):
      lastError = nil
      lastMethod = via
    case .alreadyOn:
      // 本来就开着的不归我们管,结束时也不关。
      lastError = nil
      if turningOn { focusApplied = false }
    case .skipped:
      lastError = nil
    case .failed(let error):
      lastError = error
      // 打开失败就当没开过,后面不跑关闭;这一轮还在用就过一会儿重试。
      if turningOn {
        focusApplied = false
        if attemptedOn { onRetryAt = Date().addingTimeInterval(Self.retryDelay) }
      }
    }
  }

  // MARK: - 快捷指令

  /// 同步跑 `shortcuts run`;返回 nil 表示成功,否则是错误描述。
  nonisolated static func runShortcut(_ name: String) -> String? {
    let result = runShortcutsCLI(["run", name])
    let error: String? = switch result {
    case .success: nil
    case .failure(let message): message.isEmpty ? "运行快捷指令「\(name)」失败" : "「\(name)」:\(message)"
    }
    FocusAutomationDebugLog.log("快捷指令「\(name)」\(error.map { "失败 \($0)" } ?? "完成")")
    return error
  }

  /// 读「快捷指令」App 里已有的快捷指令名,供设置页校验名字。
  func refreshShortcutNames() {
    shortcutQueue.async {
      let names: [String]? = switch Self.runShortcutsCLI(["list"]) {
      case .success(let out): out.split(separator: "\n").map(String.init)
      case .failure: nil
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { FocusAutomationController.shared.shortcutNames = names }
      }
    }
  }

  enum CLIResult: Equatable {
    case success(String)
    case failure(String)
  }

  nonisolated private static func runShortcutsCLI(_ arguments: [String]) -> CLIResult {
    runCLI("/usr/bin/shortcuts", arguments, timeout: shortcutsTimeout)
  }

  nonisolated static func runCLI(_ path: String, _ arguments: [String], timeout: TimeInterval) -> CLIResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    // 不给输入:`shortcuts run` 在 stdin 不是终端时会等着读输入。
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = out
    process.standardError = err
    do {
      try process.run()
    } catch {
      return .failure(error.localizedDescription)
    }
    // 下面的读取要等进程结束,卡住就超时杀掉,管道随之关闭,读取才能返回。
    let pid = process.processIdentifier
    let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    if process.terminationReason == .uncaughtSignal {
      return .failure("超过 \(Int(timeout)) 秒没有结束,已终止")
    }
    if process.terminationStatus == 0 {
      return .success(String(decoding: output, as: UTF8.self))
    }
    let message = String(decoding: errorOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "Error: ", with: "")
    return .failure(message)
  }
}
