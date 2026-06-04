# InputSourceSwitch 设计（按 App / 网站自动切换输入法）

> 状态：设计已与用户对齐，等待 spec 评审 → 通过后进入 writing-plans。
> 参考：用户文档 `~/Desktop/2026-06-04-input-source-switch.md`；行为参考来源
> 项目 InputSourcePro（GPL-3.0，**只参考行为，不复制源码**）。

## 1. 目标与范围

在 Velto 里新增一个模块 `InputSourceSwitch`，根据**当前前台 App** 和**浏览器当前网站**自动切换 macOS 输入法（输入源 / Input Source）。侧边栏新增入口「输入法切换」。业务入口、开关、调试日志、设计组件全部对齐 Velto 现有约定。

### 本期做（v1 核心）

- 侧边栏入口「输入法切换」+ 总开关。
- 全局默认输入法（兜底）：无任何规则命中的 App 激活时切到它。
- 应用规则：按 App `bundleIdentifier` → 目标输入法。
- 浏览器规则：按当前 Tab 的 URL（域名后缀 / 精确域名 / 正则）→ 目标输入法。
- 浏览器地址栏默认输入法：地址栏聚焦时切到它（典型用于切英文）。
- 切回 App / 网站时的恢复策略：用默认 / 恢复上次在该上下文用过的输入法。
- CJKV 修复（两策略）：`previousInputSourceShortcut` 与 `temporaryInputWindow`。
- 调试日志：独立写 `~/Library/Logs/Velto/input-source-switch.log`。
- 完成后跑 `./scripts/build-app.sh --run`。

### 本期不做（用户截图红框 + 明确裁掉）

- 位置 / 外观 / 颜色方案 / 快捷键（快捷键组）—— 截图圈出，全不做。
- 输入法指示器浮窗及其样式、Function Keys 切换、英文标点强制转换、反馈/推广卡片。
- Sparkle / LaunchAtLogin / CoreData / RxSwift / AXSwift 等 InputSourcePro 的外部依赖一律不迁。
- **光标延迟修复**（`sudo defaults write … redesigned_text_cursor`）：见 §13 差异说明，v1 不做。

## 2. 架构总览

沿用 InputSourcePro 的业务语义，但用 Velto 原生 AppKit/AX/Carbon 重写，去掉 ViewModel 体系。核心链路：

```text
NSWorkspace / AX 通知 / 兜底轮询
  → Context(算出当前上下文：普通 App 还是浏览器+URL+地址栏焦点)
  → Controller(按优先级决策目标输入法 + 维护 runtime cache)
  → Selector(TISSelectInputSource + 必要时 CJKV 修复)
  → 系统输入法切换
```

所有 AX 读取走 Velto 已有的 `AXCallQueue.shared`（后台串行队列 + 1s 超时），绝不在主线程同步等。

### 模块文件（新建 `Sources/Velto/InputSourceSwitch/`，10 个文件）

```text
InputSourceSwitchPreferences.swift   配置模型 + 规则模型 + 枚举（接入 AppPreferences）
InputSourceSwitchSource.swift        TIS 枚举/读取/持久化 ID 解析/当前输入法
InputSourceSwitchSelector.swift      TISSelectInputSource + CJKV 两策略 + 合成事件暗号
InputSourceSwitchContext.swift       前台 App / 浏览器 / URL / 地址栏焦点 的上下文模型与监听
InputSourceSwitchBrowser.swift       支持浏览器枚举 + 已安装检测
InputSourceSwitchBrowserAX.swift     AX 取 focused window → DFS 找 AXWebArea → 读 URL/地址栏焦点
InputSourceSwitchController.swift     单例总指挥：决策优先级 + runtime cache + 自切抑制 + 生命周期
InputSourceSwitchDebugLog.swift      独立调试日志通道（仿 SwitcherDebugLog）
InputSourceSwitchPage.swift          设置页（分段：通用 | 应用规则 | 浏览器规则 | 故障排除）
InputSourceSwitchRuleEditor.swift    应用规则 / 浏览器规则的新增-编辑弹窗
```

