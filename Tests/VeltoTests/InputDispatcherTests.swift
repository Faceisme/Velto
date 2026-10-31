import CoreGraphics
import Testing

@testable import Velto

/// 事件分发的特征测试:把每种事件交给哪些模块、什么顺序、谁能吞掉都固定下来。
/// 这些顺序就是功能之间的优先级,改动时这里会先红。
///
/// 用假模块记录调用,不依赖真实的 tap、权限和配置。
private final class Recorder {
  var calls: [String] = []
  /// 这些调用返回 true,也就是吞掉事件。
  var consuming: Set<String> = []

  func hit(_ name: String) -> Bool {
    calls.append(name)
    return consuming.contains(name)
  }
}

private final class FakeKeyRemap: KeyRemapInput {
  let recorder: Recorder
  init(_ recorder: Recorder) { self.recorder = recorder }
  func handleFlagsChanged(event: CGEvent) -> Bool { recorder.hit("keyRemap.flags") }
  func handleKeyDown(event: CGEvent) -> Bool { recorder.hit("keyRemap.keyDown") }
  func handleKeyUp(event: CGEvent) -> Bool { recorder.hit("keyRemap.keyUp") }
}

private final class FakePunctuation: PunctuationInput {
  let recorder: Recorder
  init(_ recorder: Recorder) { self.recorder = recorder }
  func handleKeyDown(event: CGEvent) -> Bool { recorder.hit("punctuation.keyDown") }
  func shouldConsumeKeyUp(event: CGEvent) -> Bool { recorder.hit("punctuation.keyUp") }
  func noteMouseDown() { _ = recorder.hit("punctuation.mouseDown") }
}

private final class FakeMouseControl: MouseTriggerInput {
  let recorder: Recorder
  var lastType: CGEventType?
  init(_ recorder: Recorder) { self.recorder = recorder }
  func handleTriggerEvent(type: CGEventType, event: CGEvent, normalizedFlags: UInt64) -> Bool {
    lastType = type
    return recorder.hit("mouseControl")
  }
}

private final class FakeGesture: GestureInput {
  let recorder: Recorder
  var isHandlingRightMouse = false
  var holdingButtons: Set<Int64> = []
  init(_ recorder: Recorder) { self.recorder = recorder }
  func handleRightMouseDown(at location: CGPoint, originalEvent: CGEvent?) -> Bool { recorder.hit("gesture.down") }
  func handleRightMouseDragged(at location: CGPoint) -> Bool { recorder.hit("gesture.dragged") }
  func handleRightMouseUp(at location: CGPoint, originalEvent: CGEvent?) -> Bool { recorder.hit("gesture.up") }
  func handleButtonTriggerDown(event: CGEvent, normalizedFlags: UInt64) -> Bool { recorder.hit("gesture.buttonDown") }
  func handleButtonTriggerUp(button: Int64) -> Bool { recorder.hit("gesture.buttonUp") }
  func isHoldingTriggerButton(_ button: Int64) -> Bool { holdingButtons.contains(button) }
}

/// 增强 Finder、截图只用到 `handleKeyDown`,和窗口快捷键共用一个假实现。
private final class FakeShortcut: WindowShortcutInput {
  let name: String
  let recorder: Recorder
  var holdingButtons: Set<Int64> = []
  init(_ name: String, _ recorder: Recorder) {
    self.name = name
    self.recorder = recorder
  }
  func handleKeyDown(event: CGEvent, normalizedFlags raw: UInt64) -> Bool { recorder.hit("\(name).keyDown") }
  func handleMouseDown(event: CGEvent, normalizedFlags raw: UInt64) -> Bool { recorder.hit("\(name).buttonDown") }
  func handleMouseUp(button: Int64) -> Bool { recorder.hit("\(name).buttonUp") }
  func isHoldingButton(_ button: Int64) -> Bool { holdingButtons.contains(button) }
}

