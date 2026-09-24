import AppKit
import Charts
import SwiftUI

// MARK: - 菜单栏下拉

/// 下拉菜单顶部的自定义视图(下面是原生菜单项「打开网络面板…」)。
/// 菜单打开后不会跟着内容重新布局,所以高度必须恒定:进程固定 8 行,不够就留空行。
struct NetworkMenuHeader: View {
  private let monitor = NetworkMonitor.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 0) {
        SpeedReadout(title: "上传", symbol: "arrow.up", value: monitor.upload, color: .orange)
        SpeedReadout(title: "下载", symbol: "arrow.down", value: monitor.download, color: .blue)
      }
      TrafficChart(history: monitor.history)
        .frame(height: 64)
      Text(monitor.interfaceLabel)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

      Divider()

      // 网速从高到低;没流量的按累计流量排(apps 本身按名字排好,sorted 稳定),不会每秒乱跳。
      let top = Array(monitor.apps.sorted {
        ($0.up + $0.down, $0.totalUp + $0.totalDown) > ($1.up + $1.down, $1.totalUp + $1.totalDown)
      }.prefix(8))
      VStack(spacing: 4) {
        ForEach(0..<8, id: \.self) { index in
          HStack(spacing: 8) {
            if index < top.count {
              let app = top[index]
              AppIcon(image: app.icon)
              Text(app.name)
                .lineLimit(1)
              Spacer(minLength: 8)
              Group {
                Text("↑ " + NetFormat.bytes(app.up) + "/s")
                  .frame(width: 70, alignment: .trailing)
                Text("↓ " + NetFormat.bytes(app.down) + "/s")
                  .frame(width: 70, alignment: .trailing)
              }
              .font(.system(size: 11))
              .monospacedDigit()
              .foregroundStyle(.secondary)
            }
          }
          .font(.system(size: 12))
          .frame(height: 18)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 8)
    .padding(.bottom, 4)
    .frame(width: 320)
  }
}

private struct SpeedReadout: View {
  let title: String
  let symbol: String
  let value: Double
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Label(title, systemImage: symbol)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
      Text(NetFormat.speed(value))
        .font(.system(size: 20, weight: .semibold))
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 最近 60 秒速率曲线:下载蓝、上传橙,两块面积叠着画(不堆叠)。
private struct TrafficChart: View {
  let history: [NetworkMonitor.Sample]

  var body: some View {
    let peak = history.map { max($0.up, $0.down) }.max() ?? 0
    Chart(history) { sample in
      AreaMark(x: .value("时间", sample.id), y: .value("速率", sample.down), stacking: .unstacked)
        .foregroundStyle(by: .value("方向", "下载"))
        .interpolationMethod(.monotone)
      AreaMark(x: .value("时间", sample.id), y: .value("速率", sample.up), stacking: .unstacked)
        .foregroundStyle(by: .value("方向", "上传"))
        .interpolationMethod(.monotone)
    }
    .chartForegroundStyleScale(["下载": Color.blue.opacity(0.5), "上传": Color.orange.opacity(0.5)])
    .chartLegend(.hidden)
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartXScale(domain: history[0].id...history[history.count - 1].id)
    .chartYScale(domain: 0...max(peak, 10 * 1024))
  }
}

private struct AppIcon: View {
  let image: NSImage

  var body: some View {
    Image(nsImage: image)
      .resizable()
      .frame(width: 16, height: 16)
  }
}

// MARK: - 网络面板(Surge Dashboard 风格)

struct NetworkDashboardView: View {
  private enum Tab: String, CaseIterable {
    case connections = "活动连接"
    case apps = "进程流量"
  }

  private let monitor = NetworkMonitor.shared
  @State private var tab = Tab.connections
  @State private var filter: String? = "*"
  @State private var search = ""
  @State private var connectionOrder = [KeyPathComparator(\NetworkMonitor.Connection.down, order: .reverse)]
  @State private var appOrder = [KeyPathComparator(\NetworkMonitor.AppTraffic.down, order: .reverse)]