### 改动的现有文件

```text
Models.swift          AppPreferences 加 inputSourceSwitch 字段（decodeIfPresent 兼容老配置）
AppDelegate.swift     启动/停止 InputSourceSwitchController.shared
SettingsRootView.swift  加 MGPage.inputSourceSwitch + InputSourceSwitchPage()
SidebarView.swift     「功能」组加入口「输入法切换」
EventTapManager.swift  .keyDown/.keyUp/.flagsChanged 三个分支加 Selector 暗号早退（见 §6）
PermissionManager.swift 加「打开键盘设置」入口方法
```

> **Package.swift 不改**：SwiftPM 按目录 glob 收 `Sources/Velto` 下所有源文件，新目录自动纳入。v1 走手工验证（与切换器一致，无单元测试），不加 test target。

## 3. 数据模型

`InputSourceSwitchPreferences` 嵌进 `AppPreferences`，与手势 / 窗口管理 / 切换器共享同一份 `Velto.preferences` JSON。字段规则与现有结构完全一致：**只能加不能改/删**，`init(from:)` 用 `decodeIfPresent` 兜底到 `defaults`。

```swift
struct InputSourceSwitchPreferences: Codable, Equatable {
  var enabled: Bool
  var debugLoggingEnabled: Bool
  /// 全局默认输入法持久化 ID；nil = 不设兜底（无规则命中时保持当前）。
  var systemDefaultInputSourceID: String?
  /// 浏览器地址栏默认输入法；nil = 地址栏不特殊处理。
  var browserAddressDefaultInputSourceID: String?
  var restoreStrategy: InputSourceRestoreStrategy
  var cjkFixEnabled: Bool
  var cjkFixStrategy: InputSourceCJKFixStrategy
  /// 启用了浏览器规则检测的浏览器 bundle id 集合。
  var enabledBrowserBundleIDs: Set<String>
  var appRules: [InputSourceAppRule]
  var browserRules: [InputSourceBrowserRule]

  static let defaults = InputSourceSwitchPreferences(
    enabled: false,                       // 新功能默认关，用户显式开
    debugLoggingEnabled: false,
    systemDefaultInputSourceID: nil,
    browserAddressDefaultInputSourceID: nil,
    restoreStrategy: .useDefaultInputSource,
    cjkFixEnabled: true,                  // CJKV 修复默认开（不开切了不生效是更糟的体验）
    cjkFixStrategy: .previousInputSourceShortcut,
    enabledBrowserBundleIDs: [],
    appRules: [],
    browserRules: []
  )
}
```

> **总开关默认 `false`**：与切换器（默认 true）不同。切换器是接管 Cmd+Tab 的"换皮"，默认开无副作用；输入法自动切换会"擅自改用户输入法"，必须用户显式打开并配置后才动，否则是惊吓。

应用规则——匹配键只用 `bundleIdentifier`，其余字段供 UI 展示：

```swift
struct InputSourceAppRule: Codable, Identifiable, Equatable {
  var id: UUID
  var bundleIdentifier: String
  var displayName: String
  var bundlePath: String?
  var inputSourceID: String?   // nil = 该 App 不强制（占位/暂不生效）
  var isEnabled: Bool
  var createdAt: Date
}
```

浏览器规则：

```swift
enum InputSourceBrowserRuleType: String, Codable, CaseIterable {
  case domainSuffix   // host.hasSuffix(value)
  case domain         // host == value
  case urlRegex       // 对完整 URL 做正则
}

struct InputSourceBrowserRule: Codable, Identifiable, Equatable {
  var id: UUID
  var type: InputSourceBrowserRuleType
  var value: String
  var sample: String          // 示例 URL，用于编辑器即时显示是否匹配
  var inputSourceID: String?
  var isEnabled: Bool
  var createdAt: Date
}
```

多条浏览器规则按 `createdAt` 升序，先匹配先命中（v1 不做拖拽排序）。

