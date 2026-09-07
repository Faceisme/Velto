import Carbon
import CoreGraphics
import XCTest

@testable import Velto

/// 强制英文标点的纯决策逻辑(keycode + 修饰键 → 替换字符)。
final class InputSourcePunctuationTests: XCTestCase {
  private func replacement(_ keyCode: Int, flags: CGEventFlags = []) -> String? {
    InputSourcePunctuationController.replacementString(keyCode: Int64(keyCode), flags: flags)
  }

  func testPlainPunctuationMapsToEnglish() {
    XCTAssertEqual(replacement(kVK_ANSI_Comma), ",")
    XCTAssertEqual(replacement(kVK_ANSI_Period), ".")
    XCTAssertEqual(replacement(kVK_ANSI_Semicolon), ";")
    XCTAssertEqual(replacement(kVK_ANSI_Quote), "'")
    XCTAssertEqual(replacement(kVK_ANSI_LeftBracket), "[")
    XCTAssertEqual(replacement(kVK_ANSI_RightBracket), "]")
    XCTAssertEqual(replacement(kVK_ANSI_Backslash), "\\")
    XCTAssertEqual(replacement(kVK_ANSI_Grave), "`")
    XCTAssertEqual(replacement(kVK_ANSI_Minus), "-")
    XCTAssertEqual(replacement(kVK_ANSI_Slash), "/")
  }

  func testShiftSelectsShiftedVariant() {
    XCTAssertEqual(replacement(kVK_ANSI_Comma, flags: .maskShift), "<")
    XCTAssertEqual(replacement(kVK_ANSI_Period, flags: .maskShift), ">")
    XCTAssertEqual(replacement(kVK_ANSI_Semicolon, flags: .maskShift), ":")
    XCTAssertEqual(replacement(kVK_ANSI_Quote, flags: .maskShift), "\"")
    XCTAssertEqual(replacement(kVK_ANSI_4, flags: .maskShift), "$")
    XCTAssertEqual(replacement(kVK_ANSI_6, flags: .maskShift), "^")
    XCTAssertEqual(replacement(kVK_ANSI_Grave, flags: .maskShift), "~")
    // ISP 原表漏掉的四个,中文输入法会转全角(？！（)),已补上。
    XCTAssertEqual(replacement(kVK_ANSI_Slash, flags: .maskShift), "?")
    XCTAssertEqual(replacement(kVK_ANSI_1, flags: .maskShift), "!")
    XCTAssertEqual(replacement(kVK_ANSI_9, flags: .maskShift), "(")
    XCTAssertEqual(replacement(kVK_ANSI_0, flags: .maskShift), ")")
  }

  func testShiftOnlyKeysPassThroughWithoutShift() {
    // 数字键无 Shift 参与拼音输入/候选选词,绝不能替换。
    XCTAssertNil(replacement(kVK_ANSI_4))
    XCTAssertNil(replacement(kVK_ANSI_6))
    XCTAssertNil(replacement(kVK_ANSI_1))
    XCTAssertNil(replacement(kVK_ANSI_9))
    XCTAssertNil(replacement(kVK_ANSI_0))
  }

  func testShortcutModifiersPassThrough() {
    // ⌘, 是标准的「打开设置」快捷键,必须放行。
    XCTAssertNil(replacement(kVK_ANSI_Comma, flags: .maskCommand))
    XCTAssertNil(replacement(kVK_ANSI_Period, flags: .maskControl))
    XCTAssertNil(replacement(kVK_ANSI_LeftBracket, flags: [.maskCommand, .maskShift]))
    XCTAssertNil(replacement(kVK_ANSI_Semicolon, flags: .maskAlternate))
    XCTAssertNil(replacement(kVK_ANSI_Quote, flags: .maskSecondaryFn))
  }

  func testUnmappedKeysPassThrough() {
    XCTAssertNil(replacement(kVK_ANSI_A))
    XCTAssertNil(replacement(kVK_Space))
    XCTAssertNil(replacement(kVK_Return))
    // @#%&*=+ 中文输入法本就出半角,不入表。
    XCTAssertNil(replacement(kVK_ANSI_2, flags: .maskShift))
    XCTAssertNil(replacement(kVK_ANSI_8, flags: .maskShift))
    XCTAssertNil(replacement(kVK_ANSI_Equal))
    XCTAssertNil(replacement(kVK_ANSI_Equal, flags: .maskShift))
  }

  // MARK: - 组字推演(候选窗翻页键透传的依据)

