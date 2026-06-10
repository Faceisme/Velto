# 设置界面 Liquid Glass 化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移除设置界面所有装饰性描边,放开盖在玻璃上的不透明底色,呈现真正的 Liquid Glass。

**Architecture:** 核心改动在设计系统层(`VeltoGlassSurface` / `VeltoGlassWindow`),卡片统一变为"约 8% 淡 tint 的玻璃面";侧边栏与手势列表的选中项从实色 accent 改为 accent tint 玻璃;组件层与页面的零散 hairline 逐处删除。录制态虚线高亮、手势轨迹线等功能性线条不动。

**Tech Stack:** SwiftUI `.glassEffect(.regular.tint(_:), in:)`(macOS 26)、AppKit `NSGlassEffectView`(侧边栏,已有)。部署目标 macOS 26,`#available(macOS 26.0, *)` 分支恒真,维持现有结构最小改动。

**约定:** 每个文件的缩进跟随该文件现状(多数 4 空格,InputSourceSwitchPage 为 2 空格)。spec 见 `docs/superpowers/specs/2026-06-10-liquid-glass-settings-design.md`。

---

### Task 1: 失败测试——设置界面不再有装饰性描边

**Files:**
- Create: `Tests/VeltoTests/LiquidGlassStyleTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing

/// 设置界面 Liquid Glass 化:装饰性描边(strokeBorder hairline)已全部移除,
/// 玻璃材质不再被不透明底色盖住。录制态的虚线高亮(RecorderViews /
/// MouseInputRecorderField)是功能性指示,不在此列。
@Test func settingsChromeHasNoDecorativeStrokeBorders() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let chromeFiles = [
    "Sources/Velto/DesignSystem.swift",
    "Sources/Velto/SidebarView.swift",
    "Sources/Velto/Components.swift",
    "Sources/Velto/Gestures/GesturesPage.swift",
    "Sources/Velto/InputSourceSwitch/InputSourceSwitchPage.swift",
    "Sources/Velto/betterfinder/BetterFinderPage.swift",
  ]
  for file in chromeFiles {
    let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
    #expect(!source.contains("strokeBorder"), "\(file) 不应再有装饰性描边")
  }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter settingsChromeHasNoDecorativeStrokeBorders`
Expected: FAIL,6 个文件全部命中 strokeBorder。

### Task 2: 设计系统层(DesignSystem.swift)

**Files:**
- Modify: `Sources/Velto/DesignSystem.swift:77-117`

- [ ] **Step 1: `VeltoGlassSurface.body` 整体替换为**

```swift
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(fill.opacity(0.08)), in: shape)
                .shadow(color: shadow ? Color.mgShadow.opacity(0.08) : .clear, radius: 10, x: 0, y: 4)
        } else {
            content
                .background(fill, in: shape)
                .shadow(color: shadow ? Color.mgShadow.opacity(0.04) : .clear, radius: 3, x: 0, y: 1)
        }
    }
```

- [ ] **Step 2: `VeltoGlassWindow.body` 删除 `.overlay { strokeBorder }`,其余不动**

```swift
        if #available(macOS 26.0, *) {
            content
                .background(Color.mgBg, in: shape)
                .glassEffect(.regular, in: shape)
                .clipShape(shape)
        } else {
```

### Task 3: 侧边栏(SidebarView.swift)

**Files:**
- Modify: `Sources/Velto/SidebarView.swift:187-216`(sidebarItemBackground)、`264-272`(StatusCard)

- [ ] **Step 1: `sidebarItemBackground` 整体替换为**

```swift
    @ViewBuilder
    private var sidebarItemBackground: some View {
        let shape = RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)

        if active {
            Color.clear
                .glassEffect(.regular.tint(Color.mgAccent.opacity(0.85)), in: shape)
        } else {
            SettingsSidebarGlassView(
                cornerRadius: MGRadius.control,
                tintColor: NSColor.windowBackgroundColor.withAlphaComponent(isHovered ? 0.20 : 0.12),
                style: .regular
            )
            .clipShape(shape)
            .opacity(isHovered ? 0.85 : 0.45)
        }
    }
```

- [ ] **Step 2: StatusCard 的 `.background(...)` + `.overlay(...)` + `.shadow(...)` 三段替换为**

```swift
        .veltoGlassSurface(radius: MGRadius.card)
```

### Task 4: 组件层(Components.swift)

**Files:**
- Modify: `Sources/Velto/Components.swift`