private final class FakeWindowDrag: WindowDragInput {
  let recorder: Recorder
  var mode: WindowDragController.DragMode?
  var movedTo: CGPoint?
  init(_ recorder: Recorder) { self.recorder = recorder }
  func dragMode(forNormalizedFlags raw: UInt64) -> WindowDragController.DragMode? { mode }
  func handleMouseMoved(at location: CGPoint, mode: WindowDragController.DragMode) {
    movedTo = location
    _ = recorder.hit("windowDrag.moved")
  }
  func handleFlagsChanged(event: CGEvent, normalizedFlags raw: UInt64) { _ = recorder.hit("windowDrag.flags") }
}

private final class FakeContentZoom: ContentZoomInput {
  let recorder: Recorder
  init(_ recorder: Recorder) { self.recorder = recorder }
  func handleFlagsChanged(normalizedFlags raw: UInt64) { _ = recorder.hit("contentZoom.flags") }
}

private final class Harness {
  let recorder = Recorder()
  let gesture: FakeGesture
  let mouseControl: FakeMouseControl
  let windowShortcut: FakeShortcut
  let windowDrag: FakeWindowDrag
  let dispatcher: InputDispatcher
  var inPassThrough = false

  init() {
    gesture = FakeGesture(recorder)
    mouseControl = FakeMouseControl(recorder)
    windowShortcut = FakeShortcut("windowShortcut", recorder)
    windowDrag = FakeWindowDrag(recorder)
    dispatcher = InputDispatcher(modules: .init(
      keyRemap: FakeKeyRemap(recorder),
      punctuation: FakePunctuation(recorder),
      mouseControl: mouseControl,
      gesture: gesture,
      betterFinder: FakeShortcut("betterFinder", recorder),
      screenshot: FakeShortcut("screenshot", recorder),
      windowShortcut: windowShortcut,
      windowDrag: windowDrag,
      contentZoom: FakeContentZoom(recorder)
    ))
    dispatcher.isInRightClickPassThrough = { [unowned self] _ in inPassThrough }
    dispatcher.rewritePointerLocation = { [recorder] _ in _ = recorder.hit("rewrite") }
  }

  /// 先定类型再写字段:按钮号这类字段只对鼠标类型的事件生效。
  func event(
    _ type: CGEventType, marker: Int64 = 0, flags: CGEventFlags = [], button: Int64 = 0
  ) throws -> CGEvent {
    let event = try #require(CGEvent(source: nil))
    event.type = type
    event.setIntegerValueField(.eventSourceUserData, value: marker)
    event.setIntegerValueField(.mouseEventButtonNumber, value: button)
    event.flags = flags
    event.location = CGPoint(x: 10, y: 20)
    return event
  }

  func send(_ type: CGEventType, marker: Int64 = 0, flags: CGEventFlags = [], button: Int64 = 0) throws -> Bool {
    try dispatcher.dispatch(type: type, event: event(type, marker: marker, flags: flags, button: button))
  }
}

private let shortcutMarker = ShortcutSynthesizer.syntheticEventMarker
private let punctuationMarker = InputSourcePunctuationController.syntheticEventMarker
private let inputSourceFixMarker = InputSourceSwitchSelector.syntheticEventMarker
private let replayMarker = GestureEngine.rightClickReplayMarker

// MARK: - keyDown

private let keyDownChain = [
  "keyRemap.keyDown", "mouseControl", "betterFinder.keyDown", "screenshot.keyDown",
  "punctuation.keyDown", "windowShortcut.keyDown",
]

@Suite("事件分发:keyDown")
struct InputDispatcherKeyDownTests {
  @Test("真实按键依次经过全部模块")
  func fullChain() throws {
    let harness = Harness()
    #expect(try !harness.send(.keyDown))
    #expect(harness.recorder.calls == keyDownChain)
    #expect(harness.mouseControl.lastType == .keyDown)
  }

