import Foundation
import SystemConfiguration

// 主网卡识别与字节计数改编自 exelban/stats 的 Net 模块(Modules/Net/readers.swift)。
// Attribution and MIT license: Resources/ThirdPartyNotices/Stats.md.

/// 物理主网卡:识别 + 累计收发字节(sysctl,几乎零开销,菜单栏每秒读一次)。
enum NetInterface {
  /// 当前出网的物理网卡 BSD 名(如 en0)。VPN / Surge 增强模式把默认路由交给 utun 时,
  /// 退回它底下真正出网的物理网卡 —— 否则代理流量会在 utun 和物理网卡上各算一遍。
  static func primary() -> String? {
    let store = SCDynamicStoreCreate(nil, "Velto" as CFString, nil, nil)
    func value(_ key: String) -> [String: Any]? {
      SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }
    if let name = value("State:/Network/Global/IPv4")?["PrimaryInterface"] as? String, !isVirtual(name) {
      return name
    }
    for id in value("Setup:/Network/Global/IPv4")?["ServiceOrder"] as? [String] ?? [] {
      guard let service = value("State:/Network/Service/\(id)/IPv4"), service["Router"] != nil,
            let name = service["InterfaceName"] as? String, !isVirtual(name) else { continue }
      return name
    }
    return ipv4Interfaces().first { !isVirtual($0.name) }?.name
  }

  /// 弹窗里显示用:"Wi-Fi · en0 · 192.168.3.25"。
  static func describe(_ bsd: String) -> String {
    let interfaces = (SCNetworkInterfaceCopyAll() as NSArray).map { $0 as! SCNetworkInterface }
    let name = interfaces.first { SCNetworkInterfaceGetBSDName($0) as String? == bsd }
      .flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
    let address = ipv4Interfaces().first { $0.name == bsd }?.address
    return [name, bsd, address].compactMap { $0 }.joined(separator: " · ")
  }

  /// 网卡累计收发字节(64 位计数)。改编自 Stats `getBytesInfo()`。
  static func bytes(_ bsd: String) -> (up: UInt64, down: UInt64)? {
    let index = if_nametoindex(bsd)
    guard index != 0 else { return nil }
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
    return buffer.withUnsafeBytes { raw -> (up: UInt64, down: UInt64)? in
      var offset = 0
      while offset + MemoryLayout<if_msghdr>.size <= size {
        let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
        guard header.ifm_msglen > 0 else { return nil }
        if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= size {
          let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
          if UInt32(info.ifm_index) == index {
            return (info.ifm_data.ifi_obytes, info.ifm_data.ifi_ibytes)
          }
        }
        offset += Int(header.ifm_msglen)
      }
      return nil
    }
  }

  private static func isVirtual(_ name: String) -> Bool {
    ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "wg"].contains(where: name.hasPrefix)
  }

  /// 已启用的 IPv4 网卡(非回环、非点对点)及其地址。
  private static func ipv4Interfaces() -> [(name: String, address: String)] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return [] }
    defer { freeifaddrs(list) }
    var result: [(name: String, address: String)] = []
    var cursor = list
    while let entry = cursor?.pointee {
      cursor = entry.ifa_next
      let flags = Int32(bitPattern: entry.ifa_flags)
      guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
            flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING),
            flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
      // s_addr 是网络字节序,内存里的 4 个字节依次就是 a.b.c.d。
      let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
      result.append((String(cString: entry.ifa_name), withUnsafeBytes(of: ip) { $0.map(String.init).joined(separator: ".") }))
    }
    return result
  }
}

/// nettop 一次采样里的一条连接;字节是该连接建立以来的累计值。
struct NetFlow: Equatable {
  var pid: Int32
  var process: String  // nettop 给的进程名,最多 15 个字符
  var proto: String    // tcp4 / tcp6 / udp4 / udp6
  var local: String
  var remote: String
  var state: String    // TCP 状态,UDP 为空
  var rx: UInt64
  var tx: UInt64
}

enum Nettop {
  /// 跑一次 `nettop -L 1` 拿全部连接,约 70ms CPU。
  /// ⚠️ 别加 interface 列:带上它 nettop 每次要烧约 1s CPU。
  static func sample() -> [NetFlow]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    process.arguments = ["-L", "1", "-n", "-x", "-J", "state,bytes_in,bytes_out"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    // 输出约 40KB,超过管道缓冲,必须边跑边读;卡死兜底 5s 直接杀。
    let pid = process.processIdentifier
    let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    watchdog.cancel()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
    return parse(String(decoding: data, as: UTF8.self))
  }

  /// `-J state,bytes_in,bytes_out` 的 CSV:进程行 `Surge.653,,74029602,73974618,`
  /// 后面跟它的连接行 `tcp4 192.168.3.25:59456<->17.57.145.133:5223,Established,165460,351579,`。
  /// 字节为空的(监听、没收发过的通配 UDP)跳过。
  static func parse(_ text: String) -> [NetFlow] {
    var flows: [NetFlow] = []
    var pid: Int32?
    var process = ""
    for line in text.split(separator: "\n") {
      let cols = line.split(separator: ",", omittingEmptySubsequences: false)
      guard cols.count >= 4, let head = cols.first, !head.isEmpty else { continue }
      if head.contains("<->"), let space = head.firstIndex(of: " ") {
        let ends = head[head.index(after: space)...].components(separatedBy: "<->")
        guard let pid, ends.count == 2, let rx = UInt64(cols[2]), let tx = UInt64(cols[3]) else { continue }
        flows.append(NetFlow(
          pid: pid, process: process, proto: String(head[..<space]),
          local: ends[0], remote: ends[1], state: String(cols[1]), rx: rx, tx: tx
        ))
      } else {
        let dot = head.lastIndex(of: ".")
        pid = dot.flatMap { Int32(head[head.index(after: $0)...]) }
        process = dot.map { String(head[..<$0]) } ?? String(head)
      }
    }
    return flows
  }
}
