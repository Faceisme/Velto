# InputSourceSwitch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Velto 新增 `InputSourceSwitch` 模块，根据当前前台 App 和浏览器当前网站自动切换 macOS 输入法，并提供「输入法切换」侧边栏入口（通用 / 应用规则 / 浏览器规则 / 故障排除）。

**Architecture:** 链路 `NSWorkspace/AX 通知/兜底轮询 → Context(算上下文) → Controller(按优先级决策 + runtime cache) → Selector(TISSelectInputSource + CJKV 修复)`。配置嵌进现有 `AppPreferences` 的单份 JSON；AX 读取全部走已有的 `AXCallQueue.shared`；CJKV 的合成快捷键通过专属「暗号」与常驻 `EventTapManager` 共存。设计参考 InputSourcePro 行为（GPL，不复制源码），用 Velto 原生 Swift 重写。

**Tech Stack:** Swift 6.2、SwiftUI、AppKit、Carbon Text Input Sources（`TIS*`）、ApplicationServices Accessibility（`AXUIElement`/`AXObserver`）、CoreGraphics 事件合成。

> **关于测试：** 本计划**不引入 XCTest**。spec §2 已决定 v1 不加 test target，且 Velto 现无任何测试设施（切换器等模块同样靠手工验证）。这是 writing-plans 默认 TDD 流程对本仓库现实的有意让步——用户指令/spec 优先于技能默认。每个任务的验证 = **`swift build` 编译通过** + 涉及运行期行为时的**手动核对**。
>
> 每任务编译命令统一为：
> ```bash
> swift build -c debug --arch arm64 --scratch-path .build --product Velto
> ```
> 期望输出：`Build complete!`（首次会较慢）。最终 Task 10 才跑 `./scripts/build-app.sh --run` 部署到 `/Applications` 并启动。

---

## 文件结构

新建（`Sources/Velto/InputSourceSwitch/`，10 个文件）：

| 文件 | 职责 |
|------|------|
| `InputSourceSwitchPreferences.swift` | 配置模型 + 规则模型 + 枚举（接入 `AppPreferences`） |
| `InputSourceSwitchDebugLog.swift` | 独立调试日志通道（仿 `SwitcherDebugLog`） |
| `InputSourceSwitchSource.swift` | TIS 枚举 / 当前输入法 / 持久化 ID 查找 / `isCJKV` |
| `InputSourceSwitchSelector.swift` | `TISSelectInputSource` + CJKV 两策略 + 合成事件暗号 |
| `InputSourceSwitchBrowser.swift` | 支持浏览器枚举 + 已安装检测 |
| `InputSourceSwitchBrowserAX.swift` | AX 取 focused window → DFS 找 `AXWebArea` → 读 URL / 地址栏焦点 |
| `InputSourceSwitchContext.swift` | 上下文模型 + 监听（NSWorkspace + AXObserver + 0.8s 兜底轮询） |
| `InputSourceSwitchController.swift` | 单例总指挥：决策优先级 + runtime cache + 自切抑制 + 生命周期 |
| `InputSourceSwitchPage.swift` | 设置页（分段 UI，live-save） |
| `InputSourceSwitchRuleEditor.swift` | 应用规则 / 浏览器规则新增-编辑弹窗 |

修改现有：`Models.swift`、`AppDelegate.swift`、`SettingsRootView.swift`、`SidebarView.swift`、`EventTapManager.swift`、`PermissionManager.swift`。`Package.swift` 不改（SwiftPM 按目录 glob 自动收新文件）。

任务顺序按依赖递增，每个任务结束都能 `swift build` 通过并提交。

---

### Task 1: 配置模型接入

**Files:**
- Create: `Sources/Velto/InputSourceSwitch/InputSourceSwitchPreferences.swift`
- Modify: `Sources/Velto/Models.swift`（`AppPreferences` 结构体 56-147 行区域）

- [ ] **Step 1: 创建配置模型文件**

创建 `Sources/Velto/InputSourceSwitch/InputSourceSwitchPreferences.swift`：

```swift
import Foundation

// MARK: - 枚举

/// 切回 App / 网站时的恢复策略。
enum InputSourceRestoreStrategy: String, Codable, CaseIterable, Hashable {
  case useDefaultInputSource    // 总是用规则/默认算出来的
  case restorePreviouslyUsed    // 优先恢复上次在该上下文用过的

  var displayName: String {
    switch self {
    case .useDefaultInputSource: return "使用默认输入法"
    case .restorePreviouslyUsed: return "恢复上次使用的输入法"
    }
  }
}

/// CJKV(中日韩越)输入法切换后的二次确认策略。
enum InputSourceCJKFixStrategy: String, Codable, CaseIterable, Hashable {
  case previousInputSourceShortcut   // 合成「选择上一个输入法」系统快捷键
  case temporaryInputWindow          // 透明临时窗口短暂抢焦点确认

  var displayName: String {
    switch self {
    case .previousInputSourceShortcut: return "模拟「上一个输入法」快捷键"
    case .temporaryInputWindow: return "临时输入窗口"
    }
  }
}

/// 浏览器规则匹配类型。
enum InputSourceBrowserRuleType: String, Codable, CaseIterable, Hashable {
  case domainSuffix   // host.hasSuffix(value)
  case domain         // host == value
  case urlRegex       // 对完整 URL 做正则

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
  var inputSourceID: String?   // nil = 占位/暂不生效
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
  var sample: String          // 示例 URL,编辑器即时显示是否命中
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
/// 字段规则与 SwitcherPreferences 一致:**只能加,不能改类型/删字段**;
/// `init(from:)` 用 decodeIfPresent 兜底到 defaults,保证老用户升级不丢配置。
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
    cjkFixStrategy = try c.decodeIfPresent(InputSourceCJKFixStrategy.self, forKey: .cjkFixStrategy) ?? d.cjkFixStrategy
    enabledBrowserBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .enabledBrowserBundleIDs) ?? d.enabledBrowserBundleIDs
    appRules = try c.decodeIfPresent([InputSourceAppRule].self, forKey: .appRules) ?? d.appRules
    browserRules = try c.decodeIfPresent([InputSourceBrowserRule].self, forKey: .browserRules) ?? d.browserRules
  }
}
```

- [ ] **Step 2: 在 `AppPreferences` 加字段**

在 `Sources/Velto/Models.swift` 的 `AppPreferences` 里，`var switcher: SwitcherPreferences`（78 行）之后加：

```swift
    /// 输入法自动切换的全部配置 —— 子结构定义在
    /// InputSourceSwitch/InputSourceSwitchPreferences.swift。
    var inputSourceSwitch: InputSourceSwitchPreferences
```

- [ ] **Step 3: 加到 init 参数与赋值**

在 `init(...)`（80-110 行）的参数列表末尾 `switcher: SwitcherPreferences` 之后加 `, inputSourceSwitch: InputSourceSwitchPreferences`，并在函数体末尾 `self.switcher = switcher` 之后加：

```swift
        self.inputSourceSwitch = inputSourceSwitch
```

- [ ] **Step 4: 加到 `init(from:)` 解码**

在 `init(from decoder:)` 的 `switcher = ...`（128 行）之后加：

```swift
        inputSourceSwitch = try container.decodeIfPresent(InputSourceSwitchPreferences.self, forKey: .inputSourceSwitch) ?? Self.defaults.inputSourceSwitch
```

- [ ] **Step 5: 加到 `defaults`**

在 `static let defaults = AppPreferences(...)`（131-146 行）里 `switcher: .defaults` 之后加 `, inputSourceSwitch: .defaults`：

```swift
        switcher: .defaults,
        inputSourceSwitch: .defaults
    )
```

> 注：`AppPreferences` 的 `CodingKeys` 是编译器合成的（结构体里没有手写 enum），新增的 `inputSourceSwitch` 存储属性会被自动纳入 `.inputSourceSwitch` key，无需手改 CodingKeys。

- [ ] **Step 6: 编译并确认老配置不炸**

Run:
```bash
swift build -c debug --arch arm64 --scratch-path .build --product Velto
```
Expected: `Build complete!`

手动核对：当前机器上 `defaults read <app-domain> Velto.preferences` 若已有旧配置，本次改动靠 `decodeIfPresent` 全部走默认值，不应解码失败。（运行期验证留到 Task 10。）

- [ ] **Step 7: Commit**

```bash
git add Sources/Velto/InputSourceSwitch/InputSourceSwitchPreferences.swift Sources/Velto/Models.swift
git commit -m "feat(input-source-switch): 配置模型接入 AppPreferences"
```