  @Test("谁吞掉,后面的模块就不再处理", arguments: keyDownChain.indices)
  func stopsAtConsumer(index: Int) throws {
    let harness = Harness()
    harness.recorder.consuming = [keyDownChain[index]]
    #expect(try harness.send(.keyDown))
    #expect(harness.recorder.calls == Array(keyDownChain[...index]))
  }

  /// 手势画到一半按键:只有按键映射还生效。
  @Test("手势进行中只走按键映射")
  func duringGesture() throws {
    let harness = Harness()
    harness.gesture.isHandlingRightMouse = true
    #expect(try !harness.send(.keyDown))
    #expect(harness.recorder.calls == ["keyRemap.keyDown"])
  }

  @Test("窗口管理关掉后不走窗口快捷键")
  func windowManagementOff() throws {
    let harness = Harness()
    harness.dispatcher.windowManagementEnabled = false
    #expect(try !harness.send(.keyDown))
    #expect(harness.recorder.calls == Array(keyDownChain.dropLast()))
  }

  /// 手势发出的快捷键可能正是 Velto 自己的全局快捷键,但不能再被按键映射、强制标点改写。
  @Test("合成的快捷键只走 Velto 自己的全局快捷键")
  func synthesizedShortcut() throws {
    let harness = Harness()
    #expect(try !harness.send(.keyDown, marker: shortcutMarker))
    #expect(harness.recorder.calls == ["betterFinder.keyDown", "screenshot.keyDown", "windowShortcut.keyDown"])
  }

  @Test("合成的快捷键命中时吞掉")
  func synthesizedShortcutConsumed() throws {
    let harness = Harness()
    harness.recorder.consuming = ["screenshot.keyDown"]
    #expect(try harness.send(.keyDown, marker: shortcutMarker))
    #expect(harness.recorder.calls == ["betterFinder.keyDown", "screenshot.keyDown"])
  }

  /// 手势进行中也要能走:合成快捷键不受手势状态影响。
  @Test("合成的快捷键不受手势进行中影响")
  func synthesizedShortcutDuringGesture() throws {
    let harness = Harness()
    harness.gesture.isHandlingRightMouse = true
    _ = try harness.send(.keyDown, marker: shortcutMarker)
    #expect(harness.recorder.calls.count == 3)
  }

  @Test("窗口管理关掉后合成的快捷键也不走窗口快捷键")
  func synthesizedShortcutWindowManagementOff() throws {
    let harness = Harness()
    harness.dispatcher.windowManagementEnabled = false
    _ = try harness.send(.keyDown, marker: shortcutMarker)
    #expect(harness.recorder.calls == ["betterFinder.keyDown", "screenshot.keyDown"])
  }

  @Test("强制标点和输入法修复合成的按键原样放行", arguments: [punctuationMarker, inputSourceFixMarker])
  func ownSyntheticPasses(marker: Int64) throws {
    let harness = Harness()
    #expect(try !harness.send(.keyDown, marker: marker))
    #expect(harness.recorder.calls.isEmpty)
  }
}

// MARK: - keyUp

private let keyUpChain = ["punctuation.keyUp", "keyRemap.keyUp", "mouseControl"]

@Suite("事件分发:keyUp")
struct InputDispatcherKeyUpTests {
  @Test("真实按键依次经过全部模块")
  func fullChain() throws {
    let harness = Harness()
    #expect(try !harness.send(.keyUp))
    #expect(harness.recorder.calls == keyUpChain)
    #expect(harness.mouseControl.lastType == .keyUp)
  }

  @Test("谁吞掉,后面的模块就不再处理", arguments: keyUpChain.indices)
  func stopsAtConsumer(index: Int) throws {
    let harness = Harness()
    harness.recorder.consuming = [keyUpChain[index]]
    #expect(try harness.send(.keyUp))
    #expect(harness.recorder.calls == Array(keyUpChain[...index]))
  }

