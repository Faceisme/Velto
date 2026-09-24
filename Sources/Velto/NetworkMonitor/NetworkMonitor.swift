import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

/// 网络监控数据源。菜单栏总速率每秒读一次物理网卡计数(几乎零开销);
/// 进程 / 连接明细要跑 nettop,只在弹窗或网络面板可见时采样。
@MainActor @Observable
final class NetworkMonitor {
  static let shared = NetworkMonitor()

  struct Sample: Identifiable {
    let id: Int
    let up: Double
    let down: Double
  }

  /// 按 app 汇总:进程归到最外层 .app 包(Chrome 的各个 Helper 都算 Chrome)。
  struct AppTraffic: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    var up = 0.0
    var down = 0.0
    var totalUp: UInt64 = 0
    var totalDown: UInt64 = 0
    var connections = 0
  }

  struct Connection: Identifiable {
    let id: String
    let appID: String
    let appName: String
    let icon: NSImage
    let proto: String
    let remote: String
    let state: String
    var up: Double
    var down: Double
    let totalUp: UInt64
    let totalDown: UInt64
  }

  private(set) var upload = 0.0
  private(set) var download = 0.0
  private(set) var history = (-59...0).map { Sample(id: $0, up: 0, down: 0) }
  private(set) var interfaceLabel = "未连接"
  private(set) var apps: [AppTraffic] = []
  private(set) var connections: [Connection] = []
  var paused = false

  private struct Owner {
    let id: String
    let name: String
    let icon: NSImage
  }

  @ObservationIgnored private var interface: String?
  @ObservationIgnored private var interfaceLast: (up: UInt64, down: UInt64, at: TimeInterval)?
  @ObservationIgnored private var ticks = 0
  @ObservationIgnored private var sampling = false
  @ObservationIgnored private var lastSampleAt: TimeInterval = 0
  @ObservationIgnored private var previous: [String: NetFlow] = [:]
  @ObservationIgnored private var owners: [Int32: Owner] = [:]
  @ObservationIgnored private var totals: [String: AppTraffic] = [:]

  /// 每秒一次:物理主网卡计数差 → 总速率。每 5 秒重新识别主网卡(切 Wi-Fi / 插网线)。
  func sampleInterface() {
    if interface == nil || ticks % 5 == 0 {
      let primary = NetInterface.primary()
      if primary != interface {
        interface = primary
        interfaceLast = nil
      }
      interfaceLabel = primary.map(NetInterface.describe) ?? "未连接"
    }
    ticks += 1
    let now = ProcessInfo.processInfo.systemUptime
    if let interface, let bytes = NetInterface.bytes(interface) {
      // 首次、换了网卡或定时器停过(隔太久):这一轮只记基线,旧速率清零。
      if let last = interfaceLast, now - last.at <= 3 {
        upload = Self.rate(bytes.up, last.up, now - last.at)
        download = Self.rate(bytes.down, last.down, now - last.at)
      } else {
        upload = 0
        download = 0
      }
      interfaceLast = (bytes.up, bytes.down, now)
    } else {
      upload = 0
      download = 0
      interfaceLast = nil
    }
    history.append(Sample(id: history[history.count - 1].id + 1, up: upload, down: download))
    history.removeFirst()
  }

  /// 后台跑一次 nettop,按连接做差得到速率。进程行的字节只是它当前各连接之和,
  /// 连接一断就回落,所以只能逐连接做差再汇总到 app。
  func sampleProcesses() {
    guard !paused, !sampling else { return }
    // 停采过一阵(没人看):上一轮的速率早过时了,先清零,别让菜单 / 面板一打开先闪一下旧数据再跳。
    if ProcessInfo.processInfo.systemUptime - lastSampleAt > 3 {
      apps = apps.map { var app = $0; app.up = 0; app.down = 0; return app }
      connections = connections.map { var row = $0; row.up = 0; row.down = 0; return row }
    }
    sampling = true
    Task {
      let flows = await Task.detached(priority: .utility) { Nettop.sample() }.value
      sampling = false
      if let flows, !paused { ingest(flows) }
    }
  }

  /// 清空各 app 的本次累计。
  func clear() {
    totals = [:]
    apps = []
    connections = []
  }

  func ingest(_ flows: [NetFlow]) {
    let now = ProcessInfo.processInfo.systemUptime
    let dt = now - lastSampleAt
    // 首次采样或隔了太久(弹窗关过、暂停过):这一轮只记基线,不出速率也不计累计。
    let counting = lastSampleAt > 0 && dt > 0 && dt <= 3
    let scale = counting ? 1 / dt : 0
    lastSampleAt = now
    for id in totals.keys {
      totals[id]?.up = 0
      totals[id]?.down = 0
      totals[id]?.connections = 0
    }
    // 同一进程可能开着好几个四元组一模一样的 socket(Chrome 一排 mDNS *.5353),nettop 每次
    // 输出的先后不固定,按顺序编号会配错对、凭空算出几十 MB/s —— 合成一行再做差。
    var merged: [String: NetFlow] = [:]
    var keys: [String] = []
    for flow in flows {
      let key = "\(flow.pid)|\(flow.proto)|\(flow.local)|\(flow.remote)"
      if var same = merged[key] {
        same.rx += flow.rx
        same.tx += flow.tx
        merged[key] = same
      } else {
        merged[key] = flow
        keys.append(key)
      }
    }
    var rows: [Connection] = []
    for key in keys {
      let flow = merged[key]!
      let before = previous[key]
      let rx = counting ? Self.delta(flow.rx, before?.rx) : 0
      let tx = counting ? Self.delta(flow.tx, before?.tx) : 0
      let up = Double(tx) * scale, down = Double(rx) * scale
      let owner = owner(of: flow)
      var app = totals[owner.id] ?? AppTraffic(id: owner.id, name: owner.name, icon: owner.icon)
      app.up += up
      app.down += down
      app.totalUp += tx
      app.totalDown += rx
      app.connections += 1
      totals[owner.id] = app
      rows.append(Connection(
        id: key, appID: owner.id, appName: owner.name, icon: owner.icon,
        proto: flow.proto, remote: flow.remote, state: flow.state,
        up: up, down: down, totalUp: flow.tx, totalDown: flow.rx
      ))
    }
    previous = merged
    let pids = Set(flows.map(\.pid))
    owners = owners.filter { pids.contains($0.key) }
    apps = totals.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    connections = rows
  }

  /// pid → 所属 app。取不到路径(别的用户的进程)就用 nettop 给的名字。
  private func owner(of flow: NetFlow) -> Owner {
    if let cached = owners[flow.pid] { return cached }
    var buffer = [UInt8](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
    let length = proc_pidpath(flow.pid, &buffer, UInt32(buffer.count))
    let owner: Owner
    if length > 0 {
      let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
      if let app = path.range(of: ".app/") {
        let bundle = String(path[..<app.lowerBound]) + ".app"
        var name = FileManager.default.displayName(atPath: bundle)
        if name.hasSuffix(".app") { name.removeLast(4) }
        owner = Owner(id: bundle, name: name, icon: NSWorkspace.shared.icon(forFile: bundle))
      } else {
        owner = Owner(id: path, name: (path as NSString).lastPathComponent, icon: NSWorkspace.shared.icon(forFile: path))
      }
    } else {
      owner = Owner(id: flow.process, name: flow.process, icon: NSWorkspace.shared.icon(for: .unixExecutable))
    }
    owners[flow.pid] = owner
    return owner
  }

  /// 计数回退(网卡重置)记 0;超过 100Gbps 的离谱值也按 0 处理 —— Stats 同款防护。
  private static func rate(_ now: UInt64, _ before: UInt64, _ dt: TimeInterval) -> Double {
    guard now >= before, dt > 0 else { return 0 }
    let value = Double(now - before) / dt
    return value > 12.5e9 ? 0 : value
  }

  /// 新连接(上一轮没见过)整段都算这一轮的。
  private static func delta(_ now: UInt64, _ before: UInt64?) -> UInt64 {
    guard let before else { return now }
    return now >= before ? now - before : 0
  }
}

