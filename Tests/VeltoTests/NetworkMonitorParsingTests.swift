import Testing

@testable import Velto

/// nettop CSV 解析与网速格式化。
@Test func nettopParsesProcessAndConnectionRows() {
  let text = """
  ,state,bytes_in,bytes_out,
  Google Chrome H.88999,,1200,300,
  tcp4 192.168.3.25:59456<->17.57.145.133:443,Established,165460,351579,
  udp6 *.*<->*.*,,,,
  tcp6 fe80::1%utun4.1028<->fe80::2%utun4.1025,Established,17966,37299,
  com.adguard.mac.805,,0,0,
  udp4 *:5353<->*:*,,,,
  """
  let flows = Nettop.parse(text)
  #expect(flows.count == 2)
  #expect(flows[0] == NetFlow(
    pid: 88999, process: "Google Chrome H", proto: "tcp4",
    local: "192.168.3.25:59456", remote: "17.57.145.133:443",
    state: "Established", rx: 165460, tx: 351579
  ))
  #expect(flows[1].remote == "fe80::2%utun4.1025")
  #expect(flows[1].pid == 88999)
}

@Test func speedAndBytesFormatting() {
  #expect(NetFormat.speed(0) == "0 KB/s")
  #expect(NetFormat.speed(300) == "0 KB/s")
  #expect(NetFormat.speed(999 * 1024) == "999 KB/s")
  #expect(NetFormat.speed(1000 * 1024) == "0.98 MB/s")
  #expect(NetFormat.speed(12.34 * 1024 * 1024) == "12.3 MB/s")
  #expect(NetFormat.speed(123.4 * 1024 * 1024) == "123 MB/s")
  #expect(NetFormat.bytes(512) == "512 B")
  #expect(NetFormat.bytes(1.5 * 1024 * 1024 * 1024) == "1.50 GB")
}

/// 四元组相同的 socket 在两次 nettop 里先后对调,不能把大的累计值当成这一轮的流量。
@MainActor @Test func duplicateSocketsReorderedDoNotInflateTraffic() {
  func mdns(_ rx: UInt64) -> NetFlow {
    NetFlow(pid: 999_999, process: "Chrome", proto: "udp6", local: "*.5353", remote: "*.*", state: "", rx: rx, tx: 0)
  }
  let monitor = NetworkMonitor()
  monitor.ingest([mdns(0), mdns(23_000_000)])
  monitor.ingest([mdns(23_000_100), mdns(0)])
  #expect(monitor.apps.map(\.totalDown) == [100])
  #expect(monitor.connections.count == 1)
}

/// 停采超过 3 秒再恢复(面板关了一阵再打开):上一轮的连接 / 进程速率先清零,不闪旧值。
@MainActor @Test func staleRatesClearedWhenSamplingResumes() async throws {
  func flow(_ rx: UInt64) -> NetFlow {
    NetFlow(pid: 999_999, process: "Chrome", proto: "tcp4", local: "10.0.0.2:5000", remote: "1.1.1.1:443", state: "Established", rx: rx, tx: 0)
  }
  let monitor = NetworkMonitor()
  monitor.ingest([flow(0)])
  monitor.ingest([flow(1000)])
  #expect(monitor.connections[0].down > 0)
  try await Task.sleep(for: .seconds(3.2))
  monitor.sampleProcesses()
  #expect(monitor.connections[0].down == 0)
  #expect(monitor.apps[0].down == 0)
}