---

### Task 2: 调试日志

**Files:**
- Create: `Sources/Velto/InputSourceSwitch/InputSourceSwitchDebugLog.swift`

- [ ] **Step 1: 创建日志通道**

完全仿 `Sources/Velto/Switcher/SwitcherDebugLog.swift`，但去掉 `shouldTrace`/`describeChildren`（输入法切换不需要 dump AX 子树）。创建 `Sources/Velto/InputSourceSwitch/InputSourceSwitchDebugLog.swift`：

```swift
import Foundation

/// 输入法切换调试通道 —— 独立写 ~/Library/Logs/Velto/input-source-switch.log,
/// 与切换器/手势各写各的,互不污染。
///
/// 默认关(isEnabled 求值零开销)。开启途径:
///   1. 设置页「调试日志」开关 → InputSourceSwitchController.setDebugEnabled
///   2. 环境变量 VELTO_INPUT_SOURCE_DEBUG=1(开发期强制开)
enum InputSourceSwitchDebugLog {
  private static let stateQueue = DispatchQueue(label: "com.velto.inputsource.debuglog.state")
  private nonisolated(unsafe) static var _enabled =
    ProcessInfo.processInfo.environment["VELTO_INPUT_SOURCE_DEBUG"] == "1"
  private nonisolated(unsafe) static var _handle: FileHandle?
  private nonisolated(unsafe) static var _handleOpened = false

  private static let envForced = ProcessInfo.processInfo.environment["VELTO_INPUT_SOURCE_DEBUG"] == "1"

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
  }()

  static var isEnabled: Bool {
    stateQueue.sync { _enabled }
  }

  static func setEnabled(_ enabled: Bool) {
    stateQueue.sync { _enabled = enabled || envForced }
  }

  private static func fileHandle() -> FileHandle? {
    stateQueue.sync {
      if !_handleOpened {
        _handleOpened = true
        _handle = Self.openLogFile()
      }
      return _handle
    }
  }

  private static func openLogFile() -> FileHandle? {
    let fm = FileManager.default
    guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent("Velto", isDirectory: true)
    else { return nil }
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let url = logsDir.appendingPathComponent("input-source-switch.log")
    if !fm.fileExists(atPath: url.path) {
      fm.createFile(atPath: url.path, contents: nil)
    }
    let handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
    let banner = "\n=== Velto input-source-switch log started \(dateFormatter.string(from: Date())) ===\n"
    if let data = banner.data(using: .utf8) {
      try? handle?.write(contentsOf: data)
    }
    return handle
  }

  static func log(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    let line = "[\(dateFormatter.string(from: Date()))] \(message())\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let handle = fileHandle(), let data = line.data(using: .utf8) {
      try? handle.write(contentsOf: data)
    }
  }
}
```

- [ ] **Step 2: 编译**

Run:
```bash
swift build -c debug --arch arm64 --scratch-path .build --product Velto
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Velto/InputSourceSwitch/InputSourceSwitchDebugLog.swift
git commit -m "feat(input-source-switch): 独立调试日志通道"
```

---

### Task 3: 输入法枚举与读取

**Files:**
- Create: `Sources/Velto/InputSourceSwitch/InputSourceSwitchSource.swift`

> **持久化 ID 决策（对 spec §3 的实现细化）：** spec 写的是 `sourceID::inputModeID`，那是 InputSourcePro 的内部表示。`TISCreateInputSourceList` 已经把每个输入模式当成**独立的、可选中的** source 枚举出来，每个都有唯一的 `kTISPropertyInputSourceID`。因此 v1 直接用 `InputSourceID` 作为持久化 ID（单字符串，如 `com.apple.inputmethod.SCIM.ITABC`），匹配与查找都基于它。这是对 spec 的忠实简化，v1 行为完全等价，且比拼接 `::` 更稳。

- [ ] **Step 1: 创建枚举/读取封装**

创建 `Sources/Velto/InputSourceSwitch/InputSourceSwitchSource.swift`：

```swift
import Carbon
import Foundation

/// 一个可被选中的键盘输入源的快照。
struct InputSourceInfo: Identifiable, Equatable {
  /// 持久化 ID = kTISPropertyInputSourceID。
  var id: String
  var localizedName: String
  var sourceLanguages: [String]

  /// 是否中日韩越输入法 —— 决定切换后是否需要 CJKV 二次确认。
  var isCJKV: Bool {
    guard let first = sourceLanguages.first?.lowercased() else { return false }
    // 语言码前缀:zh* / ja / ko / vi。
    return first.hasPrefix("zh") || first == "ja" || first == "ko" || first == "vi"
  }
}

/// TIS 输入源的枚举 / 当前读取 / 查找。所有调用线程安全(纯 Carbon 调用)。
enum InputSourceCatalog {
  /// 全部「可被选中的键盘输入源」,用于 UI Picker 候选与切换查找。
  static func all() -> [InputSourceInfo] {
    guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
    let list = cf as NSArray
    var result: [InputSourceInfo] = []
    for case let raw in list {
      let source = raw as! TISInputSource
      guard isSelectableKeyboardSource(source), let info = info(of: source) else { continue }
      result.append(info)
    }
    return result
  }

  /// 当前正在使用的键盘输入源。
  static func current() -> InputSourceInfo? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    return info(of: source)
  }

  /// 按持久化 ID 找到底层 TISInputSource(用于切换)。
  static func tisInputSource(forID id: String) -> TISInputSource? {
    guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return nil }
    let list = cf as NSArray
    for case let raw in list {
      let source = raw as! TISInputSource
      if sourceID(of: source) == id { return source }
    }
    return nil
  }

  // MARK: - 私有读取

  private static func isSelectableKeyboardSource(_ source: TISInputSource) -> Bool {
    guard let category = stringProperty(source, kTISPropertyInputSourceCategory),
          category == (kTISCategoryKeyboardInputSource as String)
    else { return false }
    return boolProperty(source, kTISPropertyInputSourceIsSelectCapable)
  }

  private static func info(of source: TISInputSource) -> InputSourceInfo? {
    guard let id = sourceID(of: source) else { return nil }
    let name = stringProperty(source, kTISPropertyLocalizedName) ?? id
    let langs = (arrayProperty(source, kTISPropertyInputSourceLanguages) as? [String]) ?? []
    return InputSourceInfo(id: id, localizedName: name, sourceLanguages: langs)
  }

  private static func sourceID(of source: TISInputSource) -> String? {
    stringProperty(source, kTISPropertyInputSourceID)
  }

  private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
  }

  private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
  }

  private static func arrayProperty(_ source: TISInputSource, _ key: CFString) -> NSArray? {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as NSArray
  }
}
```

- [ ] **Step 2: 编译**

Run:
```bash
swift build -c debug --arch arm64 --scratch-path .build --product Velto
```
Expected: `Build complete!`

> 若报 `Carbon` 找不到符号：确认 `import Carbon` 即可（Carbon.framework 在 macOS SDK 内，SwiftPM 无需在 Package.swift 显式 link）。

- [ ] **Step 3: Commit**

```bash
git add Sources/Velto/InputSourceSwitch/InputSourceSwitchSource.swift
git commit -m "feat(input-source-switch): TIS 输入源枚举/当前/查找"
```

---

### Task 4: 选择器 + CJKV 修复 + EventTapManager 暗号

**Files:**
- Create: `Sources/Velto/InputSourceSwitch/InputSourceSwitchSelector.swift`
- Modify: `Sources/Velto/EventTapManager.swift`（`.keyDown` 423-426、`.keyUp` 441-444、`.flagsChanged` 410-411）

- [ ] **Step 1: 创建选择器**

创建 `Sources/Velto/InputSourceSwitch/InputSourceSwitchSelector.swift`：

