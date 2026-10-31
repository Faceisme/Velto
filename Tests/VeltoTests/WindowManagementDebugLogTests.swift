import Foundation
import Testing

@testable import Velto

/// 测试进程和运行中的 Velto 同时写一份日志时,双方的内容都不能丢。
@Test func logHandlesAppendWithoutOverwritingEachOther() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("velto-log-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: url) }
  let first = try #require(WindowManagementDebugLog.openForAppending(url))
  let second = try #require(WindowManagementDebugLog.openForAppending(url))

  try first.write(contentsOf: Data("甲\n".utf8))
  try second.write(contentsOf: Data("乙\n".utf8))
  try first.write(contentsOf: Data("丙\n".utf8))

  #expect(try String(contentsOf: url, encoding: .utf8) == "甲\n乙\n丙\n")
}

@Test func logHandleKeepsExistingContent() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("velto-log-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: url) }
  try Data("旧内容\n".utf8).write(to: url)

  let handle = try #require(WindowManagementDebugLog.openForAppending(url))
  try handle.write(contentsOf: Data("新内容\n".utf8))

  #expect(try String(contentsOf: url, encoding: .utf8) == "旧内容\n新内容\n")
}
