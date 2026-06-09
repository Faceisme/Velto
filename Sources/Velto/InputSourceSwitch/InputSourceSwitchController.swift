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

    // 一进入新上下文就作废上一上下文排定的延时 select(无论本次走切换、跳过还是无目标)。
    // 否则会出现:刚切到 WeChat 排了豆包(延 0.15s),19ms 后又切回 Claude 走「非 CJKV 跳过」
    // 分支直接 return,没取消那笔豆包 → 0.15s 后豆包在 Claude 里触发(豆包→US 失败的真凶)。
    // 切换分支稍后的 select() 自身也会 cancel,但跳过 / 无目标分支不会,故在此统一兜底。
    InputSourceSwitchSelector.cancelPending()

    guard let targetID = decideTarget(for: ctx, prefs: prefs) else {
      InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 无目标,保持当前")
      return
    }
    // 进入上下文时无条件重新应用(对齐 IPS:App 激活总是 re-select)。
    // 关键:CJKV 输入法即便"当前已是它",菜单栏虽显示该 IME,内部仍可能停在英文子模式
    // (半切换),而 TIS API 读不到中/英子模式。是否额外修复由 cjkFixEnabled/strategy 决定。
    // 非 CJKV(US 等无子模式的拉丁键盘)若已是当前,重选无意义,跳过以免刷屏 / 多余抑制。
    let targetIsCJKV = InputSourceCatalog.all().first { $0.id == targetID }?.isCJKV ?? false
    let alreadyCurrent = targetID == InputSourceCatalog.current()?.id
    if alreadyCurrent, !targetIsCJKV {
      InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 目标=当前(\(targetID)),非 CJKV 跳过")
      return
    }
    // CJKV 已是当前仍重选:对齐 ISP「进入上下文必 re-select」,扶正可能停在英文子模式的半切换。
    InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 应用 \(targetID)\(alreadyCurrent && targetIsCJKV ? "(CJKV 重应用)" : "")")
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

  /// 决策算法。对齐 InputSourcePro:
  /// 地址栏强默认 > (restorePreviouslyUsed 时)上次使用 cache > 规则指定输入法 > 全局默认。
  ///
  /// 地址栏是瞬时状态,不读写 cache。普通 App / 网站开启恢复后,用户在该上下文手动切换过
  /// 输入法,下次回来优先恢复它;若手动切回默认值,cache 会被移除。
  private func decideTarget(for ctx: InputSourceContext, prefs: InputSourceSwitchPreferences) -> String? {
    // 地址栏聚焦:强默认。
    if ctx.kind == .addressBar, let addr = prefs.browserAddressDefaultInputSourceID {
      return addr
    }
    if prefs.restoreStrategy == .restorePreviouslyUsed, let cached = cache[ctx.contextID] {
      return cached
    }
    return defaultTarget(for: ctx, prefs: prefs)
  }

  /// 规则 / 全局默认算出来的默认目标,不含 restore cache。
  private func defaultTarget(for ctx: InputSourceContext, prefs: InputSourceSwitchPreferences) -> String? {
    ruleMatch(ctx, prefs: prefs) ?? prefs.systemDefaultInputSourceID
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
    let prefs = GestureStore.shared.preferences.inputSourceSwitch
    guard running, !isApplyingProgrammaticSwitch,
          prefs.restoreStrategy == .restorePreviouslyUsed,
          let ctx = lastContext, ctx.kind != .addressBar,
          let current = InputSourceCatalog.current()?.id
    else { return }
    if defaultTarget(for: ctx, prefs: prefs) == current {
      cache.removeValue(forKey: ctx.contextID)
      InputSourceSwitchDebugLog.log("用户手动切回默认 → cache[\(ctx.contextID)] 已清除")
    } else {
      cache[ctx.contextID] = current
      InputSourceSwitchDebugLog.log("用户手动切换 → cache[\(ctx.contextID)] = \(current)")
    }
  }
}