```swift
import AppKit
import Carbon
import CoreGraphics
import Foundation

/// 输入法切换执行器:TISSelectInputSource + 必要时 CJKV 二次确认。
enum InputSourceSwitchSelector {
  /// 合成事件暗号 —— previousInputSourceShortcut 策略会合成键盘事件,
  /// 必须让 Velto 常驻 EventTapManager 认得并原样透传,不误触发手势/切换器/快捷键。
  /// 取值与现有 3 个 marker 都不同(ShortcutSynthesizer=0x4D47534B4559)。"ISSFIX"。
  static let syntheticEventMarker: Int64 = 0x495353464958

  /// 切到指定持久化 ID 的输入法。返回是否成功发起切换。
  @discardableResult
  static func select(
    persistentID: String,
    cjkFixEnabled: Bool,
    cjkFixStrategy: InputSourceCJKFixStrategy
  ) -> Bool {
    guard let source = InputSourceCatalog.tisInputSource(forID: persistentID) else {
      InputSourceSwitchDebugLog.log("select FAILED: 找不到输入源 id=\(persistentID)")
      return false
    }
    let status = TISSelectInputSource(source)
    guard status == noErr else {
      InputSourceSwitchDebugLog.log("select FAILED: TISSelectInputSource status=\(status) id=\(persistentID)")
      return false
    }
    InputSourceSwitchDebugLog.log("select OK id=\(persistentID)")

    let isCJKV = InputSourceCatalog.all().first { $0.id == persistentID }?.isCJKV ?? false
    if cjkFixEnabled && isCJKV {
      applyCJKFix(strategy: cjkFixStrategy)
    }
    return true
  }

  // MARK: - CJKV 修复

  private static func applyCJKFix(strategy: InputSourceCJKFixStrategy) {
    switch strategy {
    case .previousInputSourceShortcut:
      guard let sc = previousInputSourceShortcut() else {
        InputSourceSwitchDebugLog.log("cjk-fix SKIP: 系统未配置「选择上一个输入法」快捷键")
        return
      }
      InputSourceSwitchDebugLog.log("cjk-fix previousShortcut keyCode=\(sc.keyCode)")
      synthesize(keyCode: sc.keyCode, flags: sc.flags)
    case .temporaryInputWindow:
      InputSourceSwitchDebugLog.log("cjk-fix temporaryWindow")
      DispatchQueue.main.async { showTemporaryInputWindow() }
    }
  }

  /// 读 com.apple.symbolichotkeys 里 id 60「选择上一个输入法」的快捷键。
  /// 未启用 / 不存在 → nil(UI 据此提示去键盘设置)。
  static func previousInputSourceShortcut() -> (keyCode: UInt16, flags: CGEventFlags)? {
    guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
          let hotkeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys"),
          let entry = hotkeys["60"] as? [String: Any],
          (entry["enabled"] as? Bool) == true,
          let value = entry["value"] as? [String: Any],
          let params = value["parameters"] as? [Int], params.count >= 3
    else { return nil }
    let keyCode = UInt16(params[1])
    let flags = cgFlags(fromNSModifierRaw: UInt(bitPattern: params[2]))
    return (keyCode, flags)
  }

  /// symbolichotkeys 的 modifier 字段是 NSEvent.ModifierFlags 的 raw 值。
  private static func cgFlags(fromNSModifierRaw raw: UInt) -> CGEventFlags {
    var f = CGEventFlags()
    if raw & 131072 != 0 { f.insert(.maskShift) }      // NSEvent.shift   = 1<<17
    if raw & 262144 != 0 { f.insert(.maskControl) }    // NSEvent.control = 1<<18
    if raw & 524288 != 0 { f.insert(.maskAlternate) }  // NSEvent.option  = 1<<19
    if raw & 1048576 != 0 { f.insert(.maskCommand) }   // NSEvent.command = 1<<20
    return f
  }

  /// 合成一组带暗号的按键事件(仿 ShortcutSynthesizer,但用本模块自己的 marker)。
  private static func synthesize(keyCode: UInt16, flags: CGEventFlags) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    let key = CGKeyCode(keyCode)
    let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
    down?.flags = flags
    down?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
    let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    up?.flags = flags
    up?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }

  /// 透明 3×3 临时窗口:短暂抢焦点逼 macOS 重新确认输入上下文,再还回前台 app。
  /// 仅在用户显式选 temporaryInputWindow 时走。
  @MainActor
  private static func showTemporaryInputWindow() {
    let previousApp = NSWorkspace.shared.frontmostApplication
    let window = NSWindow(
      contentRect: NSRect(x: -10, y: -10, width: 3, height: 3),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.level = .popUpMenu
    window.alphaValue = 0.0
    window.ignoresMouseEvents = true
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 3, height: 3))
    window.contentView?.addSubview(field)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(field)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      window.orderOut(nil)
      previousApp?.activate()
    }
  }
}
```

- [ ] **Step 2: EventTapManager `.keyDown` 加暗号**

`Sources/Velto/EventTapManager.swift` 第 424 行，把：

```swift
            if event.getIntegerValueField(.eventSourceUserData) == ShortcutSynthesizer.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
```

改成（`.keyDown` 分支内，第一处判断）：

```swift
            let kdUserData = event.getIntegerValueField(.eventSourceUserData)
            if kdUserData == ShortcutSynthesizer.syntheticEventMarker
                || kdUserData == InputSourceSwitchSelector.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
```

- [ ] **Step 3: EventTapManager `.keyUp` 加暗号**

第 442 行同理，把 `.keyUp` 分支的：

```swift
            if event.getIntegerValueField(.eventSourceUserData) == ShortcutSynthesizer.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
```

改成：

```swift
            let kuUserData = event.getIntegerValueField(.eventSourceUserData)
            if kuUserData == ShortcutSynthesizer.syntheticEventMarker
                || kuUserData == InputSourceSwitchSelector.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
```

- [ ] **Step 4: EventTapManager `.flagsChanged` 新增暗号早退**

`.flagsChanged` 分支当前**没有任何暗号判断**（410-411 行）。在 `case .flagsChanged:` 之后、`guard !gestureEngine.isHandlingRightMouse else {` 之前插入：

```swift
        case .flagsChanged:
            // 合成的「上一个输入法」快捷键修饰键不能污染鼠标控制/缩放/拖窗的修饰键状态机。
            if event.getIntegerValueField(.eventSourceUserData) == InputSourceSwitchSelector.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
            guard !gestureEngine.isHandlingRightMouse else {
                return Unmanaged.passUnretained(event)
            }
```

- [ ] **Step 5: 编译**

Run:
```bash
swift build -c debug --arch arm64 --scratch-path .build --product Velto
```
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/Velto/InputSourceSwitch/InputSourceSwitchSelector.swift Sources/Velto/EventTapManager.swift
git commit -m "feat(input-source-switch): 选择器+CJKV两策略+EventTap合成事件暗号"
```

---

### Task 5: 支持浏览器枚举与已安装检测

**Files:**
- Create: `Sources/Velto/InputSourceSwitch/InputSourceSwitchBrowser.swift`

- [ ] **Step 1: 创建浏览器目录**

创建 `Sources/Velto/InputSourceSwitch/InputSourceSwitchBrowser.swift`：

```swift
import AppKit
import Foundation

/// 浏览器内核家族 —— 影响地址栏焦点的判定方式(Task 6 用)。
enum BrowserEngine {
  case webkit     // Safari 系
  case chromium   // Chrome/Edge/Brave/Arc/Vivaldi/Opera/Thorium/Dia
  case gecko      // Firefox 系
}

/// 一个受支持的浏览器。
struct SupportedBrowser: Identifiable, Equatable {
  var bundleID: String
  var displayName: String
  var engine: BrowserEngine
  var id: String { bundleID }

  /// 本机是否已安装。
  var isInstalled: Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
  }
}

