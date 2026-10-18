import CoreGraphics
import Foundation
import Testing

@testable import Velto

/// 按 App 的手势:和全局手势怎么叠加、同形状谁让位、识别时挑对那一套、备份兼容。

private func line(_ from: CGPoint, _ to: CGPoint) -> [StrokePoint] {
  (0...12).map { i in
    let t = CGFloat(i) / 12
    return StrokePoint(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
  }
}

private let leftStroke = line(CGPoint(x: 130, y: 80), CGPoint(x: 20, y: 80))
private let rightStroke = line(CGPoint(x: 20, y: 80), CGPoint(x: 130, y: 80))
private let downStroke = line(CGPoint(x: 80, y: 20), CGPoint(x: 80, y: 130))

private func shortcut(_ keyCode: UInt16, _ name: String) -> Shortcut {
  Shortcut(keyCode: keyCode, modifierFlags: 0, displayName: name)
}

private let globalBack = GestureCommand(name: "后退", templates: [leftStroke], shortcut: shortcut(33, "["))
private let globalForward = GestureCommand(name: "前进", templates: [rightStroke], shortcut: shortcut(30, "]"))
private let movistRewind = GestureCommand(name: "快退", templates: [leftStroke], shortcut: shortcut(123, "←"))
private let movistPause = GestureCommand(name: "暂停", templates: [downStroke], shortcut: shortcut(49, "空格"))

private func signature(_ command: GestureCommand) -> GestureDirection.Signature {
  GestureDirection.canonical(for: command.templates.map { $0.map(\.cgPoint) })
}

private func movist(includesGlobal: Bool) -> GestureAppProfile {
  GestureAppProfile(
    bundleIdentifier: "com.example.movist", displayName: "Movist", path: "/Applications/Movist.app",
    includesGlobalGestures: includesGlobal, gestures: [movistRewind, movistPause])
}

@Test func appGestureOverridesSameShapeGlobalOnly() {
  let overrides = GestureAppScope.overrides(
    appGestures: [movistRewind, movistPause], globalGestures: [globalBack, globalForward], signature: signature)
  // 「←」快退顶掉「←」后退;「→」前进没有同形状的专属手势,不受影响。
  #expect(overrides == [globalBack.id: movistRewind.id])
}

@Test func effectiveGesturesLayersAppOverGlobal() {
  let global = [globalBack, globalForward]
  // 没配专属手势的 App 就是全局那套。
  #expect(GestureAppScope.effectiveGestures(global: global, profile: nil, signature: signature).map(\.id)
    == global.map(\.id))
  // 同时用全局:专属 + 没被覆盖的全局。
  #expect(GestureAppScope.effectiveGestures(global: global, profile: movist(includesGlobal: true), signature: signature)
    .map(\.id) == [movistRewind.id, movistPause.id, globalForward.id])
  // 不用全局:只有专属。
  #expect(GestureAppScope.effectiveGestures(global: global, profile: movist(includesGlobal: false), signature: signature)
    .map(\.id) == [movistRewind.id, movistPause.id])
}

@Test func emptyAppGestureDoesNotOverride() {
  // 还没录样本的专属手势不该把全局手势顶掉。
  let blank = GestureCommand(name: "新手势", templates: [], shortcut: nil)
  #expect(GestureAppScope.overrides(appGestures: [blank], globalGestures: [globalBack], signature: signature).isEmpty)
}

@Test @MainActor func recognizerPicksAppGestureForSharedShape() throws {
  let recognizer = GestureRecognizer()
  let drawnLeft = leftStroke.map(\.cgPoint)
  let global = [globalBack, globalForward]

  // 全局:「←」是后退。
  let inGlobal = try #require(recognizer.bestCandidates(points: drawnLeft, commands: global, version: 1))
  #expect(inGlobal.best.command.id == globalBack.id)

  // Movist 里同一笔「←」命中快退;后退已让位,次近不会是同形状的它(不会被判成模糊)。
  let commands = GestureAppScope.effectiveGestures(global: global, profile: movist(includesGlobal: true)) {
    recognizer.signature(for: $0, version: 1)
  }
  let inMovist = try #require(recognizer.bestCandidates(points: drawnLeft, commands: commands, version: 1))
  #expect(inMovist.best.command.id == movistRewind.id)
  #expect((inMovist.runnerUpDistance ?? 1) - inMovist.best.distance >= GestureAppScope.sameShapeThreshold)
}