  var body: some View {
    NavigationSplitView {
      List(selection: $filter) {
        Label("所有进程", systemImage: "network")
          .tag("*")
        Section("本地程序") {
          ForEach(monitor.apps) { app in
            Label { Text(app.name) } icon: { AppIcon(image: app.icon) }
              .tag(app.id)
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    } detail: {
      VStack(spacing: 0) {
        switch tab {
        case .connections: connectionTable
        case .apps: appTable
        }
        Divider()
        footer
      }
    }
    .navigationTitle("网络面板")
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("视图", selection: $tab) {
          ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
    }
    .searchable(text: $search, placement: .toolbar, prompt: "搜索进程 / 地址")
  }

  private var connectionTable: some View {
    let rows = monitor.connections
      .filter { visible($0.appID, $0.appName, $0.remote) }
      .sorted(using: connectionOrder)
    return Table(rows, sortOrder: $connectionOrder) {
      TableColumn("进程", value: \.appName) { row in
        AppCell(icon: row.icon, name: row.appName, active: row.up + row.down > 0)
      }
      .width(min: 150, ideal: 190)
      TableColumn("下载", value: \.down) { row in SpeedCell(value: row.down) }
        .width(80)
      TableColumn("上传", value: \.up) { row in SpeedCell(value: row.up) }
        .width(80)
      TableColumn("流量", value: \.totalDown) { row in
        Text("↓ \(NetFormat.bytes(Double(row.totalDown)))  ↑ \(NetFormat.bytes(Double(row.totalUp)))")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .width(min: 130, ideal: 150)
      TableColumn("协议", value: \.proto) { row in
        ProtocolPill(proto: row.proto, remote: row.remote)
      }
      .width(64)
      TableColumn("远端地址", value: \.remote) { row in
        Text(row.remote).truncationMode(.middle)
      }
      .width(min: 160, ideal: 260)
      TableColumn("状态", value: \.state) { row in
        Text(Self.stateLabel(row.state)).foregroundStyle(.secondary)
      }
      .width(64)
    }
    .tableStyle(.inset)
    .alternatingRowBackgrounds()
  }

  private var appTable: some View {
    let rows = monitor.apps
      .filter { visible($0.id, $0.name) }
      .sorted(using: appOrder)
    return Table(rows, sortOrder: $appOrder) {
      TableColumn("进程", value: \.name) { row in
        AppCell(icon: row.icon, name: row.name, active: row.up + row.down > 0)
      }
      .width(min: 180, ideal: 240)
      TableColumn("下载", value: \.down) { row in SpeedCell(value: row.down) }
        .width(90)
      TableColumn("上传", value: \.up) { row in SpeedCell(value: row.up) }
        .width(90)
      TableColumn("累计下载", value: \.totalDown) { row in BytesCell(value: row.totalDown) }
        .width(90)
      TableColumn("累计上传", value: \.totalUp) { row in BytesCell(value: row.totalUp) }
        .width(90)
      TableColumn("连接", value: \.connections) { row in
        Text("\(row.connections)")
          .monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .width(60)
    }
    .tableStyle(.inset)
    .alternatingRowBackgrounds()
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Button {
        monitor.paused.toggle()
      } label: {
        Image(systemName: monitor.paused ? "play.fill" : "pause.fill")
      }
      .help(monitor.paused ? "继续" : "暂停")
      Button {
        monitor.clear()
      } label: {
        Image(systemName: "trash")
      }
      .help("清空累计流量")
      Text(monitor.paused ? "已暂停" : "\(monitor.connections.count) 个连接 · 每秒刷新")
        .foregroundStyle(.secondary)
      Spacer()
      Text("↑ \(NetFormat.speed(monitor.upload))    ↓ \(NetFormat.speed(monitor.download))")
        .monospacedDigit()
    }
    .font(.system(size: 11))
    .buttonStyle(.borderless)
    .padding(.horizontal, 10)
    .frame(height: 28)
    .background(.bar)
  }

  private func visible(_ appID: String, _ texts: String...) -> Bool {
    (filter == nil || filter == "*" || filter == appID)
      && (search.isEmpty || texts.contains { $0.localizedCaseInsensitiveContains(search) })
  }

  private static func stateLabel(_ state: String) -> String {
    switch state {
    case "": "—"
    case "Established": "已建立"
    case "SynSent", "SynReceived": "连接中"
    case "Listen": "监听"
    default: "关闭中"
    }
  }
}

/// 行首状态圆点(有流量时亮黄,和 Surge 一样)+ 图标 + 名字。
private struct AppCell: View {
  let icon: NSImage
  let name: String
  let active: Bool

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(active ? Color.yellow : Color.secondary.opacity(0.35))
        .frame(width: 7, height: 7)
      AppIcon(image: icon)
      Text(name)
    }
  }
}

/// 行内速率精确到 B/s:小流量连接不至于一排 "0 KB/s"。
private struct SpeedCell: View {
  let value: Double

  var body: some View {
    Text(value > 0 ? NetFormat.bytes(value) + "/s" : "—")
      .monospacedDigit()
      .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

private struct BytesCell: View {
  let value: UInt64

  var body: some View {
    Text(NetFormat.bytes(Double(value)))
      .monospacedDigit()
      .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

/// 协议药丸:按协议 + 远端端口猜常见服务。定宽对齐;实色高饱和(系统 .teal / .indigo 在深色下发灰)。
private struct ProtocolPill: View {
  let proto: String
  let remote: String

  var body: some View {
    let (title, color) = style
    Text(title)
      .font(.system(size: 10, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: 44, height: 16)
      .background(color.gradient, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
  }

  private var style: (String, Color) {
    // nettop 的端口分隔符:IPv4 是 ":",IPv6 是 "."。
    let port = remote.split { $0 == ":" || $0 == "." }.last.map(String.init) ?? ""
    switch (proto.hasPrefix("tcp"), port) {
    case (true, "443"): return ("HTTPS", Color(red: 1, green: 0x8A/255, blue: 0))
    case (true, "80"): return ("HTTP", Color(red: 0x1F/255, green: 0x7A/255, blue: 1))
    case (false, "443"): return ("QUIC", Color(red: 0xA3/255, green: 0x4B/255, blue: 0xF5/255))
    case (false, "53"): return ("DNS", Color(red: 0x1D/255, green: 0xB3/255, blue: 0x6B/255))
    case (true, _): return ("TCP", Color(red: 0, green: 0xA2/255, blue: 0xE0/255))
    case (false, _): return ("UDP", Color(red: 0xEC/255, green: 0x40/255, blue: 0x8C/255))
    }
  }
}

// MARK: - 设置页

struct NetworkMonitorPage: View {
  private let store = GestureStore.shared

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(
          tag: "Network",
          title: "网络监控",
          subtitle: "菜单栏实时网速,点开查看哪些进程在占用网络。"
        )

        VStack(alignment: .leading, spacing: 0) {
          MGSectionLabel(text: "菜单栏")
          GroupCard {
            VStack(spacing: 0) {
              GroupRow(label: "在菜单栏显示网速", sub: "上行在上、下行在下,单位随网速自动切换;点击查看占用网络的进程") {
                Toggle("", isOn: Binding(
                  get: { store.preferences.networkMonitorEnabled },
                  set: { v in store.updatePreferences { $0.networkMonitorEnabled = v } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.mgAccent)
              }
              GroupRow(label: "网络面板", sub: "按进程查看实时流量与活动连接", showDivider: true) {
                Button("打开") { NetworkMonitorController.shared.showDashboard() }
                  .buttonStyle(MGSecondaryButtonStyle())
              }
            }
          }
        }
      }
      .padding(.horizontal, 32)
      .padding(.top, 28)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