enum SupportedBrowserCatalog {
  /// v1 支持列表(bundle id 来自 spec §8)。
  static let all: [SupportedBrowser] = [
    .init(bundleID: "com.apple.Safari", displayName: "Safari", engine: .webkit),
    .init(bundleID: "com.apple.SafariTechnologyPreview", displayName: "Safari Technology Preview", engine: .webkit),
    .init(bundleID: "com.google.Chrome", displayName: "Google Chrome", engine: .chromium),
    .init(bundleID: "org.chromium.Chromium", displayName: "Chromium", engine: .chromium),
    .init(bundleID: "company.thebrowser.Browser", displayName: "Arc", engine: .chromium),
    .init(bundleID: "company.thebrowser.dia", displayName: "Dia", engine: .chromium),
    .init(bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge", engine: .chromium),
    .init(bundleID: "com.brave.Browser", displayName: "Brave", engine: .chromium),
    .init(bundleID: "com.brave.Browser.beta", displayName: "Brave Beta", engine: .chromium),
    .init(bundleID: "com.brave.Browser.nightly", displayName: "Brave Nightly", engine: .chromium),
    .init(bundleID: "com.vivaldi.Vivaldi", displayName: "Vivaldi", engine: .chromium),
    .init(bundleID: "com.operasoftware.Opera", displayName: "Opera", engine: .chromium),
    .init(bundleID: "org.chromium.Thorium", displayName: "Thorium", engine: .chromium),
    .init(bundleID: "org.mozilla.firefox", displayName: "Firefox", engine: .gecko),
    .init(bundleID: "org.mozilla.firefoxdeveloperedition", displayName: "Firefox Developer Edition", engine: .gecko),
    .init(bundleID: "org.mozilla.nightly", displayName: "Firefox Nightly", engine: .gecko),
    .init(bundleID: "app.zen-browser.zen", displayName: "Zen", engine: .gecko),  // Zen 是 Firefox 内核
  ]

  static func browser(forBundleID id: String?) -> SupportedBrowser? {
    guard let id else { return nil }
    return all.first { $0.bundleID == id }
  }

  static func isSupportedBrowser(_ id: String?) -> Bool {
    browser(forBundleID: id) != nil
  }

  /// 本机已安装的受支持浏览器。
  static func installed() -> [SupportedBrowser] {
    all.filter { $0.isInstalled }
  }
}
```

- [ ] **Step 2: 编译**

Run:
```bash
swift build -c debug --arch arm64 --scratch-path .build --product Velto
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Velto/InputSourceSwitch/InputSourceSwitchBrowser.swift
git commit -m "feat(input-source-switch): 支持浏览器枚举+已安装检测"
```

---

### Task 6: 浏览器 URL / 地址栏焦点 AX 读取

**Files:**
- Create: `Sources/Velto/InputSourceSwitch/InputSourceSwitchBrowserAX.swift`

> 本文件全是**同步 AX 读取**的纯函数，设计为在 `AXCallQueue.shared` 的后台 block 里调用（Task 7 负责调度）。绝不在主线程直接调。

- [ ] **Step 1: 创建 AX 读取**

创建 `Sources/Velto/InputSourceSwitch/InputSourceSwitchBrowserAX.swift`：

```swift
import ApplicationServices
import Foundation

/// 浏览器当前页上下文。
struct BrowserPageContext: Equatable {
  var url: URL?
  var addressBarFocused: Bool
}

/// 在浏览器 app 的 AX 树里读 URL 与地址栏焦点。**必须在后台 AXCallQueue 调用。**
enum BrowserAXReader {
  /// DFS 深度上限 —— AX 树异常时防爆栈/卡死。
  private static let maxDepth = 60

  static func readContext(pid: pid_t, engine: BrowserEngine) -> BrowserPageContext {
    let app = AXUIElementCreateApplication(pid)
    guard let window = focusedWindow(of: app) else {
      return BrowserPageContext(url: nil, addressBarFocused: false)
    }
    let url = findWebAreaURL(in: window, depth: 0)
    let focused = isAddressBarFocused(app: app, engine: engine)
    return BrowserPageContext(url: url, addressBarFocused: focused)
  }

  // MARK: - URL

  private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
    copyElement(app, kAXFocusedWindowAttribute)
  }

  /// DFS 找 role == AXWebArea,读它的 AXURL。
  private static func findWebAreaURL(in element: AXUIElement, depth: Int) -> URL? {
    if depth > maxDepth { return nil }
    if copyString(element, kAXRoleAttribute) == "AXWebArea" {
      if let url = copyURL(element, "AXURL"), !isIgnoredScheme(url) {
        return normalize(url)
      }
    }
    guard let children = copyChildren(element) else { return nil }
    for child in children {
      if let url = findWebAreaURL(in: child, depth: depth + 1) { return url }
    }
    return nil
  }

  private static func isIgnoredScheme(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return true }
    return scheme == "chrome-extension" || scheme == "moz-extension" || scheme == "safari-web-extension"
  }

  /// 去掉 fragment 规范化。取不到 host 的(如 newtab)原样返回。
  private static func normalize(_ url: URL) -> URL {
    guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    comps.fragment = nil
    return comps.url ?? url
  }

  // MARK: - 地址栏焦点(脆弱点,见 spec §8)

  /// 判定焦点元素是否地址栏。这是已知脆弱区:靠 role/subrole + 每家浏览器的
  /// identifier 启发式。失效时退化为"不在地址栏",最坏是地址栏没切到默认,不会切错。
  private static func isAddressBarFocused(app: AXUIElement, engine: BrowserEngine) -> Bool {
    guard let focused = copyElement(app, kAXFocusedUIElementAttribute) else { return false }
    let role = copyString(focused, kAXRoleAttribute)
    guard role == "AXTextField" || role == "AXComboBox" else { return false }
    let identifier = copyString(focused, "AXIdentifier") ?? ""
    let desc = copyString(focused, kAXDescriptionAttribute) ?? ""
    switch engine {
    case .chromium:
      // Chromium 地址栏 AXIdentifier 常见 "address_and_search_bar" / desc 含地址栏文案。
      return identifier == "address_and_search_bar"
        || desc.localizedCaseInsensitiveContains("address")
        || desc.localizedCaseInsensitiveContains("地址")
    case .webkit:
      // Safari 地址栏:聚焦后焦点元素是顶层 AXTextField,且 value 常是 URL/搜索词。
      // 退化策略:顶层 AXTextField 即认为是地址栏。
      return true
    case .gecko:
      return identifier.localizedCaseInsensitiveContains("urlbar")
        || desc.localizedCaseInsensitiveContains("address")
        || desc.localizedCaseInsensitiveContains("地址")
    }
  }

  // MARK: - AX 原语

  private static func copyElement(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let v = value, CFGetTypeID(v) == AXUIElementGetTypeID()
    else { return nil }
    return (v as! AXUIElement)
  }

  private static func copyChildren(_ element: AXUIElement) -> [AXUIElement]? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let arr = value as? [AXUIElement]
    else { return nil }
    return arr
  }

  private static func copyString(_ element: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let s = value as? String
    else { return nil }
    return s
  }

  private static func copyURL(_ element: AXUIElement, _ attr: String) -> URL? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let v = value
    else { return nil }
    if let url = v as? URL { return url }
    if let s = v as? String { return URL(string: s) }
    return nil
  }
}
```

- [ ] **Step 2: 编译**

Run:
```bash
swift build -c debug --arch arm64 --scratch-path .build --product Velto
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Velto/InputSourceSwitch/InputSourceSwitchBrowserAX.swift
git commit -m "feat(input-source-switch): 浏览器AX读取URL+地址栏焦点"
```

---

### Task 7: 上下文模型与监听

**Files:**
- Create: `Sources/Velto/InputSourceSwitch/InputSourceSwitchContext.swift`

- [ ] **Step 1: 创建上下文与监听器**

创建 `Sources/Velto/InputSourceSwitch/InputSourceSwitchContext.swift`：

```swift
import AppKit
import ApplicationServices
import Foundation

/// 当前输入上下文。
struct InputSourceContext: Equatable {
  enum Kind: Equatable {
    case app
    case website
    case addressBar
  }
  var kind: Kind
  var bundleID: String
  var url: URL?

  /// cache key / 日志用 ID。
  var contextID: String {
    switch kind {
    case .app: return "app:\(bundleID)"
    case .website: return "website:\(bundleID):\(url?.host ?? "")"
    case .addressBar: return "address-bar:\(bundleID)"
    }
  }
}

/// 监听前台 App / 浏览器 Tab 变化,算出 InputSourceContext 后回调。
/// AX 读取全部派发到 AXCallQueue.shared;回调统一跳回主线程。
@MainActor
final class InputSourceContextMonitor {
  /// 上下文变化回调(主线程)。
  var onContextChange: ((InputSourceContext) -> Void)?
  /// 由 Controller 注入:当前是否启用了浏览器规则检测(决定是否跑兜底轮询)。
  var browserDetectionEnabled: () -> Bool = { false }
  /// 由 Controller 注入:某 bundleID 是否被用户勾选为启用浏览器。
  var isBrowserEnabled: (String) -> Bool = { _ in false }

  private var axObserver: AXObserver?
  private var observedPID: pid_t?
  private var pollTimer: Timer?
  private var running = false

