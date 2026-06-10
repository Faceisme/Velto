# 设置界面 Liquid Glass 化设计

日期:2026-06-10
状态:已获用户批准

## 背景

设置界面当前是"玻璃被盖住"的状态:`VeltoGlassSurface` 在 `.glassEffect`
之上又铺了不透明 `controlBackgroundColor` 底色,加上各处 0.5pt/1pt 灰描边,
视觉呈现为平面卡片 + 条条框框。用户要求:去掉所有装饰性描边,呈现真正的
Liquid Glass 质感。

## 用户决策

- 侧边栏选中项:accent 色调玻璃(`.glassEffect(.regular.tint(...))`),非实色蓝。
- 卡片透明度:保留约 8% 的淡底色 tint + 玻璃,不做全透(可读性优先)。

## 改动范围

### 设计系统层(全局生效)— Sources/Velto/DesignSystem.swift

- `VeltoGlassSurface`:删除 strokeBorder;不透明 fill 改为 `fill.opacity(0.08)`
  级别的淡 tint;保留柔和阴影。
- `VeltoGlassWindow`:删除窗口描边。
- `mgHair` / `mgHairStrong` 颜色定义保留(分隔线仍在用)。

### 侧边栏 — Sources/Velto/SidebarView.swift

- 选中项:实色 accent fill + 白描边 + 阴影 → accent tint 玻璃,白字保留。
- 未选中/hover:保留 `NSGlassEffectView`,删除白色 fill 叠层与白描边,
  hover 反馈只靠玻璃 tint 深浅。
- `StatusCard`:实色底 + 描边 → 统一走 `veltoGlassSurface`。

### 组件层与页面

- Components.swift:按钮/控件/键帽上的 mgHair、mgHairStrong 描边全部删除,
  底面统一玻璃;危险按钮删红描边、保留红字与淡红底。
- InputSourceSwitchPage.swift(415、460)、GesturesPage.swift(445)、
  BetterFinderPage.swift(315):装饰性 hairline 删除。

### 明确不动(功能性线条)

- GestureTrailView / GestureCaptureView 的轨迹绘制线。
- RecorderViews / MouseInputRecorderField 录制进行中的 accent 高亮框。
- SwitcherTileView(窗口切换器)选中高亮 —— 独立 UI,本来就是纯玻璃。
- GroupRow 行间水平分隔线。
- GesturesPage 366 行的选中态描边若为功能性选中指示则保留,实施时确认。

## 验证

1. `swift test` 全绿。
2. `./scripts/build-app.sh --run` 部署后实际打开设置窗口逐页检查:
   无装饰描边、玻璃透感正常、深浅色外观下文字可读。
