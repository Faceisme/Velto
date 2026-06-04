import Foundation

// MARK: - 枚举类型

/// 切回 App / 网站时的恢复策略。
enum InputSourceRestoreStrategy: String, Codable, CaseIterable, Hashable {
  case useDefaultInputSource
  case restorePreviouslyUsed

  var displayName: String {
    switch self {
    case .useDefaultInputSource: return "使用默认输入法"
    case .restorePreviouslyUsed: return "恢复上次使用的输入法"
    }
  }
}

/// CJKV(中日韩越)输入法切换后的二次确认策略。
enum InputSourceCJKFixStrategy: String, Codable, CaseIterable, Hashable {
  case previousInputSourceShortcut
  /// 旧版本保留值。运行时不再使用,解码时迁移到 previousInputSourceShortcut。
  case temporaryInputWindow

  var displayName: String {
    switch self {
    case .previousInputSourceShortcut: return "模拟「上一个输入法」快捷键"
    case .temporaryInputWindow: return "临时输入窗口(已停用)"
    }
  }
}

/// 浏览器规则匹配类型。
enum InputSourceBrowserRuleType: String, Codable, CaseIterable, Hashable {
  case domainSuffix
  case domain
  case urlRegex

  var displayName: String {
    switch self {
    case .domainSuffix: return "域名后缀"
    case .domain: return "精确域名"
    case .urlRegex: return "URL 正则"
    }
  }
}

// MARK: - 规则模型

/// 应用规则:按 bundleIdentifier 绑定目标输入法。匹配键只用 bundleIdentifier,
/// 其余字段供 UI 展示。
struct InputSourceAppRule: Codable, Identifiable, Equatable {
  var id: UUID
  var bundleIdentifier: String
  var displayName: String
  var bundlePath: String?
  var inputSourceID: String?
  var isEnabled: Bool
  var createdAt: Date

  init(
    id: UUID = UUID(),
    bundleIdentifier: String,
    displayName: String,
    bundlePath: String? = nil,
    inputSourceID: String? = nil,
    isEnabled: Bool = true,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.bundleIdentifier = bundleIdentifier
    self.displayName = displayName
    self.bundlePath = bundlePath
    self.inputSourceID = inputSourceID
    self.isEnabled = isEnabled
    self.createdAt = createdAt
  }
}

/// 浏览器规则:按当前 Tab URL 匹配。
struct InputSourceBrowserRule: Codable, Identifiable, Equatable {
  var id: UUID
  var type: InputSourceBrowserRuleType
  var value: String
  var sample: String
  var inputSourceID: String?
  var isEnabled: Bool
  var createdAt: Date

  init(
    id: UUID = UUID(),
    type: InputSourceBrowserRuleType = .domainSuffix,
    value: String = "",
    sample: String = "",
    inputSourceID: String? = nil,
    isEnabled: Bool = true,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.type = type
    self.value = value
    self.sample = sample
    self.inputSourceID = inputSourceID
    self.isEnabled = isEnabled
    self.createdAt = createdAt
  }
}

// MARK: - 偏好结构体

/// 输入法切换的全部用户配置。嵌进 AppPreferences.inputSourceSwitch,与手势/窗口/
/// 切换器共享同一份 `Velto.preferences` JSON。
///
/// 字段添加规则:**只能加,不能改类型/删字段**。`init(from:)` 用 decodeIfPresent
/// 兜底 nil → defaults,保证老用户升级时偏好不丢。
struct InputSourceSwitchPreferences: Codable, Equatable {
  /// 总开关。默认 false —— 自动改用户输入法属于"侵入式",必须用户显式开。
  var enabled: Bool = false
  var debugLoggingEnabled: Bool = false
  /// 全局默认输入法持久化 ID;nil = 不设兜底(无规则命中时保持当前)。
  var systemDefaultInputSourceID: String? = nil
  /// 浏览器地址栏默认输入法;nil = 地址栏不特殊处理。
  var browserAddressDefaultInputSourceID: String? = nil
  var restoreStrategy: InputSourceRestoreStrategy = .useDefaultInputSource
  var cjkFixEnabled: Bool = true
  // 对齐 InputSourcePro 默认:优先走系统「选择上一个输入法」快捷键,避免临时窗口抢焦点。
  var cjkFixStrategy: InputSourceCJKFixStrategy = .previousInputSourceShortcut
  /// 启用了 URL 检测的浏览器 bundle id 集合。
  var enabledBrowserBundleIDs: Set<String> = []
  var appRules: [InputSourceAppRule] = []
  var browserRules: [InputSourceBrowserRule] = []

  static let defaults = InputSourceSwitchPreferences()

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self.defaults
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    debugLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .debugLoggingEnabled) ?? d.debugLoggingEnabled
    systemDefaultInputSourceID = try c.decodeIfPresent(String.self, forKey: .systemDefaultInputSourceID) ?? d.systemDefaultInputSourceID
    browserAddressDefaultInputSourceID = try c.decodeIfPresent(String.self, forKey: .browserAddressDefaultInputSourceID) ?? d.browserAddressDefaultInputSourceID
    restoreStrategy = try c.decodeIfPresent(InputSourceRestoreStrategy.self, forKey: .restoreStrategy) ?? d.restoreStrategy
    cjkFixEnabled = try c.decodeIfPresent(Bool.self, forKey: .cjkFixEnabled) ?? d.cjkFixEnabled
    let decodedStrategy = try c.decodeIfPresent(InputSourceCJKFixStrategy.self, forKey: .cjkFixStrategy) ?? d.cjkFixStrategy
    cjkFixStrategy = decodedStrategy == .temporaryInputWindow ? .previousInputSourceShortcut : decodedStrategy
    enabledBrowserBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .enabledBrowserBundleIDs) ?? d.enabledBrowserBundleIDs
    appRules = try c.decodeIfPresent([InputSourceAppRule].self, forKey: .appRules) ?? d.appRules
    browserRules = try c.decodeIfPresent([InputSourceBrowserRule].self, forKey: .browserRules) ?? d.browserRules
  }
}