  func start() {
    guard !running else { return }
    running = true
    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(self, selector: #selector(activeAppChanged),
                   name: NSWorkspace.didActivateApplicationNotification, object: nil)
    nc.addObserver(self, selector: #selector(activeAppChanged),
                   name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    evaluate()
  }

  func stop() {
    guard running else { return }
    running = false
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    teardownAXObserver()
    pollTimer?.invalidate()
    pollTimer = nil
  }

  @objc private func activeAppChanged() {
    evaluate()
  }

  /// 重新计算当前上下文。前台是浏览器则走 AX 读 URL,否则是普通 App。
  func evaluate() {
    guard running, let front = NSWorkspace.shared.frontmostApplication,
          let bundleID = front.bundleIdentifier
    else { return }
    let pid = front.processIdentifier

    if let browser = SupportedBrowserCatalog.browser(forBundleID: bundleID),
       isBrowserEnabled(bundleID) {
      rewireAXObserver(pid: pid)
      reschedulePoll(isBrowserFront: true)
      let engine = browser.engine
      AXCallQueue.shared.schedule("input-source-browser:\(pid)") { [weak self] in
        let ctx = BrowserAXReader.readContext(pid: pid, engine: engine)
        DispatchQueue.main.async {
          guard let self, self.running else { return }
          self.emitBrowserContext(bundleID: bundleID, page: ctx)
        }
      }
    } else {
      teardownAXObserver()
      reschedulePoll(isBrowserFront: false)
      onContextChange?(InputSourceContext(kind: .app, bundleID: bundleID, url: nil))
    }
  }

  private func emitBrowserContext(bundleID: String, page: BrowserPageContext) {
    if page.addressBarFocused {
      onContextChange?(InputSourceContext(kind: .addressBar, bundleID: bundleID, url: page.url))
    } else if let url = page.url {
      onContextChange?(InputSourceContext(kind: .website, bundleID: bundleID, url: url))
    } else {
      // 取不到 URL:当成普通 App 处理(不强切)。
      onContextChange?(InputSourceContext(kind: .app, bundleID: bundleID, url: nil))
    }
  }

  // MARK: - AXObserver(浏览器 Tab/焦点/标题变化)

  private func rewireAXObserver(pid: pid_t) {
    if observedPID == pid, axObserver != nil { return }
    teardownAXObserver()

    var observer: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      let monitor = Unmanaged<InputSourceContextMonitor>.fromOpaque(refcon).takeUnretainedValue()
      DispatchQueue.main.async { monitor.evaluate() }
    }
    guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
    let appElement = AXUIElementCreateApplication(pid)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for note in [
      kAXFocusedWindowChangedNotification,
      kAXFocusedUIElementChangedNotification,
      kAXTitleChangedNotification,
      kAXWindowCreatedNotification,
    ] {
      AXObserverAddNotification(observer, appElement, note as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    axObserver = observer
    observedPID = pid
  }

  private func teardownAXObserver() {
    if let axObserver {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
    }
    axObserver = nil
    observedPID = nil
  }

  // MARK: - 兜底轮询(0.8s,仅浏览器前台 + 启用浏览器检测)

  private func reschedulePoll(isBrowserFront: Bool) {
    pollTimer?.invalidate()
    pollTimer = nil
    guard isBrowserFront, browserDetectionEnabled() else { return }
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.evaluate() }
    }
  }
}
```

- [ ] **Step 2: 编译**

Run:
```bash
swift build -c debug --arch arm64 --scratch-path .build --product Velto
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Velto/InputSourceSwitch/InputSourceSwitchContext.swift
git commit -m "feat(input-source-switch): 上下文模型+NSWorkspace/AXObserver/兜底轮询监听"
```

---

### Task 8: 控制器 + 生命周期

**Files:**
- Create: `Sources/Velto/InputSourceSwitch/InputSourceSwitchController.swift`
- Modify: `Sources/Velto/AppDelegate.swift`（启动 32 行后、停止 39 行后）

- [ ] **Step 1: 创建控制器**

创建 `Sources/Velto/InputSourceSwitch/InputSourceSwitchController.swift`：

```swift
import AppKit
import Carbon
import Foundation

/// 输入法自动切换的总指挥。单例,AppDelegate 持有。
///
///   ContextMonitor ──上下文──→ Controller ──决策──→ Selector(TIS 切换)
///                                  │
///                       runtime cache(内存) ←── 用户手动切换通知
///
/// 决策优先级见 spec §4。cache 仅内存,进程退出即清。
@MainActor
final class InputSourceSwitchController {
  static let shared = InputSourceSwitchController()

  private let monitor = InputSourceContextMonitor()
  /// 内存 runtime cache:contextID → 输入法持久化 ID。不持久化。
  private var cache: [String: String] = [:]
  /// 最近一次上下文(收到系统输入法变更通知时,据此更新 cache)。
  private var lastContext: InputSourceContext?
  /// 自切抑制:程序化切换会触发系统通知,期内不写 cache,避免回灌/反馈环。
  private var isApplyingProgrammaticSwitch = false
  private var running = false

  private init() {}

  // MARK: - 生命周期

  func start() {
    guard !running else { return }
    running = true
    let prefs = GestureStore.shared.preferences.inputSourceSwitch
    InputSourceSwitchDebugLog.setEnabled(prefs.debugLoggingEnabled)

    monitor.browserDetectionEnabled = {
      let p = GestureStore.shared.preferences.inputSourceSwitch
      return p.enabled && !p.enabledBrowserBundleIDs.isEmpty
    }
    monitor.isBrowserEnabled = { bundleID in
      GestureStore.shared.preferences.inputSourceSwitch.enabledBrowserBundleIDs.contains(bundleID)
    }
    monitor.onContextChange = { [weak self] ctx in
      self?.handleContext(ctx)
    }
    monitor.start()

    // 用户手动切换输入法 → 更新当前上下文 cache(用于 restorePreviouslyUsed)。
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(systemInputSourceChanged),
      name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil
    )
    // 偏好变化 → 同步调试开关 + 重新评估。
    NotificationCenter.default.addObserver(
      self, selector: #selector(storeChanged(_:)),
      name: .gestureStoreDidChange, object: GestureStore.shared
    )
  }

  func stop() {
    guard running else { return }
    running = false
    monitor.stop()
    DistributedNotificationCenter.default().removeObserver(self)
    NotificationCenter.default.removeObserver(self, name: .gestureStoreDidChange, object: GestureStore.shared)
  }

  @objc private func storeChanged(_ note: Notification) {
    guard note.gestureStoreChangeReason == .preferences
            || note.gestureStoreChangeReason == .backupImport else { return }
    InputSourceSwitchDebugLog.setEnabled(GestureStore.shared.preferences.inputSourceSwitch.debugLoggingEnabled)
    monitor.evaluate()
  }

  // MARK: - 决策

  private func handleContext(_ ctx: InputSourceContext) {
    lastContext = ctx
    let prefs = GestureStore.shared.preferences.inputSourceSwitch
    guard prefs.enabled else { return }

    guard let targetID = decideTarget(for: ctx, prefs: prefs) else {
      InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 无目标,保持当前")
      return
    }
    guard targetID != InputSourceCatalog.current()?.id else {
      InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 目标=当前(\(targetID)),不切")
      return
    }
    InputSourceSwitchDebugLog.log("context=\(ctx.contextID) → 切到 \(targetID)")
    isApplyingProgrammaticSwitch = true
    InputSourceSwitchSelector.select(
      persistentID: targetID,
      cjkFixEnabled: prefs.cjkFixEnabled,
      cjkFixStrategy: prefs.cjkFixStrategy
    )
    // 程序化切换会引发系统通知,延后一拍再解除抑制(覆盖 CJKV 二次事件)。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.isApplyingProgrammaticSwitch = false
    }
  }

  /// spec §4 决策算法。
  private func decideTarget(for ctx: InputSourceContext, prefs: InputSourceSwitchPreferences) -> String? {
    // 地址栏聚焦:瞬时强覆盖,不被 cache 覆盖。
    if ctx.kind == .addressBar, let addr = prefs.browserAddressDefaultInputSourceID {
      return addr
    }
    let base = defaultFor(ctx, prefs: prefs)
    if prefs.restoreStrategy == .restorePreviouslyUsed, let cached = cache[ctx.contextID] {
      return cached
    }
    return base
  }

  private func defaultFor(_ ctx: InputSourceContext, prefs: InputSourceSwitchPreferences) -> String? {
    // 浏览器网站规则(按 createdAt 升序,先匹配先命中)。
    if ctx.kind == .website, let url = ctx.url {
      let sorted = prefs.browserRules.filter { $0.isEnabled }.sorted { $0.createdAt < $1.createdAt }
      for rule in sorted where matches(rule: rule, url: url) {
        if let id = rule.inputSourceID { return id }
      }
    }
    // 应用规则。
    if let rule = prefs.appRules.first(where: { $0.isEnabled && $0.bundleIdentifier == ctx.bundleID }),
       let id = rule.inputSourceID {
      return id
    }
    // 全局默认兜底。
    return prefs.systemDefaultInputSourceID
  }

  /// 浏览器规则匹配。
  static func matches(rule: InputSourceBrowserRule, url: URL) -> Bool {
    switch rule.type {
    case .domain:
      return url.host == rule.value
    case .domainSuffix:
      return (url.host ?? "").hasSuffix(rule.value)
    case .urlRegex:
      guard let re = try? NSRegularExpression(pattern: rule.value) else { return false }
      let s = url.absoluteString
      return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
  }

  private func matches(rule: InputSourceBrowserRule, url: URL) -> Bool {
    Self.matches(rule: rule, url: url)
  }

  // MARK: - 用户手动切换 → 更新 cache

  @objc private func systemInputSourceChanged() {
    guard running, !isApplyingProgrammaticSwitch,
          let ctx = lastContext, ctx.kind != .addressBar,
          let current = InputSourceCatalog.current()?.id
    else { return }
    cache[ctx.contextID] = current
    InputSourceSwitchDebugLog.log("用户手动切换 → cache[\(ctx.contextID)] = \(current)")
  }
}
```

- [ ] **Step 2: AppDelegate 启动控制器**

`Sources/Velto/AppDelegate.swift` 第 32 行（切换器 `start()` 那个 `if` 块的 `}` 之后、`applicationDidFinishLaunching` 的方法体内）加：

```swift
        // 启动输入法自动切换:监听前台 App/浏览器上下文 → 按规则切输入法。
        InputSourceSwitchController.shared.start()