恢复策略：

```swift
enum InputSourceRestoreStrategy: String, Codable, CaseIterable {
  case useDefaultInputSource   // 总是用规则/默认算出来的
  case restorePreviouslyUsed   // 优先恢复上次在该上下文用过的
}

enum InputSourceCJKFixStrategy: String, Codable, CaseIterable {
  case previousInputSourceShortcut   // 合成「选择上一个输入法」快捷键
  case temporaryInputWindow          // 透明临时窗口短暂抢焦点确认
}
```

输入法持久化 ID 格式（与 InputSourcePro 一致）：`sourceID::inputModeID`，区分同一 source 下不同输入模式。

## 4. 决策优先级（对齐 InputSourcePro）

InputSourcePro 的真实逻辑是：

```text
getAppAutoSwitchKeyboard = cache[contextId] ?? getAppDefaultKeyboard ?? systemWideDefault
getAppDefaultKeyboard    = 地址栏默认 → 浏览器规则 → 应用规则 → systemWideDefault
```

注意：**cache 在 default 之前**。用户文档 §5 把 cache 排在规则之后（第 4 位），与来源行为不符。v1 采用来源语义，并把"是否查 cache"用 `restoreStrategy` 显式门控。最终算法：

```text
决策(context):
  若总开关关 → 不处理

  // 地址栏聚焦是瞬时强覆盖：浏览器 + 地址栏聚焦 + 设了地址栏默认
  若 context.isBrowser && context.addressBarFocused && addressBarDefault != nil:
      target = addressBarDefault            // 独立上下文，不被 cache 覆盖
  否则:
      base = defaultFor(context)            // 地址栏default不计；见下
      若 restoreStrategy == .restorePreviouslyUsed && cache[context.id] != nil:
          target = cache[context.id]
      否则:
          target = base

  若 target == nil → 保持当前输入法，结束
  若 target == 当前输入法 → 不切，结束
  Selector.select(target)                   // 内部按需 CJKV 修复
  写调试日志

defaultFor(context):
  若 context.isBrowser && context.url 命中某条启用的浏览器规则 → 该规则 inputSource
  否则若 context.app 命中某条启用的应用规则 → 该规则 inputSource
  否则 → systemDefaultInputSourceID（nil 表示无兜底）
```

上下文 ID（cache key 与日志用）：

```text
普通 App:   app:<bundleIdentifier>
浏览器网站: website:<browserBundleID>:<host>
地址栏:     address-bar:<browserBundleID>   // 瞬时态，v1 不写 cache
```

## 5. 输入法枚举与切换

### 枚举（InputSourceSwitchSource）

`TISCreateInputSourceList(nil, false)` 取全部，过滤：

- 类别 `kTISTypeKeyboardInputSource`（键盘输入源，排除手写板等）。
- `kTISPropertyInputSourceIsSelectCapable == true`（可被选中）。

每个输入法暴露：持久化 ID（`sourceID::inputModeID`）、本地化显示名、所属语言、`isCJKV`（语言前缀 zh/ja/ko/vi 等，用于决定是否要 CJKV 修复）。当前输入法用 `TISCopyCurrentKeyboardInputSource()`。

### 切换（InputSourceSwitchSelector）

```text
select(persistentID):
  解析 persistentID → 在枚举列表里找到 TISInputSource
  TISSelectInputSource(source)
  若 cjkFixEnabled && source.isCJKV:
      按 cjkFixStrategy 补一次确认
```

为什么需要 CJKV 修复：macOS 上对中日韩越输入法，`TISSelectInputSource` 后菜单栏图标变了，但实际键入仍走旧 IME，必须额外"踢一脚"。两策略：

