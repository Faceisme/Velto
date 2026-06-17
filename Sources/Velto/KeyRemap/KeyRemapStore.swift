import Foundation
import Observation

@MainActor
@Observable
final class KeyRemapStore {
  static let shared = KeyRemapStore()

  private let storageKey = "Velto.keyRemaps"
  private let enabledKey = "Velto.keyRemapEnabled"
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private(set) var rules: [KeyRemapRule]
  // 功能总开关:关闭后所有映射规则暂停生效。默认开启,保持既有行为。
  private(set) var masterEnabled: Bool

  private init() {
    if let data = UserDefaults.standard.data(forKey: storageKey),
       let saved = try? decoder.decode([KeyRemapRule].self, from: data) {
      rules = saved
    } else {
      rules = []
    }
    // 从未设置过时默认开启。
    if UserDefaults.standard.object(forKey: enabledKey) == nil {
      masterEnabled = true
    } else {
      masterEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    }
  }

  // MARK: - 总开关

  func setMasterEnabled(_ enabled: Bool) {
    guard masterEnabled != enabled else { return }
    masterEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: enabledKey)
    notify()
  }

  // MARK: - 写操作（每次操作后持久化 + 通知）

  func addRule(_ rule: KeyRemapRule) {
    rules.append(rule)
    persist()
    notify()
  }

  func updateRule(_ rule: KeyRemapRule) {
    guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
    rules[idx] = rule
    persist()
    notify()
  }

  func deleteRule(id: UUID) {
    rules.removeAll { $0.id == id }
    persist()
    notify()
  }

  func setEnabled(_ enabled: Bool, ruleID: UUID) {
    guard let idx = rules.firstIndex(where: { $0.id == ruleID }) else { return }
    rules[idx].enabled = enabled
    persist()
    notify()
  }

  // 手动映射专用：获取或新建 isManual 规则
  func manualRule() -> KeyRemapRule {
    if let existing = rules.first(where: { $0.isManual }) { return existing }
    let rule = KeyRemapRule(title: "手动映射", enabled: true, isManual: true, manipulators: [])
    rules.insert(rule, at: 0)
    persist()
    notify()
    return rules[0]
  }

  func addManualManipulator(_ m: KeyRemapManipulator) {
    guard let idx = rules.firstIndex(where: { $0.isManual }) else {
      _ = manualRule()
      addManualManipulator(m)
      return
    }
    rules[idx].manipulators.append(m)
    persist()
    notify()
  }

  func deleteManualManipulator(id: UUID) {
    guard let rIdx = rules.firstIndex(where: { $0.isManual }) else { return }
    rules[rIdx].manipulators.removeAll { $0.id == id }
    persist()
    notify()
  }

  // MARK: - 持久化

  private func persist() {
    guard let data = try? encoder.encode(rules) else { return }
    UserDefaults.standard.set(data, forKey: storageKey)
  }

  private func notify() {
    NotificationCenter.default.post(name: .keyRemapStoreDidChange, object: self)
  }
}