```

- [ ] **Step 3: AppDelegate 停止控制器**

第 39 行 `SwitcherController.shared.stop()` 之后加：

```swift
        InputSourceSwitchController.shared.stop()
```

- [ ] **Step 4: 编译**

Run:
```bash
swift build -c debug --arch arm64 --scratch-path .build --product Velto
```
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/Velto/InputSourceSwitch/InputSourceSwitchController.swift Sources/Velto/AppDelegate.swift
git commit -m "feat(input-source-switch): 控制器(决策+cache+自切抑制)+生命周期接入"
```

---

### Task 9: 设置页 UI + 侧边栏 + 权限入口

**Files:**
- Create: `Sources/Velto/InputSourceSwitch/InputSourceSwitchPage.swift`
- Create: `Sources/Velto/InputSourceSwitch/InputSourceSwitchRuleEditor.swift`
- Modify: `Sources/Velto/SettingsRootView.swift`（`MGPage` 枚举 3-27、`content` 49-58）
- Modify: `Sources/Velto/SidebarView.swift`（「功能」组 22-50）
- Modify: `Sources/Velto/PermissionManager.swift`

- [ ] **Step 1: MGPage 加 case**

`Sources/Velto/SettingsRootView.swift`：
- 第 4 行 `case gestures, mouseControl, window, switcher, general` 改为 `case gestures, mouseControl, window, switcher, inputSourceSwitch, general`
- `label`（8-16 行）的 `case .switcher: "窗口切换"` 之后加 `case .inputSourceSwitch: "输入法切换"`
- `icon`（18-26 行）的 `case .switcher: "rectangle.on.rectangle"` 之后加 `case .inputSourceSwitch: "keyboard.badge.ellipsis"`

- [ ] **Step 2: content 注册页面**

同文件 `content`（49-58 行）的 `pageContent(.switcher, ...) { SwitcherSettingsPage() }` 之后加：

```swift
            pageContent(.inputSourceSwitch, current: current) { InputSourceSwitchPage() }
```

- [ ] **Step 3: 侧边栏加入口**

`Sources/Velto/SidebarView.swift`「功能」组里 switcher 那个 `SidebarItem`（44-49 行）之后加：

```swift
                    SidebarItem(
                        icon: MGPage.inputSourceSwitch.icon,
                        label: MGPage.inputSourceSwitch.label,
                        badge: nil,
                        active: page == .inputSourceSwitch
                    ) { page = .inputSourceSwitch }
```

- [ ] **Step 4: PermissionManager 加打开键盘设置**

`Sources/Velto/PermissionManager.swift` 的 `openPrivacySettings()`（38-51 行）之后加：

```swift
    /// 打开「系统设置 → 键盘」,引导用户确认/设置「选择上一个输入法」快捷键。
    static func openKeyboardSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard"
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            NSWorkspace.shared.open(url)
            break
        }
    }
```

- [ ] **Step 5: 创建规则编辑器**

创建 `Sources/Velto/InputSourceSwitch/InputSourceSwitchRuleEditor.swift`：

```swift
import SwiftUI

/// 浏览器规则新增/编辑弹窗。应用规则走系统选 App 面板,不需要本编辑器。
struct BrowserRuleEditor: View {
  @Environment(\.dismiss) private var dismiss
  let sources: [InputSourceInfo]
  let initial: InputSourceBrowserRule
  let onSave: (InputSourceBrowserRule) -> Void

  @State private var draft: InputSourceBrowserRule

  init(
    sources: [InputSourceInfo],
    initial: InputSourceBrowserRule,
    onSave: @escaping (InputSourceBrowserRule) -> Void
  ) {
    self.sources = sources
    self.initial = initial
    self.onSave = onSave
    _draft = State(initialValue: initial)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("浏览器规则").font(.mgPageTitle).foregroundStyle(Color.mgText1)

      Picker("匹配类型", selection: $draft.type) {
        ForEach(InputSourceBrowserRuleType.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      TextField("匹配值(如 github.com)", text: $draft.value)
      TextField("示例 URL(如 https://github.com/x)", text: $draft.sample)

      Picker("目标输入法", selection: Binding(
        get: { draft.inputSourceID ?? "" },
        set: { draft.inputSourceID = $0.isEmpty ? nil : $0 }
      )) {
        Text("不指定").tag("")
        ForEach(sources) { Text($0.localizedName).tag($0.id) }
      }

      // 示例 URL 即时显示是否命中。
      if let url = URL(string: draft.sample), !draft.sample.isEmpty {
        let hit = InputSourceSwitchController.matches(rule: draft, url: url)
        Text(hit ? "✓ 示例 URL 命中" : "✗ 示例 URL 不命中")
          .font(.mgMeta)
          .foregroundStyle(hit ? Color.mgAccent : Color.mgText3)
      }

      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("保存") { onSave(draft); dismiss() }
          .keyboardShortcut(.defaultAction)
          .disabled(draft.value.isEmpty)
      }
    }
    .padding(24)
    .frame(width: 420)
  }
}
```

- [ ] **Step 6: 创建设置页（通用 + 应用规则 + 浏览器规则 + 故障排除）**

创建 `Sources/Velto/InputSourceSwitch/InputSourceSwitchPage.swift`。沿用 `SwitcherSettingsPage` 的 `row`/live-`bind` 视觉与 `GroupCard`：