/// 菜单栏网速图标 + 下拉菜单 + 网络面板窗口,以及驱动采样的 1s 定时器。
@MainActor
final class NetworkMonitorController: NSObject, NSMenuDelegate {
  static let shared = NetworkMonitorController()

  private let monitor = NetworkMonitor.shared
  private var statusItem: NSStatusItem?
  private var timer: Timer?
  private var dashboard: NSWindow?
  private var lastWatched: TimeInterval = 0
  private var menuOpen = false
  /// 下拉用原生菜单(和 Surge 一样):点开不激活 Velto。激活会把后台开着的网络面板 / 设置窗口
  /// 一起带到最前,前台 app 也会失焦闪一下。菜单跟踪期间 .common 定时器和 SwiftUI 照常刷新。
  private lazy var menu: NSMenu = {
    let menu = NSMenu()
    menu.delegate = self
    let header = NSMenuItem()
    let hosting = NSHostingView(rootView: NetworkMenuHeader())
    hosting.frame.size = hosting.fittingSize
    header.view = hosting
    menu.addItem(header)
    menu.addItem(.separator())
    menu.addItem(withTitle: "打开网络面板…", action: #selector(showDashboard), keyEquivalent: "").target = self
    return menu
  }()

  func setEnabled(_ enabled: Bool) {
    if enabled, statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.autosaveName = "VeltoNetworkSpeed"
      item.menu = menu
      statusItem = item
      render()
      startTimer()
    } else if !enabled, let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
      self.statusItem = nil
    }
  }

  @objc func showDashboard() {
    if dashboard == nil {
      let controller = NSHostingController(rootView: NetworkDashboardView())
      controller.sceneBridgingOptions = [.toolbars, .title]
      let window = NSWindow(contentViewController: controller)
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      window.toolbarStyle = .unified
      window.isReleasedWhenClosed = false
      window.setContentSize(NSSize(width: 1040, height: 640))
      window.minSize = NSSize(width: 760, height: 420)
      window.center()
      window.setFrameAutosaveName("VeltoNetworkDashboard")
      dashboard = window
    }
    watch()  // 先清掉过时的速率再露面
    dashboard?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func menuWillOpen(_ menu: NSMenu) {
    menuOpen = true
    watch()
  }

  func menuDidClose(_ menu: NSMenu) {
    menuOpen = false
  }

  /// 有人在看明细:立刻采一次,之后每秒采,没人看 30 秒后停掉 nettop。
  private func watch() {
    lastWatched = ProcessInfo.processInfo.systemUptime
    monitor.sampleProcesses()
    startTimer()
  }

  private func startTimer() {
    guard timer == nil else { return }
    // 定时器停过(菜单栏网速关着、面板关了 30 秒):总速率也过时了,立刻重采一次清零。
    monitor.sampleInterface()
    let timer = Timer(timeInterval: 1, repeats: true) { _ in
      MainActor.assumeIsolated { NetworkMonitorController.shared.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func tick() {
    let now = ProcessInfo.processInfo.systemUptime
    monitor.sampleInterface()
    if menuOpen || dashboard?.occlusionState.contains(.visible) == true { lastWatched = now }
    let watched = now - lastWatched < 30
    if watched { monitor.sampleProcesses() }
    render()
    if statusItem == nil, !watched {
      timer?.invalidate()
      timer = nil
    }
  }

  private func render() {
    guard let button = statusItem?.button else { return }
    let up = NetFormat.speed(monitor.upload), down = NetFormat.speed(monitor.download)
    button.image = NetFormat.menuBarImage(up: up, down: down)
    button.setAccessibilityLabel("上传 \(up),下载 \(down)")
  }
}

enum NetFormat {
  /// 字节量:B / KB 取整,MB 起保留 3 位有效数字。
  static func bytes(_ value: Double) -> String { scaled(value, unit: 0) }

  /// 速率:最小单位 KB/s(和 Surge 一样,闲时显示 0 KB/s)。
  static func speed(_ value: Double) -> String { scaled(value / 1024, unit: 1) + "/s" }

  private static let units = ["B", "KB", "MB", "GB", "TB"]

  private static func scaled(_ value: Double, unit: Int) -> String {
    var value = max(0, value), unit = unit
    while value >= 999.5, unit < units.count - 1 {
      value /= 1024
      unit += 1
    }
    let number = unit < 2 || value >= 99.95 ? String(format: "%.0f", value)
      : value >= 9.995 ? String(format: "%.1f", value) : String(format: "%.2f", value)
    return "\(number) \(units[unit])"
  }

  /// Surge 式菜单栏图标:左边 5 根圆角竖条,右边两行右对齐,上行上传、下行下载。
  /// 模板图,颜色跟随菜单栏;文字区宽度固定,数字变化时图标不跳。
  /// nonisolated:drawingHandler 可能在任意线程回调,不能继承 MainActor 隔离。
  static func menuBarImage(up: String, down: String) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .right
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.black]
    let textWidth = ceil(("8.88 MB/s" as NSString).size(withAttributes: [.font: font]).width) + 1
    let bars: [CGFloat] = [4, 8, 12, 9, 5]
    let upText = NSAttributedString(string: up, attributes: attributes)
    let downText = NSAttributedString(string: down, attributes: attributes)
    let size = NSSize(width: CGFloat(bars.count) * 3.5 - 1.5 + 4 + textWidth, height: 22)
    let image = NSImage(size: size, flipped: false) { _ in
      NSColor.black.setFill()
      for (index, height) in bars.enumerated() {
        let bar = NSRect(x: CGFloat(index) * 3.5, y: (size.height - height) / 2, width: 2, height: height)
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
      }
      let x = size.width - textWidth
      upText.draw(in: NSRect(x: x, y: 10.5, width: textWidth, height: 11))
      downText.draw(in: NSRect(x: x, y: 0.5, width: textWidth, height: 11))
      return true
    }
    image.isTemplate = true
    return image
  }
}