  private typealias Tracker = InputSourcePunctuationController.CompositionTracker

  private func key(_ tracker: inout Tracker, _ keyCode: Int, flags: CGEventFlags = []) {
    tracker.noteKeyDown(keyCode: Int64(keyCode), flags: flags)
  }

  func testCandidateNavigationKeySet() {
    // [ ] - 是 Apple 拼音/双拼的候选翻页键,组字中必须透传;其余标点照常替换。
    let navKeys = InputSourcePunctuationController.candidateNavigationKeyCodes
    XCTAssertTrue(navKeys.contains(Int64(kVK_ANSI_LeftBracket)))
    XCTAssertTrue(navKeys.contains(Int64(kVK_ANSI_RightBracket)))
    XCTAssertTrue(navKeys.contains(Int64(kVK_ANSI_Minus)))
    XCTAssertFalse(navKeys.contains(Int64(kVK_ANSI_Comma)))
    XCTAssertFalse(navKeys.contains(Int64(kVK_ANSI_Period)))
    XCTAssertFalse(navKeys.contains(Int64(kVK_ANSI_Quote)))
  }

  func testLettersStartCompositionAndCommitKeysEndIt() {
    var tracker = Tracker()
    XCTAssertFalse(tracker.isComposing)
    key(&tracker, kVK_ANSI_N)
    key(&tracker, kVK_ANSI_I)
    XCTAssertTrue(tracker.isComposing)
    key(&tracker, kVK_Space) // 空格上屏
    XCTAssertFalse(tracker.isComposing)

    key(&tracker, kVK_ANSI_H)
    XCTAssertTrue(tracker.isComposing)
    key(&tracker, kVK_Escape) // Esc 取消
    XCTAssertFalse(tracker.isComposing)

    key(&tracker, kVK_ANSI_H)
    key(&tracker, kVK_ANSI_1) // 数字选候选
    XCTAssertFalse(tracker.isComposing)

    key(&tracker, kVK_ANSI_H)
    key(&tracker, kVK_Return) // 回车上屏原文
    XCTAssertFalse(tracker.isComposing)
  }

  func testBackspaceDrainsCompositionBuffer() {
    var tracker = Tracker()
    key(&tracker, kVK_ANSI_N)
    key(&tracker, kVK_ANSI_I)
    key(&tracker, kVK_Delete)
    XCTAssertTrue(tracker.isComposing) // 还剩一个字母
    key(&tracker, kVK_Delete)
    XCTAssertFalse(tracker.isComposing) // 缓冲清空
    key(&tracker, kVK_Delete) // 多退不为负
    XCTAssertFalse(tracker.isComposing)
  }

  func testNavigationKeysDoNotEndComposition() {
    // 组字中按 [ ] - 和方向键都在导航候选,组字继续。
    var tracker = Tracker()
    key(&tracker, kVK_ANSI_N)
    key(&tracker, kVK_ANSI_I)
    key(&tracker, kVK_ANSI_RightBracket)
    key(&tracker, kVK_ANSI_LeftBracket)
    key(&tracker, kVK_ANSI_Minus)
    key(&tracker, kVK_DownArrow)
    key(&tracker, kVK_PageDown)
    XCTAssertTrue(tracker.isComposing)
  }

  func testModifiedKeysResetOrSkipComposition() {
    var tracker = Tracker()
    key(&tracker, kVK_ANSI_N)
    key(&tracker, kVK_ANSI_A, flags: .maskCommand) // ⌘A 打断组字
    XCTAssertFalse(tracker.isComposing)

    key(&tracker, kVK_ANSI_A, flags: .maskAlternate) // ⌥字母出符号,不进缓冲
    XCTAssertFalse(tracker.isComposing)
  }

  func testPreferencesDecodeDefaultsWhenFieldsMissing() throws {
    // 老配置里没有该字段 → 解码回默认值:全局开关关(侵入式行为必须显式开)。
    let decoded = try JSONDecoder().decode(InputSourceSwitchPreferences.self, from: Data("{}".utf8))
    XCTAssertFalse(decoded.forceEnglishPunctuationEnabled)
  }

  func testPreferencesRoundTrip() throws {
    var prefs = InputSourceSwitchPreferences()
    prefs.forceEnglishPunctuationEnabled = true
    let data = try JSONEncoder().encode(prefs)
    let decoded = try JSONDecoder().decode(InputSourceSwitchPreferences.self, from: data)
    XCTAssertTrue(decoded.forceEnglishPunctuationEnabled)
  }
}
