import AppKit
import ApplicationServices
import Foundation

/// 当前输入上下文。
struct InputSourceContext: Equatable {
  enum Kind: Equatable {
    case app
    case website
    case addressBar
  }
  var kind: Kind
  var bundleID: String
  var url: URL?

  /// cache key / 日志用 ID。
  var contextID: String {
    switch kind {
    case .app: return "app:\(bundleID)"
    case .website: return "website:\(bundleID):\(url?.host ?? "")"
    case .addressBar: return "address-bar:\(bundleID)"
    }
  }
}

/// 监听前台 App / 浏览器 Tab 变化,算出 InputSourceContext 后回调。
/// AX 读取全部派发到 AXCallQueue.shared;回调统一跳回主线程。
@MainActor
final class InputSourceContextMonitor {
  /// 上下文变化回调(主线程)。
  var onContextChange: ((InputSourceContext) -> Void)?
  /// 由 Controller 注入:当前是否启用了浏览器规则检测(决定是否跑兜底轮询)。
  var browserDetectionEnabled: () -> Bool = { false }
  /// 由 Controller 注入:某 bundleID 是否被用户勾选为启用浏览器。
  var isBrowserEnabled: (String) -> Bool = { _ in false }

  private var axObserver: AXObserver?
  private var observedPID: pid_t?
  private var pollTimer: Timer?
  private var running = false

  func start() {
    guard !running else { return }
    running = true
    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(self, selector: #selector(activeAppChanged),
                   name: NSWorkspace.didActivateApplicationNotification, object: nil)
    nc.addObserver(self, selector: #selector(activeAppChanged),
                   name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    evaluate()
  }

  func stop() {
    guard running else { return }
    running = false
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    teardownAXObserver()
    pollTimer?.invalidate()
    pollTimer = nil
  }

  @objc private func activeAppChanged() {
    evaluate()
  }

  /// 重新计算当前上下文。前台是浏览器则走 AX 读 URL,否则是普通 App。
  func evaluate() {
    guard running, let front = NSWorkspace.shared.frontmostApplication,
          let bundleID = front.bundleIdentifier
    else { return }
    if InputSourceSwitchSelector.isTemporaryWindowApplicationActivation(front) {
      return
    }
    let pid = front.processIdentifier

    if let browser = SupportedBrowserCatalog.browser(forBundleID: bundleID),
       isBrowserEnabled(bundleID) {
      rewireAXObserver(pid: pid)
      reschedulePoll(isBrowserFront: true)
      let engine = browser.engine
      AXCallQueue.shared.schedule("input-source-browser:\(pid)") { [weak self] in
        let ctx = BrowserAXReader.readContext(pid: pid, engine: engine)
        DispatchQueue.main.async {
          guard let self, self.running else { return }
          self.emitBrowserContext(bundleID: bundleID, page: ctx)
        }
      }
    } else {
      teardownAXObserver()
      reschedulePoll(isBrowserFront: false)
      onContextChange?(InputSourceContext(kind: .app, bundleID: bundleID, url: nil))
    }
  }

  private func emitBrowserContext(bundleID: String, page: BrowserPageContext) {
    if page.addressBarFocused {
      onContextChange?(InputSourceContext(kind: .addressBar, bundleID: bundleID, url: page.url))
    } else if let url = page.url {
      onContextChange?(InputSourceContext(kind: .website, bundleID: bundleID, url: url))
    } else {
      // 取不到 URL:当成普通 App 处理(不强切)。
      onContextChange?(InputSourceContext(kind: .app, bundleID: bundleID, url: nil))
    }
  }

  // MARK: - AXObserver(浏览器 Tab/焦点/标题变化)

  private func rewireAXObserver(pid: pid_t) {
    if observedPID == pid, axObserver != nil { return }
    teardownAXObserver()

    var observer: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      let monitor = Unmanaged<InputSourceContextMonitor>.fromOpaque(refcon).takeUnretainedValue()
      DispatchQueue.main.async { monitor.evaluate() }
    }
    guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
    let appElement = AXUIElementCreateApplication(pid)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for note in [
      kAXFocusedWindowChangedNotification,
      kAXFocusedUIElementChangedNotification,
      kAXTitleChangedNotification,
      kAXWindowCreatedNotification,
    ] {
      AXObserverAddNotification(observer, appElement, note as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    axObserver = observer
    observedPID = pid
  }

  private func teardownAXObserver() {
    if let axObserver {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
    }
    axObserver = nil
    observedPID = nil
  }

  // MARK: - 兜底轮询(0.8s,仅浏览器前台 + 启用浏览器检测)

  private func reschedulePoll(isBrowserFront: Bool) {
    pollTimer?.invalidate()
    pollTimer = nil
    guard isBrowserFront, browserDetectionEnabled() else { return }
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.evaluate() }
    }
  }
}