  @Test("手势进行中不走鼠标控制")
  func duringGesture() throws {
    let harness = Harness()
    harness.gesture.isHandlingRightMouse = true
    #expect(try !harness.send(.keyUp))
    #expect(harness.recorder.calls == ["punctuation.keyUp", "keyRemap.keyUp"])
  }

  @Test("合成的按键原样放行", arguments: [shortcutMarker, punctuationMarker, inputSourceFixMarker])
  func syntheticPasses(marker: Int64) throws {
    let harness = Harness()
    #expect(try !harness.send(.keyUp, marker: marker))
    #expect(harness.recorder.calls.isEmpty)
  }
}

// MARK: - flagsChanged

@Suite("事件分发:修饰键")
struct InputDispatcherFlagsChangedTests {
  private let chain = ["keyRemap.flags", "mouseControl", "contentZoom.flags", "windowDrag.flags"]

  @Test("真实修饰键依次经过全部模块")
  func fullChain() throws {
    let harness = Harness()
    #expect(try !harness.send(.flagsChanged))
    #expect(harness.recorder.calls == chain)
    #expect(harness.mouseControl.lastType == .flagsChanged)
  }

  @Test("按键映射吞掉后不再处理")
  func keyRemapConsumes() throws {
    let harness = Harness()
    harness.recorder.consuming = ["keyRemap.flags"]
    #expect(try harness.send(.flagsChanged))
    #expect(harness.recorder.calls == ["keyRemap.flags"])
  }

  /// 修饰键状态机要看到每一次变化:鼠标控制吞掉事件时,缩放和拖窗也得知道。
  @Test("鼠标控制吞掉后内容缩放和拖窗仍能看到")
  func mouseControlConsumesButOthersStillSee() throws {
    let harness = Harness()
    harness.recorder.consuming = ["mouseControl"]
    #expect(try harness.send(.flagsChanged))
    #expect(harness.recorder.calls == chain)
  }

  @Test("手势进行中只走按键映射")
  func duringGesture() throws {
    let harness = Harness()
    harness.gesture.isHandlingRightMouse = true
    #expect(try !harness.send(.flagsChanged))
    #expect(harness.recorder.calls == ["keyRemap.flags"])
  }

  @Test("窗口管理关掉后不走缩放和拖窗")
  func windowManagementOff() throws {
    let harness = Harness()
    harness.dispatcher.windowManagementEnabled = false
    _ = try harness.send(.flagsChanged)
    #expect(harness.recorder.calls == ["keyRemap.flags", "mouseControl"])
  }

  /// 合成的修饰键不能污染鼠标控制、缩放、拖窗的修饰键状态机。
  @Test("合成的修饰键原样放行", arguments: [shortcutMarker, punctuationMarker, inputSourceFixMarker])
  func syntheticPasses(marker: Int64) throws {
    let harness = Harness()
    #expect(try !harness.send(.flagsChanged, marker: marker))
    #expect(harness.recorder.calls.isEmpty)
  }
}

// MARK: - 右键

@Suite("事件分发:右键")
struct InputDispatcherRightMouseTests {
  @Test("按下交给手势并吞掉")
  func downGoesToGesture() throws {
    let harness = Harness()
    #expect(try harness.send(.rightMouseDown))
    #expect(harness.recorder.calls == ["mouseControl", "gesture.down"])
    #expect(harness.mouseControl.lastType == .rightMouseDown)
  }

  @Test("手势关掉时按下放行,系统右键菜单正常")
  func downWithGesturesOff() throws {
    let harness = Harness()
    harness.dispatcher.gesturesEnabled = false
    #expect(try !harness.send(.rightMouseDown))
    #expect(harness.recorder.calls == ["mouseControl"])
  }

  @Test("鼠标控制绑定了右键时不进手势")
  func downConsumedByMouseControl() throws {
    let harness = Harness()
    harness.recorder.consuming = ["mouseControl"]
    #expect(try harness.send(.rightMouseDown))
    #expect(harness.recorder.calls == ["mouseControl"])
  }

