# 按键映射功能设计文档

**日期：** 2026-06-17  
**状态：** 已批准，待实现

---

## 1. 背景与目标

在 Velto 中加入按键映射功能，对标 Karabiner-Elements 的 Simple Modifications + Complex Modifications（basic type）的子集。

用户可以：
- 导入来自 [ke-complex-modifications.pqrs.org](https://ke-complex-modifications.pqrs.org/) 的社区 JSON 规则文件
- 在 Velto 内直接执行按键重映射，无需安装 Karabiner

---

## 2. 支持范围（方案 B）

### 支持（Mode A + Mode B）

**Mode A：单键替换（含修饰键）**
- `caps_lock → f19`
- `caps_lock → hyper（⌘⌃⌥⇧，即 left_shift + left_command + left_control + left_option）`
- `left_option → left_command`
- 禁用某键（vk_none）

**Mode B：组合键触发**
- `right_command + h/j/k/l → 方向键`
- `right_command + i/j/k/l → 方向键`（任意修饰键 + 任意普通键的组合）

技术实现对标 Karabiner-Elements 的 basic manipulator 逻辑：
- `from.modifiers.optional = ["any"]`（透明修饰键）始终默认生效
- `from.modifiers.mandatory` 对应 Mode B 的"必须同时按住"语义

### 不支持（Mode C，后续可扩展）
- tap vs hold（`to_if_alone` / `to_if_held_down`）
- 条件（`conditions`：前台 App、设备等）
- 变量（`set_variable` / `to_if_set`）
- `type` 非 `basic` 的 manipulator

---

## 3. 架构

### 新增文件

```
Sources/Velto/KeyRemap/
├── KeyRemapModels.swift       # 数据结构（Codable，对标 Karabiner JSON schema）
├── KeyRemapController.swift   # 执行引擎（Tap 线程，对标 simple_modifications_manipulator_manager）
├── KeyRemapStore.swift        # 持久化单例（主线程，模式同 GestureStore）
├── KarabinerJSONParser.swift  # 导入转换：Karabiner JSON → 内部模型
├── KeyCodeMap.swift           # Karabiner key_code 字符串 → CGKeyCode 映射表
└── KeyRemapPage.swift         # SwiftUI 设置页
```

### 改动现有文件

| 文件 | 改动 |
|------|------|
| `EventTapManager.swift` | 持有 `KeyRemapController`；在 `flagsChanged` / `keyDown` / `keyUp` 分支最先处理重映射 |
| `SettingsRootView.swift` | 加 `MGPage.keyRemap`，路由到 `KeyRemapPage` |

### 数据流

```
用户点击"导入 JSON 规则文件"
    → 文件选择器（.json）
    → KarabinerJSONParser.parse()
        → 提取 type=="basic" 的 manipulator
        → 跳过不支持的类型，计数后提示
        → key_code 字符串经 KeyCodeMap 转为 CGKeyCode
    → KeyRemapStore.add(rules:)
        → UserDefaults 持久化（key: "Velto.keyRemaps"）
        → NotificationCenter 广播 .keyRemapStoreDidChange
    → EventTapManager 收到通知
        → performOnTapThread { keyRemapController.update(rules:) }
        → 重建查找表（[from keyCode: manipulator]）
```

---

## 4. 执行引擎

`KeyRemapController` 运行在 EventTap 专用线程，持有两张查找表：

```
normalKeyTable:   [UInt16 → [CompiledManipulator]]   // 普通键 keyDown/keyUp
modifierKeyTable: [UInt16 → [CompiledManipulator]]   // 修饰键 flagsChanged
```

`CompiledManipulator` 是从 `KeyRemapManipulator` 预编译的结构体，存 CGEventFlags mask，避免热路径枚举转换。

### Mode A 执行：`caps_lock → f19`

```
flagsChanged 事件到达：
  1. 检查 modifierKeyTable[caps_lock keyCode]
  2. 匹配到规则：suppress 原事件（return nil）
  3. caps_lock 状态变为 ON  → synthesize f19 keyDown
     caps_lock 状态变为 OFF → synthesize f19 keyUp
  4. 合成事件打 syntheticEventMarker，防止递归触发
```

### Mode A 执行：`caps_lock → hyper`

```
flagsChanged 事件（caps_lock ON）：
  → suppress 原事件
  → post flagsChanged：flags = maskCommand | maskControl | maskAlternate | maskShift
  → 记录 capsHyperActive = true

flagsChanged 事件（caps_lock OFF）：
  → suppress 原事件
  → post flagsChanged：flags 清除上述位
  → capsHyperActive = false
```

### Mode B 执行：`right_command + h → left_arrow`

```
flagsChanged（right_command 按下）：
  → normalKeyTable 里有用到 right_command 作 mandatory 的规则
  → suppress 原事件，suppressedModifiers.insert(rightCommand)
  → 内部标记 rightCommandHeld = true

keyDown（h，且 rightCommandHeld）：
  → normalKeyTable[h] 匹配到规则（mandatory = {rightCommand}）
  → suppress 原 keyDown
  → synthesize left_arrow keyDown（flags 清除 rightCommand）
  → activeRemaps[h] = left_arrow

keyUp（h）：
  → activeRemaps[h] 存在
  → suppress 原 keyUp
  → synthesize left_arrow keyUp
  → activeRemaps.remove(h)

flagsChanged（right_command 松开）：
  → suppressedModifiers.remove(rightCommand)
  → suppress 原事件（modifier 已被"消费"）
  → rightCommandHeld = false
```

### 合成事件标记

复用 `ShortcutSynthesizer.syntheticEventMarker`（`0x4D47534B4559`），所有 KeyRemapController 合成的事件都打此标记，EventTapManager 开头检查到后直接透传，防止递归。

---

## 5. Karabiner JSON 导入

### 输入格式（complex_modifications JSON）

```json
{
  "title": "Vim arrow keys",
  "rules": [
    {
      "description": "right_command + hjkl to arrow keys",
      "manipulators": [
        {
          "type": "basic",
          "from": {
            "key_code": "h",
            "modifiers": {
              "mandatory": ["right_command"],
              "optional": ["any"]
            }
          },
          "to": [{ "key_code": "left_arrow" }]
        }
      ]
    }
  ]
}
```

### 解析策略

- 只处理 `type == "basic"` 的 manipulator
- `from.modifiers.optional = ["any"]`：直接忽略（默认行为）
- `to_if_alone` / `to_if_held_down`：检测到则跳过该 manipulator，计入 skippedCount
- `conditions` 字段：跳过整条 manipulator，计入 skippedCount
- 解析完成后，UI 提示：「导入 N 条规则，跳过 M 条（包含不支持的功能）」

### KeyCodeMap 覆盖范围

- 修饰键：caps_lock、left/right control/shift/option/command、fn
- 字母键：a–z（26 个）
- 数字键：0–9
- 功能键：f1–f20
- 方向键：left_arrow / right_arrow / up_arrow / down_arrow
- 导航键：home / end / page_up / page_down / delete_forward
- 常用符号：space、return、tab、escape、等号、减号、括号等
- 媒体键：volume_up / volume_down / mute、brightness_up / brightness_down

---

## 6. 持久化

- 存储 key：`"Velto.keyRemaps"`（UserDefaults）
- 格式：`[KeyRemapRule]` JSON，与 `"Velto.gestures"` 平级
- 新字段 `decodeIfPresent` + 默认空数组，旧配置无缝兼容

---

## 7. UI 结构（KeyRemapPage）

```
页面标题：按键映射
副标题：导入 Karabiner 社区规则文件，实现按键重映射

[导入 JSON 规则文件]  ← 文件选择器，接受 .json

─── 已导入规则列表 ───────────────────────────────

┌─ caps_lock → Hyper Key ─────────────────────┐
│  [toggle: 启用]                  [删除]       │
│  caps_lock → ⌘⌃⌥⇧                          │
└──────────────────────────────────────────────┘

┌─ Vim 方向键 ────────────────────────────────┐
│  [toggle: 启用]                  [删除]       │
│  right_cmd + h → ←                          │
│  right_cmd + j → ↓                          │
│  right_cmd + k → ↑                          │
│  right_cmd + l → →                          │
└──────────────────────────────────────────────┘
```

规则卡片样式对齐现有 Velto 设计系统（`GroupCard` 组件）。

---

## 8. EventTapManager 集成

```swift
// handle() 的 flagsChanged 分支最开头加：
if keyRemapController.handleFlagsChanged(event: event) { return nil }

// keyDown 分支，紧接合成事件检查之后加：
if keyRemapController.handleKeyDown(event: event) { return nil }

// keyUp 分支，紧接合成事件检查之后加：
if keyRemapController.handleKeyUp(event: event) { return nil }
```

`applyPreferenceSnapshots` 里不改（KeyRemap 有自己的 store observer），`EventTapManager.init` 里额外订阅 `.keyRemapStoreDidChange`，收到后 `performOnTapThread` 更新控制器。

---

## 9. 扩展性预留

- `KeyRemapManipulator` 字段预留 `toIfAlone` / `toIfHeldDown`（可选，默认 nil）
- `KarabinerJSONParser` 检测到这些字段时跳过，但不丢数据（存入模型后静默不执行）
- 后续加 Mode C 时：在 `KeyRemapController` 加定时器状态机，模型字段已就位

---

## 10. 不在此次范围内

- 手动在 UI 里 Add item（文字下拉选 from/to）—— 可后续加
- 按设备过滤规则（Karabiner 的 device condition）
- 规则导出
- 规则执行顺序调整（拖拽排序）
