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
  /// 强制下一次重评估即便上下文未变也执行自动切换 —— 偏好变更后置位,
  /// 让用户刚改的规则能立刻作用到当前上下文。
  private var forceReapply = false
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
    // 与 systemInputSourceChanged 同理:@objc 派发绕过 @MainActor 隔离的编译期检查,
    // 显式跳回主线程再访问 monitor / 偏好状态。
    Task { @MainActor [weak self] in
      guard let self else { return }
      InputSourceSwitchDebugLog.setEnabled(GestureStore.shared.preferences.inputSourceSwitch.debugLoggingEnabled)
      // 偏好变更后清空 runtime cache:否则 restorePreviouslyUsed 模式下旧缓存会
      // 一直命中、绕过用户刚改的规则,导致"新配的规则不生效"。代价是会话内
      // "上次用过的输入法"记忆被重置,但语义更可预期。
      self.cache.removeAll()
      self.forceReapply = true
      self.monitor.evaluate()
    }
  }

  // MARK: - 决策

  private func handleContext(_ ctx: InputSourceContext) {
    // 忽略 Velto 自身:对自己的设置窗口自动切输入法没意义;更关键的是临时窗口策略
    // 会让 Velto 短暂抢焦点成为前台,若不忽略就会误触发一次切换、把刚扶正的 IME 冲掉。
    guard ctx.bundleID != Bundle.main.bundleIdentifier else { return }
    let isSameContext = (lastContext?.contextID == ctx.contextID)
    lastContext = ctx
    let prefs = GestureStore.shared.preferences.inputSourceSwitch
    guard prefs.enabled else { return }

    // 自动切换只在「进入新上下文」(或偏好刚变更需重评)时发生一次。同一上下文的重复
    // 评估(浏览器 0.8s 轮询 / 打字触发的 AX 事件 / 重新激活)不再自动切 —— 否则用户在
    // 该上下文里手动切到别的输入法,一打字就被强行打回,等于跟用户抢。手动切换即用户
    // 意图,应予尊重;要换默认值,离开再回来(contextID 变化)时会按策略重新决策。
    guard !isSameContext || forceReapply else {
      return
    }
    forceReapply = false

    guard let targetID = decideTarget(for: ctx, prefs: prefs) else {
      InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 无目标,保持当前")
      return
    }
    // 进入上下文时无条件重新应用(对齐 IPS:App 激活总是 re-select)。
    // 关键:CJKV 输入法即便"当前已是它",菜单栏虽显示该 IME,内部仍可能停在英文子模式
    // (半切换),而 TIS API 读不到中/英子模式 —— 所以必须重跑临时窗口修复才能扶正成中文态。
    // 非 CJKV(US 等无子模式的拉丁键盘)若已是当前,重选无意义,跳过以免刷屏 / 多余抑制。
    let targetIsCJKV = InputSourceCatalog.all().first { $0.id == targetID }?.isCJKV ?? false
    if targetID == InputSourceCatalog.current()?.id, !targetIsCJKV {
      InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 目标=当前(\(targetID)),非 CJKV 跳过")
      return
    }
    InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 应用 \(targetID)\(targetIsCJKV ? "(CJKV 重跑修复)" : "")")
    isApplyingProgrammaticSwitch = true
    programmaticSwitchGeneration += 1
    let generation = programmaticSwitchGeneration
    InputSourceSwitchSelector.select(
      persistentID: targetID,
      cjkFixEnabled: prefs.cjkFixEnabled,
      cjkFixStrategy: prefs.cjkFixStrategy
    )
    // 程序化切换会引发系统通知,延后一拍再解除抑制(覆盖 CJKV 二次事件)。
    // 0.6s 要盖住整套 CJKV 修复序列(bounce 选到非 CJKV 源→合成热键→Command→兜底重选,
    // 约 0.3s)+ 通知投递延迟,否则 bounce 那次选 US 的系统通知会被误记成用户手动切换、
    // 污染 cache。仅当这期间没有更晚的程序化切换时才复位,否则把复位交给最后那一次。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self, self.programmaticSwitchGeneration == generation else { return }
      self.isApplyingProgrammaticSwitch = false
    }
  }

  /// 决策算法。优先级:地址栏强默认 > 规则指定输入法 >(仅 restorePreviouslyUsed)
  /// 上次残留 > 全局默认。
  ///
  /// **规则指定的输入法是 authoritative 的**:切回配了规则的 App / 网站,一定用规则
  /// 指定值,不被"上次手动残留"覆盖。restore 缓存只服务于"没有规则命中、落到全局默认"
  /// 的上下文(即用户没专门配置的 App)—— 那里才记忆/恢复上次手动选择。这样既满足
  /// "配了规则就强制",又保留"没配的 App 记住我上次的选择"。
  private func decideTarget(for ctx: InputSourceContext, prefs: InputSourceSwitchPreferences) -> String? {
    // 地址栏聚焦:强默认。
    if ctx.kind == .addressBar, let addr = prefs.browserAddressDefaultInputSourceID {
      return addr
    }
    // 规则命中(网站规则 / 应用规则):authoritative,优先于 cache 残留。
    if let ruleTarget = ruleMatch(ctx, prefs: prefs) {
      return ruleTarget
    }
    // 无规则命中,落全局默认。restorePreviouslyUsed 时用 cache 记忆上次手动选择。
    if prefs.restoreStrategy == .restorePreviouslyUsed, let cached = cache[ctx.contextID] {
      return cached
    }
    return prefs.systemDefaultInputSourceID
  }

  /// 命中的网站 / 应用规则所指定的输入法;无命中返回 nil(交给 cache / 全局默认)。
  private func ruleMatch(_ ctx: InputSourceContext, prefs: InputSourceSwitchPreferences) -> String? {
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
    return nil
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
