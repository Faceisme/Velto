import Foundation
import Testing

private func switcherHotPathSource(_ file: String) throws -> String {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  return try String(
    contentsOf: root.appendingPathComponent("Sources/Velto/Switcher/\(file)"),
    encoding: .utf8
  )
}

private func sourceSection(
  _ source: String,
  from startMarker: String,
  until endMarker: String
) throws -> Substring {
  let start = try #require(source.range(of: startMarker))
  let end = try #require(source.range(
    of: endMarker,
    range: start.upperBound..<source.endIndex
  ))
  return source[start.lowerBound..<end.lowerBound]
}

@Test func axNotificationRegistrationDoesNotBlockMainActor() throws {
  let source = try switcherHotPathSource("SwitcherApp.swift")
  let startObserving = try sourceSection(
    source,
    from: "func startObserving(",
    until: "func stopObserving()"
  )

  #expect(startObserving.contains("AXCallQueue.shared.submit"))
  #expect(!startObserving.contains("AXObserverAddNotification"))
  #expect(source.contains("AXObserverAddNotification("))
}

@Test func windowNotificationMutationsDoNotBlockMainActor() throws {
  let source = try switcherHotPathSource("SwitcherWindowList.swift")
  let subscribe = try sourceSection(
    source,
    from: "private func subscribeWindowNotifications(",
    until: "private func unsubscribeWindowNotifications("
  )
  let unsubscribe = try sourceSection(
    source,
    from: "private func unsubscribeWindowNotifications(",
    until: "private func window(matching element:"
  )

  #expect(subscribe.contains("AXCallQueue.shared.submit"))
  #expect(!subscribe.contains("AXObserverAddNotification"))
  #expect(unsubscribe.contains("AXCallQueue.shared.submit"))
  #expect(!unsubscribe.contains("AXObserverRemoveNotification"))
}

@Test func ghostProbeReadsSpacesInsideDetachedTask() throws {
  let source = try switcherHotPathSource("SwitcherWindowList.swift")
  let runProbe = try sourceSection(
    source,
    from: "private func runGhostProbeNow()",
    until: "private func applyGhostProbe("
  )
  let detached = try #require(runProbe.range(of: "Task.detached"))
  let allSpaces = try #require(runProbe.range(of: "SwitcherSpaces.allSpaceIds()"))
  let visibleSpaces = try #require(runProbe.range(of: "SwitcherSpaces.visibleSpaceIds()"))
  let probe = try #require(runProbe.range(of: "SwitcherGhostDetector.probe(across:"))

  #expect(detached.lowerBound < allSpaces.lowerBound)
  #expect(detached.lowerBound < visibleSpaces.lowerBound)
  #expect(allSpaces.lowerBound < probe.lowerBound)
  #expect(visibleSpaces.lowerBound < probe.lowerBound)
}