```swift
import SwiftUI
import UniformTypeIdentifiers

struct InputSourceSwitchPage: View {
  private let store = GestureStore.shared

  private enum Segment: String, CaseIterable, Identifiable {
    case general, appRules, browserRules, troubleshooting
    var id: String { rawValue }
    var title: String {
      switch self {
      case .general: return "通用"
      case .appRules: return "应用规则"
      case .browserRules: return "浏览器规则"
      case .troubleshooting: return "故障排除"
      }
    }
  }

  @State private var segment: Segment = .general
  @State private var editingBrowserRule: InputSourceBrowserRule?
  @State private var showAppPicker = false

  /// 输入法候选(进页面取一次)。
  private var sources: [InputSourceInfo] { InputSourceCatalog.all() }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          PageHeader(
            tag: "Input Source",
            title: "输入法切换",
            subtitle: "根据当前 App 和浏览器网站自动切换输入法。"
          )
          Picker("", selection: $segment) {
            ForEach(Segment.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden()
          .pickerStyle(.segmented)

          switch segment {
          case .general: generalGroup
          case .appRules: appRulesGroup
          case .browserRules: browserRulesGroup
          case .troubleshooting: troubleshootingGroup
          }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 28)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(item: $editingBrowserRule) { rule in
      BrowserRuleEditor(sources: sources, initial: rule) { saved in
        store.updatePreferences { p in
          if let idx = p.inputSourceSwitch.browserRules.firstIndex(where: { $0.id == saved.id }) {
            p.inputSourceSwitch.browserRules[idx] = saved
          } else {
            p.inputSourceSwitch.browserRules.append(saved)
          }
        }
      }
    }
  }

  // MARK: - 通用

  private var generalGroup: some View {
    GroupCard(radius: MGRadius.cardLg) {
      VStack(spacing: 0) {
        row(icon: "power", title: "启用输入法切换",
            desc: "关闭后不再自动切换输入法。", showDivider: false) {
          AnyView(toggle(\.enabled))
        }
        row(icon: "globe", title: "全局默认输入法",
            desc: "无任何规则命中的 App 激活时切到它。", showDivider: true) {
          AnyView(sourcePicker(\.systemDefaultInputSourceID))
        }
        row(icon: "arrow.uturn.backward", title: "切回 App / 网站时",
            desc: "用默认,还是恢复上次在该上下文用过的输入法。", showDivider: true) {
          AnyView(enumPicker(\.restoreStrategy, cases: InputSourceRestoreStrategy.allCases) { $0.displayName })
        }
        row(icon: "magnifyingglass", title: "浏览器地址栏默认输入法",
            desc: "地址栏聚焦时切到它(常用于切英文)。", showDivider: true) {
          AnyView(sourcePicker(\.browserAddressDefaultInputSourceID))
        }
        row(icon: "ladybug", title: "调试日志",
            desc: "排查时打开,只写 input-source-switch.log。", showDivider: true) {
          AnyView(toggle(\.debugLoggingEnabled))
        }
        row(icon: "folder", title: "打开日志文件夹",
            desc: "~/Library/Logs/Velto/", showDivider: true) {
          AnyView(Button("打开") { openLogsFolder() })
        }
      }
    }
  }

  // MARK: - 应用规则

  private var appRulesGroup: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Spacer()
        Button {
          showAppPicker = true
        } label: { Label("从应用选择", systemImage: "plus") }
      }
      GroupCard(radius: MGRadius.cardLg) {
        VStack(spacing: 0) {
          let rules = store.preferences.inputSourceSwitch.appRules
          if rules.isEmpty {
            emptyHint("还没有应用规则。点右上角「从应用选择」添加。")
          }
          ForEach(rules) { rule in
            ruleRow(
              title: rule.displayName, subtitle: rule.bundleIdentifier,
              isEnabled: rule.isEnabled,
              sourceID: rule.inputSourceID,
              showDivider: rule.id != rules.first?.id,
              onToggle: { v in updateAppRule(rule.id) { $0.isEnabled = v } },
              onPick: { id in updateAppRule(rule.id) { $0.inputSourceID = id } },
              onDelete: { deleteAppRule(rule.id) }
            )
          }
        }
      }
    }
    .fileImporter(isPresented: $showAppPicker, allowedContentTypes: [.application]) { result in
      if case .success(let url) = result { addAppRule(fromAppAt: url) }
    }
  }

  // MARK: - 浏览器规则

  private var browserRulesGroup: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 10) {
        sectionLabel("启用的浏览器")
        GroupCard(radius: MGRadius.cardLg) {
          VStack(spacing: 0) {
            let installed = SupportedBrowserCatalog.installed()
            if installed.isEmpty { emptyHint("没检测到受支持的浏览器。") }
            ForEach(installed) { b in
              row(icon: "globe", title: b.displayName, desc: b.bundleID,
                  showDivider: b.id != installed.first?.id) {
                AnyView(Toggle("", isOn: Binding(
                  get: { store.preferences.inputSourceSwitch.enabledBrowserBundleIDs.contains(b.bundleID) },
                  set: { v in store.updatePreferences { p in
                    if v { p.inputSourceSwitch.enabledBrowserBundleIDs.insert(b.bundleID) }
                    else { p.inputSourceSwitch.enabledBrowserBundleIDs.remove(b.bundleID) }
                  } }
                )).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.mgAccent))
              }
            }
          }
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          sectionLabel("URL 规则")
          Spacer()
          Button {
            editingBrowserRule = InputSourceBrowserRule()
          } label: { Label("新增规则", systemImage: "plus") }
        }
        GroupCard(radius: MGRadius.cardLg) {
          VStack(spacing: 0) {
            let rules = store.preferences.inputSourceSwitch.browserRules
            if rules.isEmpty { emptyHint("还没有 URL 规则。") }
            ForEach(rules) { rule in
              ruleRow(
                title: "\(rule.type.displayName): \(rule.value)", subtitle: rule.sample,
                isEnabled: rule.isEnabled, sourceID: rule.inputSourceID,
                showDivider: rule.id != rules.first?.id,
                onToggle: { v in updateBrowserRule(rule.id) { $0.isEnabled = v } },
                onPick: { id in updateBrowserRule(rule.id) { $0.inputSourceID = id } },
                onDelete: { deleteBrowserRule(rule.id) },
                onEdit: { editingBrowserRule = rule }
              )
            }
          }
        }
      }
    }
  }

  // MARK: - 故障排除

  private var troubleshootingGroup: some View {
    GroupCard(radius: MGRadius.cardLg) {
      VStack(spacing: 0) {
        row(icon: "wrench.and.screwdriver", title: "修复输入法切换问题(CJKV)",
            desc: "中日韩越输入法切了图标变但实际没切时打开。", showDivider: false) {
          AnyView(toggle(\.cjkFixEnabled))
        }
        row(icon: "slider.horizontal.3", title: "CJKV 修复策略",
            desc: "默认「模拟上一个输入法快捷键」;临时窗口会瞬时抢焦点。", showDivider: true) {
          AnyView(enumPicker(\.cjkFixStrategy, cases: InputSourceCJKFixStrategy.allCases) { $0.displayName })
        }
        if store.preferences.inputSourceSwitch.cjkFixStrategy == .previousInputSourceShortcut,
           InputSourceSwitchSelector.previousInputSourceShortcut() == nil {
          row(icon: "exclamationmark.triangle", title: "系统未配置「选择上一个输入法」快捷键",
              desc: "该策略依赖此系统快捷键,请到键盘设置开启。", showDivider: true) {
            AnyView(Button("打开键盘设置") { PermissionManager.openKeyboardSettings() })
          }
        }
      }
    }
  }

  // MARK: - 行/控件 helper

  private func row(icon: String, title: String, desc: String?, showDivider: Bool,
                   @ViewBuilder control: () -> AnyView) -> some View {
    VStack(spacing: 0) {
      if showDivider {
        Rectangle().fill(Color.mgHair).frame(height: 0.5).padding(.leading, 78)
      }
      HStack(alignment: .center, spacing: 16) {
        ActionIcon(systemName: icon)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.mgText1)
          if let desc { Text(desc).font(.system(size: 12)).foregroundStyle(Color.mgText2) }
        }
        Spacer(minLength: 12)
        control()
      }
      .padding(.horizontal, 20).padding(.vertical, 16)
    }
  }

  private func ruleRow(
    title: String, subtitle: String, isEnabled: Bool, sourceID: String?,
    showDivider: Bool,
    onToggle: @escaping (Bool) -> Void, onPick: @escaping (String?) -> Void,
    onDelete: @escaping () -> Void, onEdit: (() -> Void)? = nil
  ) -> some View {
    row(icon: "list.bullet", title: title, desc: subtitle.isEmpty ? nil : subtitle, showDivider: showDivider) {
      AnyView(HStack(spacing: 10) {
        Picker("", selection: Binding(get: { sourceID ?? "" }, set: { onPick($0.isEmpty ? nil : $0) })) {
          Text("不指定").tag("")
          ForEach(sources) { Text($0.localizedName).tag($0.id) }
        }.labelsHidden().frame(minWidth: 140)
        Toggle("", isOn: Binding(get: { isEnabled }, set: { onToggle($0) }))
          .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.mgAccent)
        if let onEdit { Button { onEdit() } label: { Image(systemName: "pencil") }.buttonStyle(.borderless) }
        Button { onDelete() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
      })
    }
  }

  private func sectionLabel(_ t: String) -> some View {
    Text(t).font(.mgSubLabel).foregroundStyle(Color.mgText3).padding(.leading, 4)
  }

  private func emptyHint(_ t: String) -> some View {
    Text(t).font(.system(size: 13)).foregroundStyle(Color.mgText3)
      .frame(maxWidth: .infinity, alignment: .leading).padding(20)
  }

  private func toggle(_ kp: WritableKeyPath<InputSourceSwitchPreferences, Bool>) -> some View {
    Toggle("", isOn: Binding(
      get: { store.preferences.inputSourceSwitch[keyPath: kp] },
      set: { v in store.updatePreferences { $0.inputSourceSwitch[keyPath: kp] = v } }
    )).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.mgAccent)
  }

  private func sourcePicker(_ kp: WritableKeyPath<InputSourceSwitchPreferences, String?>) -> some View {
    Picker("", selection: Binding(
      get: { store.preferences.inputSourceSwitch[keyPath: kp] ?? "" },
      set: { v in store.updatePreferences { $0.inputSourceSwitch[keyPath: kp] = v.isEmpty ? nil : v } }
    )) {
      Text("不指定").tag("")
      ForEach(sources) { Text($0.localizedName).tag($0.id) }
    }.labelsHidden().frame(minWidth: 160)
  }

  private func enumPicker<E: Hashable>(
    _ kp: WritableKeyPath<InputSourceSwitchPreferences, E>,
    cases: [E], name: @escaping (E) -> String
  ) -> some View {
    Picker("", selection: Binding(
      get: { store.preferences.inputSourceSwitch[keyPath: kp] },
      set: { v in store.updatePreferences { $0.inputSourceSwitch[keyPath: kp] = v } }
    )) { ForEach(cases, id: \.self) { Text(name($0)).tag($0) } }
      .labelsHidden().frame(minWidth: 160)
  }

  // MARK: - 规则增删改

  private func addAppRule(fromAppAt url: URL) {
    guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { return }
    let name = (bundle.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
    store.updatePreferences { p in
      guard !p.inputSourceSwitch.appRules.contains(where: { $0.bundleIdentifier == bid }) else { return }
      p.inputSourceSwitch.appRules.append(InputSourceAppRule(
        bundleIdentifier: bid, displayName: name, bundlePath: url.path
      ))
    }
  }

  private func updateAppRule(_ id: UUID, _ mutate: (inout InputSourceAppRule) -> Void) {
    store.updatePreferences { p in
      if let idx = p.inputSourceSwitch.appRules.firstIndex(where: { $0.id == id }) {
        mutate(&p.inputSourceSwitch.appRules[idx])
      }
    }
  }

  private func deleteAppRule(_ id: UUID) {
    store.updatePreferences { $0.inputSourceSwitch.appRules.removeAll { $0.id == id } }
  }

  private func updateBrowserRule(_ id: UUID, _ mutate: (inout InputSourceBrowserRule) -> Void) {
    store.updatePreferences { p in
      if let idx = p.inputSourceSwitch.browserRules.firstIndex(where: { $0.id == id }) {
        mutate(&p.inputSourceSwitch.browserRules[idx])
      }
    }
  }

  private func deleteBrowserRule(_ id: UUID) {
    store.updatePreferences { $0.inputSourceSwitch.browserRules.removeAll { $0.id == id } }
  }

  private func openLogsFolder() {
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Logs/Velto", isDirectory: true)
    if let url { NSWorkspace.shared.open(url) }
  }
}
```