- [ ] **Step 1: `Kbd.singleCap`** —— 删除 `borderColor` 变量与 `.overlay(strokeBorder)`;底色改 `Color.mgGlassControl.opacity(0.45)`(inverted 分支不动)。
- [ ] **Step 2: `KeyCapSlot`** —— fill 改 `Color.mgGlassControl.opacity(0.35)`,删 `.overlay(strokeBorder)`。
- [ ] **Step 3: `ActionIcon`** —— fill 改 `Color.mgAccentSoft.opacity(0.35)`,删 `.overlay(strokeBorder)`。
- [ ] **Step 4: `MGSegmentedPicker`** —— 容器 fill 改 `Color.mgCardAlt.opacity(0.35)`,删 `.overlay(strokeBorder)`;选中段实色 accent 芯片不动。
- [ ] **Step 5: `MGSecondaryButtonStyle`** —— fill 改 `Color.mgGlassControl.opacity(0.35)`,删 `.overlay(strokeBorder)`。
- [ ] **Step 6: `MGDestructiveButtonStyle`** —— fill 改 `Color.mgDanger.opacity(0.08)`(淡红底),删红描边 overlay,红字保留。
- [ ] **Step 7: `MGStepperField`** —— fill 改 `Color.mgGlassControl.opacity(0.35)`,删 `.overlay(strokeBorder)`。

### Task 5: 手势列表(GesturesPage.swift)

**Files:**
- Modify: `Sources/Velto/Gestures/GesturesPage.swift:359-370, 431-446`

- [ ] **Step 1: 缩略图盒子** —— 删除 360-370 的 `.overlay(RoundedRectangle().strokeBorder(...))`,保留 fill。
- [ ] **Step 2: 行背景** —— selected 分支改 accent tint 玻璃,unselected 降低底色不透明度:

```swift
            .background(
                Group {
                    if selected {
                        Color.clear
                            .glassEffect(.regular.tint(Color.mgAccent.opacity(0.85)),
                                         in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.mgGlassWeak.opacity(0.3))
                            .veltoNativeGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            )
```

- [ ] **Step 3:** 删除外层 443-446 的 `.overlay(strokeBorder)`。

### Task 6: 零散页面描边

**Files:**
- Modify: `Sources/Velto/InputSourceSwitch/InputSourceSwitchPage.swift:412-416, 457-461`(注意该文件 2 空格缩进)
- Modify: `Sources/Velto/betterfinder/BetterFinderPage.swift:309-316`

- [ ] **Step 1: AppRuleIcon / BrowserIcon** —— fill 改 `Color.mgGlassControl.opacity(0.35)`,删 `.overlay { strokeBorder }`。
- [ ] **Step 2: BetterFinderPage 自定义 App 列表容器** —— fill 改 `Color.mgCardAlt.opacity(0.35)`,补 `.veltoNativeGlass(in: RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous))`,删 `.overlay(strokeBorder)`。

### Task 7: 验证与提交

- [ ] **Step 1:** `swift test` —— 全部通过(含 Task 1 新测试)。
- [ ] **Step 2:** `./scripts/build-app.sh --run` 部署。
- [ ] **Step 3:** 实际打开设置窗口逐页目检:无描边、玻璃透感、选中项为蓝调玻璃、深浅色下文字可读。
- [ ] **Step 4:** 仅提交样式相关文件(工作区还有未提交的 LoginItemManager 修复与用户自己的测试改动,勿混入):

```bash
git add Tests/VeltoTests/LiquidGlassStyleTests.swift \
  Sources/Velto/DesignSystem.swift Sources/Velto/SidebarView.swift \
  Sources/Velto/Components.swift Sources/Velto/Gestures/GesturesPage.swift \
  Sources/Velto/InputSourceSwitch/InputSourceSwitchPage.swift \
  Sources/Velto/betterfinder/BetterFinderPage.swift \
  docs/superpowers/plans/2026-06-10-liquid-glass-settings.md
git commit -m "设置界面去描边并释放 Liquid Glass 质感"
```

### 明确不改

- `RecorderViews.swift` / `MouseInputRecorderField.swift`:描边均在 `if isRecording` 内,录制态功能指示。
- `GestureTrailView.swift` / `GestureCaptureView.swift`:手势轨迹绘制线。
- `SwitcherTileView.swift`:窗口切换器选中高亮,独立 UI。
- `GroupRow` 行间 0.5px 水平分隔线与 `mgHair`/`mgHairStrong` 颜色定义。
- `MGPrimaryButtonStyle` 实色 accent 主按钮(本无描边)。
