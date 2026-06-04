import AppKit
import Carbon
import Foundation

/// 输入法自动切换的总指挥。单例,AppDelegate 持有。
///
///   ContextMonitor ──上下文──→ Controller ──决策──→ Selector(TIS 切换)
///                                  │
///                       runtime cache(内存) ←── 用户手动切换通知
///
/// 决策优先级见 spec §4。cache 仅内存,进程退出即清。
@MainActor
final class InputSourceSwitchController {
  static let shared = InputSourceSwitchController()

  private let monitor = InputSourceContextMonitor()
  /// 内存 runtime cache:contextID → 输入法持久化 ID。不持久化。
  private var cache: [String: String] = [:]
  /// 最近一次上下文(收到系统输入法变更通知时,据此更新 cache)。
  private var lastContext: InputSourceContext?
  /// 自切抑制:程序化切换会触发系统通知,期内不写 cache,避免回灌/反馈环。
  private var isApplyingProgrammaticSwitch = false
  /// 抑制窗口代次:仅最后一次程序化切换排定的复位生效。否则 0.3s 内连续两次切换时,
  /// 早到的定时器会提前清掉抑制标志,使后一次切换的系统通知被误记成用户手动 → 污染 cache。
  private var programmaticSwitchGeneration = 0
  private var running = false

  private init() {}

  // MARK: - 生命周期

  func start() {
    guard !running else { return }
    running = true
    let prefs = GestureStore.shared.preferences.inputSourceSwitch
    InputSourceSwitchDebugLog.setEnabled(prefs.debugLoggingEnabled)

    monitor.browserDetectionEnabled = {
      let p = GestureStore.shared.preferences.inputSourceSwitch
      return p.enabled && !p.enabledBrowserBundleIDs.isEmpty
    }
    monitor.isBrowserEnabled = { bundleID in
      GestureStore.shared.preferences.inputSourceSwitch.enabledBrowserBundleIDs.contains(bundleID)
    }
    monitor.onContextChange = { [weak self] ctx in
      self?.handleContext(ctx)
    }
    monitor.start()

    // 用户手动切换输入法 → 更新当前上下文 cache(用于 restorePreviouslyUsed)。
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(systemInputSourceChanged),
      name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil
    )
    // 偏好变化 → 同步调试开关 + 重新评估。
    NotificationCenter.default.addObserver(
      self, selector: #selector(storeChanged(_:)),
      name: .gestureStoreDidChange, object: GestureStore.shared
    )
  }

  func stop() {
    guard running else { return }
    running = false
    monitor.stop()
    DistributedNotificationCenter.default().removeObserver(self)
    NotificationCenter.default.removeObserver(self, name: .gestureStoreDidChange, object: GestureStore.shared)
  }

  @objc private func storeChanged(_ note: Notification) {
    guard note.gestureStoreChangeReason == .preferences
            || note.gestureStoreChangeReason == .backupImport else { return }
    InputSourceSwitchDebugLog.setEnabled(GestureStore.shared.preferences.inputSourceSwitch.debugLoggingEnabled)
    monitor.evaluate()
  }

  // MARK: - 决策

  private func handleContext(_ ctx: InputSourceContext) {
    lastContext = ctx
    let prefs = GestureStore.shared.preferences.inputSourceSwitch
    guard prefs.enabled else { return }

    guard let targetID = decideTarget(for: ctx, prefs: prefs) else {
      InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 无目标,保持当前")
      return
    }
    guard targetID != InputSourceCatalog.current()?.id else {
      InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 目标=当前(\(targetID)),不切")
      return
    }
    InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 切到 \(targetID)")
    isApplyingProgrammaticSwitch = true
    programmaticSwitchGeneration += 1
    let generation = programmaticSwitchGeneration
    InputSourceSwitchSelector.select(
      persistentID: targetID,
      cjkFixEnabled: prefs.cjkFixEnabled,
      cjkFixStrategy: prefs.cjkFixStrategy
    )
    // 程序化切换会引发系统通知,延后一拍再解除抑制(覆盖 CJKV 二次事件)。
    // 仅当这期间没有更晚的程序化切换时才复位,否则把复位交给最后那一次。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, self.programmaticSwitchGeneration == generation else { return }
      self.isApplyingProgrammaticSwitch = false
    }
  }

  /// spec §4 决策算法。
  private func decideTarget(for ctx: InputSourceContext, prefs: InputSourceSwitchPreferences) -> String? {
    // 地址栏聚焦:瞬时强覆盖,不被 cache 覆盖。
    if ctx.kind == .addressBar, let addr = prefs.browserAddressDefaultInputSourceID {
      return addr
    }
    let base = defaultFor(ctx, prefs: prefs)
    if prefs.restoreStrategy == .restorePreviouslyUsed, let cached = cache[ctx.contextID] {
      return cached
    }
    return base
  }

  private func defaultFor(_ ctx: InputSourceContext, prefs: InputSourceSwitchPreferences) -> String? {
    // 浏览器网站规则(按 createdAt 升序,先匹配先命中)。
    if ctx.kind == .website, let url = ctx.url {
      let sorted = prefs.browserRules.filter { $0.isEnabled }.sorted { $0.createdAt < $1.createdAt }
      for rule in sorted where matches(rule: rule, url: url) {
        if let id = rule.inputSourceID { return id }
      }
    }
    // 应用规则。
    if let rule = prefs.appRules.first(where: { $0.isEnabled && $0.bundleIdentifier == ctx.bundleID }),
       let id = rule.inputSourceID {
      return id
    }
    // 全局默认兜底。
    return prefs.systemDefaultInputSourceID
  }

  /// 浏览器规则匹配。
  static func matches(rule: InputSourceBrowserRule, url: URL) -> Bool {
    switch rule.type {
    case .domain:
      return url.host == rule.value
    case .domainSuffix:
      return (url.host ?? "").hasSuffix(rule.value)
    case .urlRegex:
      guard let re = try? NSRegularExpression(pattern: rule.value) else { return false }
      let s = url.absoluteString
      return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
  }

  private func matches(rule: InputSourceBrowserRule, url: URL) -> Bool {
    Self.matches(rule: rule, url: url)
  }

  // MARK: - 用户手动切换 → 更新 cache

  @objc private func systemInputSourceChanged() {
    // 该通知由 DistributedNotificationCenter 投递,投递线程取决于注册时的 run loop。
    // 当前在主线程 start() 注册,实际即主线程;但 @objc 派发会绕过 actor 隔离的编译期
    // 检查,这里显式跳回主线程,确保对 @MainActor 状态(cache/抑制标志)的访问始终安全。
    Task { @MainActor [weak self] in self?.applyUserInputSourceChange() }
  }

  private func applyUserInputSourceChange() {
    guard running, !isApplyingProgrammaticSwitch,
          let ctx = lastContext, ctx.kind != .addressBar,
          let current = InputSourceCatalog.current()?.id
    else { return }
    cache[ctx.contextID] = current
    InputSourceSwitchDebugLog.log("用户手动切换 → cache[\(ctx.contextID)] = \(current)")
  }
}