@Test func legacyBackupWithoutAppProfilesDecodes() throws {
  var json = try JSONSerialization.jsonObject(
    with: {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      return try encoder.encode(VeltoBackupFile(
        gestures: [globalBack], gestureAppProfiles: [movist(includesGlobal: true)], preferences: .defaults))
    }()) as! [String: Any]
  #expect(json["gestureAppProfiles"] != nil)

  // 旧备份没有这个字段:解码成 nil,导入时保留当前的专属手势而不是清空。
  json.removeValue(forKey: "gestureAppProfiles")
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let legacy = try decoder.decode(VeltoBackupFile.self, from: JSONSerialization.data(withJSONObject: json))
  #expect(legacy.gestureAppProfiles == nil)
  #expect(legacy.gestures.map(\.id) == [globalBack.id])
}

// MARK: - 鼠标按钮触发

private let middle = MouseButtonTrigger(button: 2, modifierFlags: 0)
private let commandMiddle = MouseButtonTrigger(button: 2, modifierFlags: 1 << 20)  // ⌘ + 中键
private let maximize = GestureCommand(
  name: "最大化", templates: [], buttonTrigger: middle, shortcut: shortcut(19, "⇧⌘2"))
private let movistPlay = GestureCommand(
  name: "播放", templates: [], buttonTrigger: middle, shortcut: shortcut(49, "空格"))

@Test func buttonTriggerDisplay() {
  #expect(middle.kbdKeys == ["中键"])
  #expect(commandMiddle.kbdKeys == ["⌘", "中键"])
  #expect(MouseButtonTrigger(button: 3, modifierFlags: 0).displayName == "后退侧键")
  #expect(MouseButtonTrigger(button: 6, modifierFlags: 0).displayName == "按钮 7")
}

@Test func appGestureOverridesSameButtonGlobal() {
  let overrides = GestureAppScope.overrides(
    appGestures: [movistPlay], globalGestures: [maximize, globalBack], signature: signature)
  #expect(overrides == [maximize.id: movistPlay.id])
}

@Test func buttonMapResolvesPerAppAndGlobal() {
  let withGlobal = movist(includesGlobal: true)
  var playOnly = movist(includesGlobal: false)
  playOnly.bundleIdentifier = "com.example.player"
  playOnly.gestures = [movistPlay]
  let map = GestureButtonMap(global: [maximize, globalBack], appProfiles: [withGlobal, playOnly], signature: signature)

  #expect(map.triggers == [middle])
  // 没配专属手势的 App、或拿不到 App:全局的中键 = 最大化。
  #expect(map.command(for: middle, bundleID: "com.apple.Safari")?.id == maximize.id)
  #expect(map.command(for: middle, bundleID: nil)?.id == maximize.id)
  // Movist 开着全局手势、自己没占中键:沿用全局。
  #expect(map.command(for: middle, bundleID: "com.example.movist")?.id == maximize.id)
  // 播放器把中键配成播放:专属的覆盖全局的。
  #expect(map.command(for: middle, bundleID: "com.example.player")?.id == movistPlay.id)
  // 修饰键必须完全相同。
  #expect(map.command(for: commandMiddle, bundleID: nil) == nil)
}

@Test func buttonMapSkipsGesturesWithoutShortcut() {
  // 专属手势占了中键却没设快捷键:全局的最大化让位,这个 App 里中键原样放行。
  var silent = movistPlay
  silent.shortcut = nil
  let profile = GestureAppProfile(
    bundleIdentifier: "com.example.player", displayName: "Player", path: "/Applications/Player.app",
    gestures: [silent])
  let map = GestureButtonMap(global: [maximize], appProfiles: [profile], signature: signature)
  #expect(map.command(for: middle, bundleID: "com.example.player") == nil)
  #expect(map.command(for: middle, bundleID: "com.apple.Safari")?.id == maximize.id)
}

@Test func legacyGestureWithoutButtonTriggerDecodes() throws {
  var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(globalBack)) as! [String: Any]
  #expect(json["buttonTrigger"] == nil)  // nil 不编码
  json.removeValue(forKey: "buttonTrigger")
  let decoded = try JSONDecoder().decode(GestureCommand.self, from: JSONSerialization.data(withJSONObject: json))
  #expect(decoded == globalBack)
  let roundTrip = try JSONDecoder().decode(GestureCommand.self, from: JSONEncoder().encode(maximize))
  #expect(roundTrip.buttonTrigger == middle)
}