  @Test("透传区内按下原样放行")
  func downInPassThrough() throws {
    let harness = Harness()
    harness.inPassThrough = true
    #expect(try !harness.send(.rightMouseDown))
    #expect(harness.recorder.calls.isEmpty)
  }

  @Test("补发的右键原样放行", arguments: [
    CGEventType.rightMouseDown, .rightMouseDragged, .rightMouseUp,
  ])
  func replayedPasses(type: CGEventType) throws {
    let harness = Harness()
    #expect(try !harness.send(type, marker: replayMarker))
    #expect(harness.recorder.calls.filter { $0 != "rewrite" }.isEmpty)
  }

  @Test("手势接管的拖动降级成 mouseMoved,不吞")
  func draggedDowngrades() throws {
    let harness = Harness()
    harness.recorder.consuming = ["gesture.dragged"]
    let event = try harness.event(.rightMouseDragged, button: 1)
    event.setDoubleValueField(.mouseEventPressure, value: 1)

    #expect(!harness.dispatcher.dispatch(type: .rightMouseDragged, event: event))

    #expect(event.type == .mouseMoved)
    #expect(event.getIntegerValueField(.mouseEventButtonNumber) == 0)
    #expect(event.getDoubleValueField(.mouseEventPressure) == 0)
  }

  @Test("手势没接管的拖动保持原样")
  func draggedUntouched() throws {
    let harness = Harness()
    let event = try harness.event(.rightMouseDragged, button: 1)

    #expect(!harness.dispatcher.dispatch(type: .rightMouseDragged, event: event))

    #expect(event.type == .rightMouseDragged)
    #expect(event.getIntegerValueField(.mouseEventButtonNumber) == 1)
  }

  @Test("透传区内拖动不进手势")
  func draggedInPassThrough() throws {
    let harness = Harness()
    harness.inPassThrough = true
    #expect(try !harness.send(.rightMouseDragged))
    #expect(!harness.recorder.calls.contains("gesture.dragged"))
  }

  /// 手势在卡片外起手后飘进透传区,必须继续交给引擎,否则 up 被透传走、引擎卡死。
  @Test("手势进行中飘进透传区仍交给手势")
  func gestureKeepsEventsInsidePassThrough() throws {
    let harness = Harness()
    harness.inPassThrough = true
    harness.gesture.isHandlingRightMouse = true
    _ = try harness.send(.rightMouseDragged)
    _ = try harness.send(.rightMouseUp)
    #expect(harness.recorder.calls == ["rewrite", "gesture.dragged", "mouseControl", "gesture.up"])
  }

  @Test("松开先过鼠标控制再过手势")
  func upOrder() throws {
    let harness = Harness()
    #expect(try !harness.send(.rightMouseUp))
    #expect(harness.recorder.calls == ["mouseControl", "gesture.up"])
    #expect(harness.mouseControl.lastType == .rightMouseUp)
  }

  @Test("手势认领的松开吞掉")
  func upConsumedByGesture() throws {
    let harness = Harness()
    harness.recorder.consuming = ["gesture.up"]
    #expect(try harness.send(.rightMouseUp))
  }

  @Test("鼠标控制吞掉松开时不进手势")
  func upConsumedByMouseControl() throws {
    let harness = Harness()
    harness.recorder.consuming = ["mouseControl"]
    #expect(try harness.send(.rightMouseUp))
    #expect(harness.recorder.calls == ["mouseControl"])
  }

  @Test("透传区内松开原样放行")
  func upInPassThrough() throws {
    let harness = Harness()
    harness.inPassThrough = true
    #expect(try !harness.send(.rightMouseUp))
    #expect(harness.recorder.calls.isEmpty)
  }
}

// MARK: - 其他鼠标事件