- `previousInputSourceShortcut`（默认）：读 `com.apple.symbolichotkeys` 里 id `60`（"选择上一个输入法"）的快捷键，**合成**一组按键事件触发它，让系统真正落到目标 IME。不抢焦点。**缺点**：依赖用户配过该系统快捷键；没配则失效，UI 要提示去键盘设置开启。
- `temporaryInputWindow`：创建一个透明 3×3 窗口短暂抢焦点再还回去，逼 macOS 重新确认输入上下文（macism 的 MIT 思路）。**缺点**：瞬时抢焦点，对部分浮窗类 App 有副作用，故只在用户显式选择时启用。

## 6. ★ 与 EventTapManager 的合成事件协同（用户文档完全没提，关键补充）

`previousInputSourceShortcut` 策略要**合成键盘事件**（keyDown/keyUp，且带修饰键 → 可能产生 flagsChanged）。但 Velto 有一个**常驻的 `EventTapManager`**，会拦截所有键鼠事件喂给手势引擎 / 切换器 / 窗口快捷键。我们自己合成的按键会被自己的 tap 再次吃掉，误触发别的功能 —— 这是必须处理的冲突。

Velto 已有成熟的「暗号」模式：合成事件时在 `.eventSourceUserData` 写一个独有常数，tap 在分发最前面识别到这个常数就**原样透传、绝不介入**。现有 3 处：

- `gestureEngine.rightClickSyntheticMarker`（右键事件，`EventTapManager.swift:329/364/377`）
- `ShortcutSynthesizer.syntheticEventMarker`（keyDown/keyUp，`EventTapManager.swift:424/442`）
- `MouseControlController.syntheticScrollMarker`（滚轮，`EventTapManager.swift:476`）

本期照搬：在 `InputSourceSwitchSelector` 定义 `static let syntheticEventMarker: Int64`（取一个与上述 3 个都不同的常数），合成的每个事件都写上它；并在 `EventTapManager.handle(...)` 的三个分支加早退：

```swift
case .keyDown:
  if event.getIntegerValueField(.eventSourceUserData) == ShortcutSynthesizer.syntheticEventMarker
      || event.getIntegerValueField(.eventSourceUserData) == InputSourceSwitchSelector.syntheticEventMarker {
    return Unmanaged.passUnretained(event)
  }
  …

case .keyUp:
  // 同上，追加 InputSourceSwitchSelector.syntheticEventMarker 判断

case .flagsChanged:
  // 当前该分支【没有任何暗号判断】—— 必须新增一个早退，
  // 否则合成快捷键的修饰键 flagsChanged 会污染 mouseControl/contentZoom/windowDrag 的修饰键状态机
  if event.getIntegerValueField(.eventSourceUserData) == InputSourceSwitchSelector.syntheticEventMarker {
    return Unmanaged.passUnretained(event)
  }
  …
```

> 用户已确认采用「暗号」方案（保留完整 CJKV 修复，通过 marker 与 tap 共存），不退化为默认 `temporaryWindow`。

## 7. 上下文监听（InputSourceSwitchContext）

监听来源（与 InputSourcePro 一致，全部最终落到 `AXCallQueue.shared` 上做 AX 读取）：

- `NSWorkspace.shared.notificationCenter`：`didActivateApplicationNotification`、`activeSpaceDidChangeNotification`。
- 对前台浏览器注册 `AXObserver` 通知：`kAXFocusedWindowChangedNotification`、`kAXFocusedUIElementChangedNotification`、`kAXTitleChangedNotification`、`kAXWindowCreatedNotification`。切到别的浏览器时换观察对象。
- **兜底轮询**：仅当「启用了浏览器规则 + 当前前台是已启用浏览器」时，0.8s 低频查一次当前 URL —— 某些浏览器 AX 通知不全，靠它补漏。前台不是浏览器时停轮询。

每次上下文变化 → 计算上下文 → 交给 Controller 决策。AX 读取按 `app:<pid>` 之类的 key 在队列上节流（同 App 连续事件只处理最新一个）。

## 8. 浏览器 URL 检测（InputSourceSwitchBrowser / BrowserAX）

### 支持浏览器（v1，bundle id）

