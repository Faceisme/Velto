import Foundation
import Testing

@testable import Velto

@Suite("日志文件")
struct LogFileWriterTests {
  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("velto-log-\(UUID().uuidString).log")
  }

  private func cleanUp(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
  }

  /// 测试进程和运行中的 Velto 同时写一份日志时,双方的内容都不能丢。
  @Test("两个写入方互不覆盖")
  func appendsWithoutOverwritingEachOther() throws {
    let url = temporaryURL()
    defer { cleanUp(url) }
    let first = LogFileWriter(url: url)
    let second = LogFileWriter(url: url)

    first.append(Data("甲\n".utf8))
    second.append(Data("乙\n".utf8))
    first.append(Data("丙\n".utf8))

    #expect(try String(contentsOf: url, encoding: .utf8) == "甲\n乙\n丙\n")
  }

  @Test("保留已有内容")
  func keepsExistingContent() throws {
    let url = temporaryURL()
    defer { cleanUp(url) }
    try Data("旧内容\n".utf8).write(to: url)

    LogFileWriter(url: url).append(Data("新内容\n".utf8))

    #expect(try String(contentsOf: url, encoding: .utf8) == "旧内容\n新内容\n")
  }

  @Test("超过上限后改名成 .1,只留一份旧的")
  func rotatesAtMaximumSize() throws {
    let url = temporaryURL()
    defer { cleanUp(url) }
    let archive = url.appendingPathExtension("1")
    let writer = LogFileWriter(url: url, maximumSize: 10)

    writer.append(Data("0123456789".utf8))
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try String(contentsOf: archive, encoding: .utf8) == "0123456789")

    writer.append(Data("新\n".utf8))
    #expect(try String(contentsOf: url, encoding: .utf8) == "新\n")

    writer.append(Data("abcdefghij".utf8))
    #expect(try String(contentsOf: archive, encoding: .utf8) == "新\nabcdefghij")
  }

  @Test("启动时已有的大小也算进上限")
  func countsExistingSize() throws {
    let url = temporaryURL()
    defer { cleanUp(url) }
    try Data("12345678".utf8).write(to: url)

    LogFileWriter(url: url, maximumSize: 10).append(Data("90".utf8))

    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8) == "1234567890")
  }

  @Test("文件被删后重新创建,不往旧 inode 里写")
  func reopensAfterDeletion() throws {
    let url = temporaryURL()
    defer { cleanUp(url) }
    let writer = LogFileWriter(url: url)
    writer.append(Data("一\n".utf8))
    try FileManager.default.removeItem(at: url)

    writer.append(Data("二\n".utf8))

    #expect(try String(contentsOf: url, encoding: .utf8) == "二\n")
  }

  @Test("环境变量强制开启时关不掉,开关只报告从关到开")
  func enabledFlag() {
    let log = DebugLogFile(name: "test", fileName: "test-\(UUID().uuidString).log", environmentKey: "VELTO_TEST_UNSET")
    #expect(!log.isEnabled)
    #expect(log.setEnabled(true))
    #expect(!log.setEnabled(true))
    #expect(log.isEnabled)
    #expect(!log.setEnabled(false))
    #expect(!log.isEnabled)
  }
}