@Suite("事件分发:其他鼠标事件")
struct InputDispatcherMouseTests {
  @Test("左键按下:鼠标控制之后通知强制标点")
  func leftDown() throws {
    let harness = Harness()
    #expect(try !harness.send(.leftMouseDown))
    #expect(harness.recorder.calls == ["mouseControl", "punctuation.mouseDown"])
    #expect(harness.mouseControl.lastType == .leftMouseDown)
  }

  /// 事件被吞掉就没到 App,IME 组字不受影响,不用通知。
  @Test("左键按下被吞掉时不通知强制标点")
  func leftDownConsumed() throws {
    let harness = Harness()
    harness.recorder.consuming = ["mouseControl"]
    #expect(try harness.send(.leftMouseDown))
    #expect(harness.recorder.calls == ["mouseControl"])
  }

  @Test("左键松开只过鼠标控制")
  func leftUp() throws {
    let harness = Harness()
    #expect(try !harness.send(.leftMouseUp))
    #expect(harness.recorder.calls == ["mouseControl"])
  }

  @Test("其他按键按下:鼠标控制 → 手势 → 最大化 → 强制标点")
  func otherDownOrder() throws {
    let harness = Harness()
    #expect(try !harness.send(.otherMouseDown))
    #expect(harness.recorder.calls == [
      "mouseControl", "gesture.buttonDown", "windowShortcut.buttonDown", "punctuation.mouseDown",
    ])
  }

  @Test("同一按钮手势优先于最大化")
  func gestureWinsOverMaximize() throws {
    let harness = Harness()
    harness.recorder.consuming = ["gesture.buttonDown"]
    #expect(try harness.send(.otherMouseDown))
    #expect(harness.recorder.calls == ["mouseControl", "gesture.buttonDown"])
  }

  @Test("手势关掉后不走手势按钮")
  func otherDownGesturesOff() throws {
    let harness = Harness()
    harness.dispatcher.gesturesEnabled = false
    _ = try harness.send(.otherMouseDown)
    #expect(!harness.recorder.calls.contains("gesture.buttonDown"))
    #expect(harness.recorder.calls.contains("windowShortcut.buttonDown"))
  }

  @Test("窗口管理关掉后不走最大化按钮")
  func otherDownWindowManagementOff() throws {
    let harness = Harness()
    harness.dispatcher.windowManagementEnabled = false
    _ = try harness.send(.otherMouseDown)
    #expect(harness.recorder.calls.contains("gesture.buttonDown"))
    #expect(!harness.recorder.calls.contains("windowShortcut.buttonDown"))
  }

  /// 按住期间关掉开关,抬起也得一并吞,不然 App 会收到一个没有按下的抬起。
  @Test("其他按键抬起不看开关")
  func otherUpIgnoresToggles() throws {
    let harness = Harness()
    harness.dispatcher.gesturesEnabled = false
    harness.dispatcher.windowManagementEnabled = false
    #expect(try !harness.send(.otherMouseUp, button: 2))
    #expect(harness.recorder.calls == ["mouseControl", "gesture.buttonUp", "windowShortcut.buttonUp"])
  }

  @Test("手势认领的抬起不再问最大化")
  func otherUpConsumedByGesture() throws {
    let harness = Harness()
    harness.recorder.consuming = ["gesture.buttonUp"]
    #expect(try harness.send(.otherMouseUp))
    #expect(harness.recorder.calls == ["mouseControl", "gesture.buttonUp"])
  }

  @Test("手势按住的按钮拖动降级成 mouseMoved")
  func otherDraggedHeldByGesture() throws {
    let harness = Harness()
    harness.gesture.holdingButtons = [3]
    let event = try harness.event(.otherMouseDragged, button: 3)
    #expect(!harness.dispatcher.dispatch(type: .otherMouseDragged, event: event))
    #expect(event.type == .mouseMoved)
    #expect(event.getIntegerValueField(.mouseEventButtonNumber) == 0)
  }

  @Test("最大化按住的按钮拖动降级成 mouseMoved")
  func otherDraggedHeldByWindowShortcut() throws {
    let harness = Harness()
    harness.windowShortcut.holdingButtons = [3]
    let event = try harness.event(.otherMouseDragged, button: 3)
    #expect(!harness.dispatcher.dispatch(type: .otherMouseDragged, event: event))
    #expect(event.type == .mouseMoved)
  }

  @Test("没人按住的按钮拖动保持原样")
  func otherDraggedUntouched() throws {
    let harness = Harness()
    let event = try harness.event(.otherMouseDragged, button: 3)
    #expect(!harness.dispatcher.dispatch(type: .otherMouseDragged, event: event))
    #expect(event.type == .otherMouseDragged)
  }

  @Test("按住修饰键移动鼠标时拖窗")
  func mouseMovedDrags() throws {
    let harness = Harness()
    harness.windowDrag.mode = .move
    #expect(try !harness.send(.mouseMoved, flags: .maskAlternate))
    #expect(harness.recorder.calls == ["rewrite", "windowDrag.moved"])
    #expect(harness.windowDrag.movedTo == CGPoint(x: 10, y: 20))
  }

  @Test("没按修饰键不拖窗")
  func mouseMovedWithoutModifier() throws {
    let harness = Harness()
    harness.windowDrag.mode = .move
    _ = try harness.send(.mouseMoved)
    #expect(harness.recorder.calls == ["rewrite"])
  }

  @Test("修饰键不是拖窗键时不拖窗")
  func mouseMovedWithOtherModifier() throws {
    let harness = Harness()
    _ = try harness.send(.mouseMoved, flags: .maskAlternate)
    #expect(harness.recorder.calls == ["rewrite"])
  }

  @Test("手势进行中不拖窗")
  func mouseMovedDuringGesture() throws {
    let harness = Harness()
    harness.windowDrag.mode = .move
    harness.gesture.isHandlingRightMouse = true
    _ = try harness.send(.mouseMoved, flags: .maskAlternate)
    #expect(harness.recorder.calls == ["rewrite"])
  }

  @Test("窗口管理关掉后不拖窗")
  func mouseMovedWindowManagementOff() throws {
    let harness = Harness()
    harness.windowDrag.mode = .move
    harness.dispatcher.windowManagementEnabled = false
    _ = try harness.send(.mouseMoved, flags: .maskAlternate)
    #expect(harness.recorder.calls == ["rewrite"])
  }
}