Safari / Safari Technology Preview / Chrome / Chromium / Arc / Edge / Brave(+beta/nightly) / Vivaldi / Opera / Thorium / Firefox(+dev/nightly) / Zen / Dia。UI 只展示**本机已安装或在运行**的浏览器，但保留历史配置不丢。

### URL 读取流程

```text
AXUIElementCreateApplication(pid)
  → kAXFocusedWindowAttribute
  → DFS 遍历 children（带深度上限，防 AX 树异常时爆栈/卡死）
  → 找 role == AXWebArea
  → 读 AXURL
  → 过滤 chrome-extension:// 之类
  → 去掉 fragment 规范化
```

Safari 在新标签页可能取不到 URL，退化为占位 `velto-input-source://newtab`（规则不会误命中）。读不到就**记日志、不强切**，绝不乱改输入法。

### 地址栏聚焦检测（脆弱点，照搬 InputSourcePro）

判断"地址栏是否聚焦"靠每个浏览器各自的 DOM 标识 / class 列表 + 一张巨大的本地化文案表（`chromiumSearchBarDescMap` 那类）。**这本质上是脆弱的**：浏览器升级、换语言、换内核都可能让它失效。v1 决定：

- 直接参考 InputSourcePro 的判定数据（用户已确认"直接参考 InputSourcePro"）。
- 失效时的退化是良性的：当成"不在地址栏" → 走网站规则，最坏是地址栏没切到英文，不会切错。
- 这是已知技术债，写进调试日志便于日后定位，不作为 v1 阻塞项。

## 9. Runtime cache（in-memory）

`[contextId: persistentInputSourceID]` 内存字典，进程退出即清，**不持久化、不进导出配置**。这与 InputSourcePro 实际实现一致；用户文档 §4 建议单独写 `UserDefaults` 键，被本设计否决（理由见 §13）。

- 仅 `restoreStrategy == .restorePreviouslyUsed` 时才被查询。
- 写入时机：监听 `kTISNotifySelectedKeyboardInputSourceChanged`，**用户手动**切换输入法时，把"当前上下文 → 新输入法"写进 cache。

### 自切抑制（必须，否则反馈环）

我们自己调 `TISSelectInputSource` 也会触发 `kTISNotifySelectedKeyboardInputSourceChanged`。Controller 在发起程序化切换前后设一个 `isApplyingProgrammaticSwitch` 标志（或一个极短的时间窗），通知回调在标志期内**跳过 cache 写入**，避免把"我们刚设的值"当成"用户手动切的值"反复回灌、甚至与 CJKV 修复的二次事件打架。

## 10. UI 设计

### 侧边栏

「功能」组在「窗口切换」之后追加「输入法切换」，图标 `keyboard.badge.ellipsis`（`SidebarView.swift` 的 `SidebarGroup("功能")` 内，`MGPage.inputSourceSwitch`）。

### 设置页（InputSourceSwitchPage）

沿用 `SwitcherSettingsPage` 的视觉：`PageHeader` + `GroupCard` + 行组件 + `.mgAccent/.mgText*` + `MGRadius`，**live-save**（改一项即 `store.updatePreferences`）。顶部分段：

```text
通用 | 应用规则 | 浏览器规则 | 故障排除
```

- **通用**：启用总开关；全局默认输入法 Picker；恢复策略 Picker；浏览器地址栏默认输入法 Picker；调试日志 Toggle；打开日志文件夹按钮。
- **应用规则**：从运行中的 App 添加 / 从 `/Applications` 选 App；列表（图标、名称、bundle id、目标输入法 Menu、启用开关、删除）。
- **浏览器规则**：已安装浏览器的启用开关；规则列表；新增/编辑弹窗（类型、匹配值、示例 URL、目标输入法、启用），示例 URL 即时显示是否命中。
- **故障排除**：CJKV 修复 Toggle + 策略选择；若选「上一个输入法快捷键」但系统未配该快捷键，提示去键盘设置。

输入法 Picker 的候选来自 `InputSourceSwitchSource` 的枚举（显示本地化名，存持久化 ID）。

