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
  case temporaryInputWindow

  var displayName: String {
    switch self {
    case .previousInputSourceShortcut: return "模拟「上一个输入法」快捷键"
    case .temporaryInputWindow: return "临时输入窗口"
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

/// 固定分组角色。当前写死两组:英文组 / 中文组。`role == nil` 的是旧版动态分组
/// 残留,会被 ensureFixedGroups 归并掉。
enum InputSourceGroupRole: String, Codable, CaseIterable {
  case english
  case chinese

  var displayName: String {
    switch self {
    case .english: return "英文组"
    case .chinese: return "中文组"
    }
  }
}

/// 应用分组:按分组级别绑定一个输入法,分组包含多个应用。改分组输入法时整组
/// 应用同时生效,避免逐个修改。当前 UI 写死两组(英文组 / 中文组),靠 role 区分。
struct InputSourceAppGroup: Codable, Identifiable, Equatable {
  var id: UUID
  var displayName: String
  var inputSourceID: String?
  var bundleIdentifiers: [String] = []
  var isEnabled: Bool = true
  /// 固定分组角色;nil = 旧动态分组(待归并)。Optional → 旧数据缺字段解码为 nil。
  var role: InputSourceGroupRole?
  var createdAt: Date

  init(
    id: UUID = UUID(),
    displayName: String,
    inputSourceID: String? = nil,
    bundleIdentifiers: [String] = [],
    isEnabled: Bool = true,
    role: InputSourceGroupRole? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.displayName = displayName
    self.inputSourceID = inputSourceID
    self.bundleIdentifiers = bundleIdentifiers
    self.isEnabled = isEnabled
    self.role = role
    self.createdAt = createdAt
  }
}

/// 应用规则(兼容旧架构):按 bundleIdentifier 绑定目标输入法。
/// 新配置优先走 appGroups;升级时自动把 appRules 迁移成分组。
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
  var cjkFixEnabled: Bool = false
  // 对齐 InputSourcePro 默认:优先走系统「选择上一个输入法」快捷键,避免临时窗口抢焦点。
  var cjkFixStrategy: InputSourceCJKFixStrategy = .previousInputSourceShortcut
  /// 启用了 URL 检测的浏览器 bundle id 集合。
  var enabledBrowserBundleIDs: Set<String> = []
  /// 强制英文标点总开关(通用页条目)。默认开 —— 不勾选任何应用时本来就无效果,
  /// 真正的粒度在 forceEnglishPunctuationBundleIDs;这里是一键全停的开关。
  var forceEnglishPunctuationEnabled: Bool = true
  /// 强制英文标点(移植自 ISP):集合里的 App 前台时即便是 CJKV 输入法,标点键也
  /// 直接输出英文字符。按应用勾选生效,独立于 enabled 总开关。
  var forceEnglishPunctuationBundleIDs: Set<String> = []
  /// 应用分组(新架构):按分组管理应用,一个分组一个输入法。
  var appGroups: [InputSourceAppGroup] = []
  /// 应用规则(兼容旧架构):新配置优先走 appGroups,升级时自动迁移。
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
    cjkFixStrategy = try c.decodeIfPresent(InputSourceCJKFixStrategy.self, forKey: .cjkFixStrategy) ?? d.cjkFixStrategy
    enabledBrowserBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .enabledBrowserBundleIDs) ?? d.enabledBrowserBundleIDs
    forceEnglishPunctuationEnabled = try c.decodeIfPresent(Bool.self, forKey: .forceEnglishPunctuationEnabled) ?? d.forceEnglishPunctuationEnabled
    forceEnglishPunctuationBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .forceEnglishPunctuationBundleIDs) ?? d.forceEnglishPunctuationBundleIDs
    appGroups = try c.decodeIfPresent([InputSourceAppGroup].self, forKey: .appGroups) ?? d.appGroups
    appRules = try c.decodeIfPresent([InputSourceAppRule].self, forKey: .appRules) ?? d.appRules
    browserRules = try c.decodeIfPresent([InputSourceBrowserRule].self, forKey: .browserRules) ?? d.browserRules
  }
}

// MARK: - 固定两分组的归一化

extension InputSourceSwitchPreferences {
  /// 把分组规整成「写死的两组:英文组 + 中文组」。幂等,返回是否有改动(供调用方
  /// 决定是否写回,避免无谓保存)。
  ///
  /// 归并来源(都默认并入中文组,英文组留空待用户分配 —— 老配置基本是中文输入法):
  ///   - 旧「逐应用规则」appRules;
  ///   - 旧版动态分组(role == nil)的成员。
  /// 候选输入法取第一个非空的(旧规则/旧分组的 inputSourceID)填给中文组。
  /// 已存在的英文组 / 中文组(role 命中)保留其 id / 成员 / 输入法,只统一显示名。
  @discardableResult
  mutating func ensureFixedGroups() -> Bool {
    let before = appGroups
    let beforeRules = appRules

    var english = appGroups.first { $0.role == .english }
      ?? InputSourceAppGroup(displayName: InputSourceGroupRole.english.displayName, role: .english)
    var chinese = appGroups.first { $0.role == .chinese }
      ?? InputSourceAppGroup(displayName: InputSourceGroupRole.chinese.displayName, role: .chinese)
    english.displayName = InputSourceGroupRole.english.displayName
    chinese.displayName = InputSourceGroupRole.chinese.displayName
    english.isEnabled = true
    chinese.isEnabled = true

    // 收集待归并的旧成员 + 候选输入法。
    var legacyBundleIDs: [String] = []
    var legacySource: String? = nil
    for rule in appRules where rule.isEnabled {
      legacyBundleIDs.append(rule.bundleIdentifier)
      if legacySource == nil { legacySource = rule.inputSourceID }
    }
    for g in appGroups where g.role == nil {
      legacyBundleIDs.append(contentsOf: g.bundleIdentifiers)
      if legacySource == nil { legacySource = g.inputSourceID }
    }

    // 旧成员并入中文组(去重,且不抢已在英文组里的)。
    let inEnglish = Set(english.bundleIdentifiers)
    for bid in legacyBundleIDs where !inEnglish.contains(bid) && !chinese.bundleIdentifiers.contains(bid) {
      chinese.bundleIdentifiers.append(bid)
    }
    if chinese.inputSourceID == nil { chinese.inputSourceID = legacySource }

    appGroups = [english, chinese]
    appRules = []
    return appGroups != before || beforeRules != appRules
  }
}