// MARK: - 坐标改写

@Suite("事件分发:坐标改写")
struct InputDispatcherRewriteTests {
  /// 触发角和程序坞遮挡要在所有模块看到坐标之前改好。
  @Test("移动类事件最先改写坐标", arguments: [
    CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
  ])
  func movementRewritesFirst(type: CGEventType) throws {
    let harness = Harness()
    harness.windowDrag.mode = .move
    _ = try harness.send(type, flags: .maskAlternate)
    #expect(harness.recorder.calls.first == "rewrite")
    #expect(harness.recorder.calls.filter { $0 == "rewrite" }.count == 1)
  }

  @Test("其他事件不改写坐标", arguments: [
    CGEventType.rightMouseDown, .rightMouseUp, .leftMouseDown, .otherMouseDown, .keyDown, .keyUp, .flagsChanged,
  ])
  func othersDoNotRewrite(type: CGEventType) throws {
    let harness = Harness()
    _ = try harness.send(type)
    #expect(!harness.recorder.calls.contains("rewrite"))
  }

  @Test("左键拖动只改写坐标")
  func leftDraggedOnlyRewrites() throws {
    let harness = Harness()
    #expect(try !harness.send(.leftMouseDragged))
    #expect(harness.recorder.calls == ["rewrite"])
  }

  @Test("没处理的事件类型直接放行")
  func unknownTypePasses() throws {
    let harness = Harness()
    #expect(try !harness.send(.scrollWheel))
    #expect(harness.recorder.calls.isEmpty)
  }
}