## 11. 权限

- 浏览器 URL / 地址栏检测需要**辅助功能**权限 —— Velto 已申请（切换器/手势都在用），`Info.plist` 无需新增。
- 运行期无辅助功能权限：只跳过浏览器检测，应用规则 + 全局默认照常工作；页面给提示 + 打开辅助功能设置按钮。
- CJKV `previousInputSourceShortcut`：在 `PermissionManager` 加「打开键盘设置」入口，引导用户确认/设置系统「选择上一个输入法」快捷键。

## 12. 调试日志（InputSourceSwitchDebugLog）

完全仿 `SwitcherDebugLog`：

- 独立文件 `~/Library/Logs/Velto/input-source-switch.log`，**与切换器/手势各写各的，互不污染**。
- 运行时开关由设置页 Toggle 经 Controller 驱动；保留环境变量 `VELTO_INPUT_SOURCE_DEBUG=1` 作开发期强制开启。
- 关闭时零文件开销（首次写才开句柄）。
- 记录维度：context（上下文变化）、match（命中哪条规则）、select（切了什么、成功/失败）、cjk-fix（用了哪个策略）、error。

## 13. 与参考文档的差异（我的判断 + 理由）

1. **runtime cache 用内存，不写 UserDefaults**（文档 §4 建议写 `Velto.inputSourceSwitch.runtimeCache`）。
   - 理由：cache 是会话内的瞬时状态，跨重启恢复"上次用过的输入法"价值低、却要承担脏数据/迁移/导出污染的成本；InputSourcePro 本身也是内存实现。保持内存最简单且行为对齐来源。
2. **补上 EventTapManager 合成事件冲突处理**（文档完全没提，见 §6）。这是 Velto 特有、且必须处理的集成点，是本设计最重要的新增。
3. **修正决策优先级里 cache 与规则默认的先后**（文档 §5 把 cache 排在规则之后；来源是 `cache ?? default`，cache 在前），并用 `restoreStrategy` 显式门控是否查 cache（见 §4）。
4. **光标延迟修复（`redesigned_text_cursor`）v1 不做**（文档 Task 7 含 `sudo defaults write …`）。
   - 理由：用户明确"只实现核心功能=切换输入法"。该项是系统级、需管理员权限改 `/Library/Preferences/FeatureFlags` 的高风险操作，与"切换输入法"核心无关，收益小、回滚和兼容性风险大。留待后续单独评估。
5. **总开关默认关**（见 §3）；**Package.swift 不改 / v1 不加 test target**（见 §2）；故障排除做成页面分段而非独立 `Troubleshooting.swift` 文件，模块文件数从文档的 11 降到 10。

## 14. 验证清单（手工）

- [ ] 设全局默认输入法，切到无规则 App，自动切到默认。
- [ ] 加一条 App 规则，切到该 App，目标输入法生效。
- [ ] 启用 Chrome/Safari 浏览器规则，配 `domain`，访问对应站点，自动切换。
- [ ] 切 Tab / 改 URL，浏览器规则重新匹配。
- [ ] 地址栏聚焦时切到地址栏默认输入法。
- [ ] CJKV 输入法（中文）切过去后，**实际键入**就是中文（验证 CJKV 修复生效）。
- [ ] 合成「上一个输入法」快捷键时，不误触发手势/切换器/窗口快捷键（暗号生效）。
- [ ] 关总开关 → 不再自动切。
- [ ] 开调试日志 → `input-source-switch.log` 有 context/match/select 记录。
- [ ] 跑 `./scripts/build-app.sh --run`，老配置不解码失败，`/Applications/Velto.app` 被覆盖、新进程起来。

## 15. 完成标准

- 编译通过；`/Applications/Velto.app` 被新包覆盖、新进程已启动。
- 侧边栏可进「输入法切换」。
- App 规则、浏览器规则各至少一次真实切换验证通过。
- CJKV 中文输入法切换后实际键入正确。
- 调试日志可打开并看到切换记录。
