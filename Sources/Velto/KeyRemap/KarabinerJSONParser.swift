import Foundation

enum KarabinerJSONParser {

  struct ParseResult {
    var rules: [KeyRemapRule]
    var skippedCount: Int
  }

  // 解析完整的 complex_modifications JSON 文件数据。
  // 顶层格式：{ "title": "...", "rules": [ { "description": "...", "manipulators": [...] } ] }
  static func parse(data: Data) -> ParseResult {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return ParseResult(rules: [], skippedCount: 0)
    }

    let fileTitle = root["title"] as? String ?? "导入的规则"
    guard let rulesJSON = root["rules"] as? [[String: Any]] else {
      return ParseResult(rules: [], skippedCount: 0)
    }

    var skipped = 0
    var allManipulators: [KeyRemapManipulator] = []

    for ruleJSON in rulesJSON {
      guard let manipulatorsJSON = ruleJSON["manipulators"] as? [[String: Any]] else { continue }
      for mJSON in manipulatorsJSON {
        if let m = parseManipulator(mJSON, skippedCount: &skipped) {
          allManipulators.append(m)
        }
      }
    }

    if allManipulators.isEmpty {
      return ParseResult(rules: [], skippedCount: skipped)
    }

    let rule = KeyRemapRule(
      title: fileTitle,
      enabled: true,
      isManual: false,
      manipulators: allManipulators
    )
    return ParseResult(rules: [rule], skippedCount: skipped)
  }

  // MARK: - 单条 manipulator 解析

  private static func parseManipulator(
    _ json: [String: Any],
    skippedCount: inout Int
  ) -> KeyRemapManipulator? {
    // 只处理 basic type
    guard (json["type"] as? String) == "basic" else {
      skippedCount += 1; return nil
    }
    // 含 conditions：跳过（暂不支持）
    if json["conditions"] != nil {
      skippedCount += 1; return nil
    }
    // 含 to_if_alone / to_if_held_down：跳过（Mode C）
    if json["to_if_alone"] != nil || json["to_if_held_down"] != nil {
      skippedCount += 1; return nil
    }

    guard let fromJSON = json["from"] as? [String: Any],
          let from = parseFrom(fromJSON) else {
      skippedCount += 1; return nil
    }

    guard let toArray = json["to"] as? [[String: Any]], !toArray.isEmpty else {
      skippedCount += 1; return nil
    }
    let toActions = toArray.compactMap { parseTo($0) }
    guard !toActions.isEmpty else {
      skippedCount += 1; return nil
    }

    return KeyRemapManipulator(from: from, to: toActions)
  }

  // MARK: - from 解析

  private static func parseFrom(_ json: [String: Any]) -> KeyRemapFrom? {
    guard let keyName = json["key_code"] as? String,
          let entry = KeyCodeMap.byKarabinerName[keyName] else { return nil }

    var mandatory: [UInt16] = []
    if let modifiers = json["modifiers"] as? [String: Any],
       let mandatoryNames = modifiers["mandatory"] as? [String] {
      for name in mandatoryNames {
        if let e = KeyCodeMap.byKarabinerName[name] {
          mandatory.append(e.keyCode)
        }
      }
    }

    return KeyRemapFrom(
      keyCode: entry.keyCode,
      isModifier: entry.isModifier,
      mandatory: mandatory
    )
  }

  // MARK: - to 解析

  private static func parseTo(_ json: [String: Any]) -> KeyRemapTo? {
    // vk_none 特殊处理（禁用键）
    if let keyName = json["key_code"] as? String, keyName == "vk_none" {
      return KeyRemapTo(keyCode: 0xFFFF, isModifier: false, additionalModifierCodes: [])
    }

    guard let keyName = json["key_code"] as? String,
          let entry = KeyCodeMap.byKarabinerName[keyName] else { return nil }

    var additionalMods: [UInt16] = []
    if let modNames = json["modifiers"] as? [String] {
      for name in modNames {
        if let e = KeyCodeMap.byKarabinerName[name] {
          additionalMods.append(e.keyCode)
        }
      }
    }

    return KeyRemapTo(
      keyCode: entry.keyCode,
      isModifier: entry.isModifier,
      additionalModifierCodes: additionalMods
    )
  }
}
