import Carbon
import CoreGraphics
import Testing

@testable import Velto

/// tap 被系统禁用期间抬起事件全丢,各模块记着的按下状态要清掉,该补的抬起要补上。
@Suite("模块瞬态复位")
struct InputModuleResetTests {
  private final class Posted {
    var events: [CGEvent] = []
  }

  private func keyEvent(_ keyCode: CGKeyCode, down: Bool) throws -> CGEvent {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down))
    // 新建事件会带上系统当前的修饰键状态,测试结果不能跟着真机走。
    event.flags = []
    return event
  }

  private func flagsEvent(_ keyCode: CGKeyCode, flags: CGEventFlags) throws -> CGEvent {
    let event = try keyEvent(keyCode, down: true)
    event.type = .flagsChanged
    event.flags = flags
    return event
  }

  private func remap(from: KeyRemapFrom, to: KeyRemapTo) -> (KeyRemapController, Posted) {
    let posted = Posted()
    let controller = KeyRemapController()
    controller.eventPoster = { posted.events.append($0) }
    controller.update(rules: [KeyRemapRule(
      title: "测试",
      manipulators: [KeyRemapManipulator(from: from, to: [to])]
    )])
    return (controller, posted)
  }

  private let aToB = (
    KeyRemapFrom(keyCode: 0, isModifier: false, mandatory: []),
    KeyRemapTo(keyCode: 11, isModifier: false, additionalModifierCodes: [])
  )
  private let optionToControl = (
    KeyRemapFrom(keyCode: 58, isModifier: true, mandatory: []),
    KeyRemapTo(keyCode: 59, isModifier: true, additionalModifierCodes: [])
  )

  @Test("按键映射:按下等不到抬起时补发抬起")
  func keyRemapReleasesHeldKey() throws {
    let (controller, posted) = remap(from: aToB.0, to: aToB.1)
    #expect(try controller.handleKeyDown(event: keyEvent(0, down: true)))
    #expect(posted.events.count == 1)

    controller.resetTransientState()

    #expect(posted.events.count == 2)
    let release = try #require(posted.events.last)
    #expect(release.type == .keyUp)
    #expect(release.getIntegerValueField(.keyboardEventKeycode) == 11)
    #expect(release.getIntegerValueField(.eventSourceUserData) == ShortcutSynthesizer.syntheticEventMarker)
  }

  /// 按键其实还按着,复位之后才松开:这次抬起透传就好,不能再补发一次。
  @Test("按键映射:复位后物理抬起不再合成")
  func keyRemapIgnoresLateKeyUp() throws {
    let (controller, posted) = remap(from: aToB.0, to: aToB.1)
    _ = try controller.handleKeyDown(event: keyEvent(0, down: true))
    controller.resetTransientState()
    let count = posted.events.count

    #expect(try !controller.handleKeyUp(event: keyEvent(0, down: false)))
    #expect(posted.events.count == count)
  }

  @Test("按键映射:修饰键目标补发松开,不会粘住")
  func keyRemapReleasesHeldModifier() throws {
    let (controller, posted) = remap(from: optionToControl.0, to: optionToControl.1)
    #expect(try controller.handleFlagsChanged(event: flagsEvent(58, flags: .maskAlternate)))
    #expect(posted.events.last?.flags.contains(.maskControl) == true)

    controller.resetTransientState()

    let release = try #require(posted.events.last)
    #expect(posted.events.count == 2)
    #expect(release.type == .flagsChanged)
    #expect(!release.flags.contains(.maskControl))
  }

  @Test("按键映射:正常松开后复位不再补发")
  func keyRemapNothingToReleaseAfterNormalRelease() throws {
    let (controller, posted) = remap(from: optionToControl.0, to: optionToControl.1)
    _ = try controller.handleFlagsChanged(event: flagsEvent(58, flags: .maskAlternate))
    _ = try controller.handleFlagsChanged(event: flagsEvent(58, flags: []))
    let count = posted.events.count

    controller.resetTransientState()

    #expect(posted.events.count == count)
  }

  @Test("按键映射:规则更新时也补发抬起")
  func keyRemapReleasesOnRuleUpdate() throws {
    let (controller, posted) = remap(from: aToB.0, to: aToB.1)
    _ = try controller.handleKeyDown(event: keyEvent(0, down: true))

    controller.update(rules: [])

    #expect(posted.events.count == 2)
    #expect(posted.events.last?.type == .keyUp)
  }

  @Test("按键映射:没有按住时复位什么都不发")
  func keyRemapResetWhenIdle() {
    let (controller, posted) = remap(from: aToB.0, to: aToB.1)
    controller.resetTransientState()
    #expect(posted.events.isEmpty)
  }

  private func activePunctuation() -> InputSourcePunctuationController {
    let controller = InputSourcePunctuationController()
    controller.eventPoster = { _ in }
    controller.setActive(true)
    controller.setCurrentInputSourceIsCJKV(true)
    return controller
  }

  @Test("强制标点:正常情况下吞掉对应的抬起")
  func punctuationConsumesMatchingKeyUp() throws {
    let controller = activePunctuation()
    let comma = CGKeyCode(kVK_ANSI_Comma)
    #expect(try controller.handleKeyDown(event: keyEvent(comma, down: true)))
    #expect(try controller.shouldConsumeKeyUp(event: keyEvent(comma, down: false)))
    #expect(try !controller.shouldConsumeKeyUp(event: keyEvent(comma, down: false)))
  }

  /// 抬起丢了之后不清掉,下一次按这个键时就少一次抬起,App 看到按键粘住。
  @Test("强制标点:复位后不再吞抬起")
  func punctuationForgetsPendingKeyUp() throws {
    let controller = activePunctuation()
    let comma = CGKeyCode(kVK_ANSI_Comma)
    _ = try controller.handleKeyDown(event: keyEvent(comma, down: true))

    controller.resetTransientState()

    #expect(try !controller.shouldConsumeKeyUp(event: keyEvent(comma, down: false)))
  }
}