> 说明：应用规则的「从应用选择」用 `.fileImporter` + `.application` 类型，免去自定义 NSOpenPanel；目标输入法、启用、删除都在行内 live-save。`enumPicker` 用 `.menu` 默认样式即可。

- [ ] **Step 7: 编译**

Run:
```bash
swift build -c debug --arch arm64 --scratch-path .build --product Velto
```
Expected: `Build complete!`

> 若 `enumPicker` 的泛型 `Picker` 推断报错，给 `Picker` 显式 `.pickerStyle(.menu)`。

- [ ] **Step 8: Commit**

```bash
git add Sources/Velto/InputSourceSwitch/InputSourceSwitchPage.swift Sources/Velto/InputSourceSwitch/InputSourceSwitchRuleEditor.swift Sources/Velto/SettingsRootView.swift Sources/Velto/SidebarView.swift Sources/Velto/PermissionManager.swift
git commit -m "feat(input-source-switch): 设置页(分段UI)+侧边栏入口+键盘设置入口"
```

---

### Task 10: 集成验证与部署

**Files:** 无新增/修改（纯验证）。

- [ ] **Step 1: 打包部署并运行**

Run:
```bash
./scripts/build-app.sh --run
```
Expected: 构建成功，`/Applications/Velto.app` 被覆盖，新进程启动。

Run:
```bash
pgrep -af "/Applications/Velto.app/Contents/MacOS/Velto"
```
Expected: 能看到正在运行的 Velto 进程。

- [ ] **Step 2: 手动验证清单（逐项打勾）**

- [ ] 侧边栏出现「输入法切换」，可进入页面，四个分段都能切换、UI 正常。
- [ ] 通用页设全局默认输入法 → 开总开关 → 切到一个无规则 App → 自动切到默认。
- [ ] 应用规则：「从应用选择」添加一个 App、设目标输入法 → 切到该 App → 目标输入法生效。
- [ ] 浏览器规则：启用 Chrome/Safari → 加 `domainSuffix=github.com` 规则设中文 → 访问 github.com → 自动切。
- [ ] 切 Tab / 改 URL → 规则重新匹配（0.8s 内或即时）。
- [ ] 地址栏聚焦 → 切到地址栏默认输入法。
- [ ] **CJKV：目标设中文输入法，切过去后实际键入就是中文**（验证 CJKV 修复生效，不是只换了图标）。
- [ ] 触发 CJKV「上一个输入法」合成快捷键时，不误触发手势 / 切换器 / 窗口快捷键（暗号生效）。
- [ ] 关总开关 → 不再自动切。
- [ ] 开调试日志 → `~/Library/Logs/Velto/input-source-switch.log` 有 context/select 记录；该文件与 `switcher-debug.log` 独立。
- [ ] `restoreStrategy=恢复上次使用` 下：在某 App 手动切输入法 → 切走再切回 → 恢复到手动切的那个。

- [ ] **Step 3: 验证老配置兼容**

确认升级安装后旧偏好不丢（手势/切换器配置仍在），新字段走默认。若有问题，检查 Task 1 的 `decodeIfPresent` 接入。

- [ ] **Step 4: 收尾提交（如验证中有微调）**

```bash
git add -A
git commit -m "chore(input-source-switch): 集成验证微调"
```

---

## 自检

**1. Spec 覆盖：**
- §1 范围（总开关/全局默认/应用规则/浏览器规则/地址栏默认/恢复策略/CJKV/调试日志）→ Task 1/8/9（配置+决策+UI）、Task 4（CJKV）、Task 2（日志）。✓
- §2 模块结构（10 文件）→ Task 1-9 逐个创建。✓
- §3 数据模型 → Task 1。✓
- §4 决策优先级（地址栏强覆盖 / cache 在 default 前 / restoreStrategy 门控）→ Task 8 `decideTarget`/`defaultFor`。✓
- §5 TIS 枚举 + CJKV 两策略 → Task 3 + Task 4。✓
- §6 EventTapManager 暗号（三分支，含 flagsChanged 新增）→ Task 4 Step 2-4。✓
- §7 上下文监听（NSWorkspace + AXObserver + 0.8s 轮询，走 AXCallQueue）→ Task 7。✓
- §8 浏览器列表 + AX DFS + 归一化 + 地址栏焦点脆弱点 → Task 5 + Task 6。✓
- §9 runtime cache 内存 + 自切抑制 → Task 8。✓
- §10 UI（侧边栏 + 分段页）→ Task 9。✓
- §11 权限（打开键盘设置；无 Info.plist 改动）→ Task 9 Step 4。✓
- §12 调试日志独立文件 → Task 2。✓
- §13 差异（cache 内存 / 暗号 / 优先级修正 / 不做光标修复 / 默认关 / 不改 Package）→ 全部落到对应任务，光标修复未列入任何任务（正确，本期不做）。✓

**2. 占位符扫描：** 无 TBD/TODO；每个改代码的 Step 都给了完整代码或精确 diff。✓

**3. 类型一致性：**
- `InputSourceSwitchSelector.syntheticEventMarker`（Task 4 定义）= EventTapManager 三分支引用（Task 4 Step 2-4）。✓
- `InputSourceCatalog.all()/current()/tisInputSource(forID:)`（Task 3）= Selector/Controller/Page 调用。✓
- `InputSourceSwitchController.matches(rule:url:)` 为 `static`（Task 8），被 `BrowserRuleEditor`（Task 9）和实例 `defaultFor` 调用 —— 两处签名一致。✓
- `BrowserAXReader.readContext(pid:engine:)`（Task 6）= Context 调用（Task 7）。✓
- `SupportedBrowserCatalog.browser(forBundleID:)/installed()`（Task 5）= Context/Page 调用。✓
- `InputSourceSwitchPreferences` 字段名（Task 1）= Page 的 KeyPath 绑定（Task 9）一致。✓

无遗留问题。
