import Foundation

// MARK: - From

struct KeyRemapFrom: Codable, Equatable {
  var keyCode: UInt16           // CGKeyCode（来自 KeyCodeMap）
  var isModifier: Bool          // true = flagsChanged 事件；false = keyDown/keyUp
  var mandatory: [UInt16]       // 必须同时按住的修饰键 keyCode（Mode B）
}

// MARK: - To

struct KeyRemapTo: Codable, Equatable {
  var keyCode: UInt16           // CGKeyCode；0xFFFF = vk_none（禁用）
  var isModifier: Bool
  // 合成时一并激活的修饰键（hyper key 用）。
  // 仅当 isModifier = true 时有意义：合成 flagsChanged 携带这些 flag。
  var additionalModifierCodes: [UInt16]
}

// MARK: - Manipulator

struct KeyRemapManipulator: Codable, Identifiable, Equatable {
  var id: UUID
  var from: KeyRemapFrom
  var to: [KeyRemapTo]
  // Mode C 扩展预留（暂不执行，解析到时静默跳过）
  var toIfAlone: [KeyRemapTo]?
  var toIfHeldDown: [KeyRemapTo]?

  init(id: UUID = UUID(), from: KeyRemapFrom, to: [KeyRemapTo]) {
    self.id = id
    self.from = from
    self.to = to
    self.toIfAlone = nil
    self.toIfHeldDown = nil
  }
}

// MARK: - Rule

struct KeyRemapRule: Codable, Identifiable, Equatable {
  var id: UUID
  var title: String
  var enabled: Bool
  var isManual: Bool            // true = 手动 Add item；false = 从 JSON 导入
  var manipulators: [KeyRemapManipulator]

  init(id: UUID = UUID(), title: String, enabled: Bool = true,
       isManual: Bool = false, manipulators: [KeyRemapManipulator]) {
    self.id = id
    self.title = title
    self.enabled = enabled
    self.isManual = isManual
    self.manipulators = manipulators
  }
}

// MARK: - Notification

extension Notification.Name {
  static let keyRemapStoreDidChange = Notification.Name("Velto.keyRemapStoreDidChange")
}
