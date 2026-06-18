# 截图功能 · 标注编辑器设计文档

**日期：** 2026-06-18
**状态：** 已批准，待实现
**阶段：** Phase 2 / 3（标注编辑器）
**上游：** `docs/superpowers/specs/2026-06-17-screenshot-core-capture-design.md`

---

## 1. 背景与目标

截图核心捕获已经跑通全局快捷键、冻结快照、区域框选、窗口识别、复制与保存。Phase 2 在同一个截图覆盖窗口内加入可编辑标注层，不打开独立编辑窗口。

本阶段交付以下完整工具：

1. 矩形
2. 椭圆
3. 直线
4. 箭头
5. 画笔
6. 马赛克
7. 文字
8. 高亮
9. 序号
10. 裁剪

所有标注对象在输出前都可再次选择、移动、缩放、修改样式、删除、撤销和重做。最终输出继续复用 Phase 1 的剪贴板与 PNG 保存闭环。

滚动长截图仍属于 Phase 3，不在本文档范围。

### 平台约束

- 仅支持 macOS 26+，直接使用最新 AppKit、Core Graphics 与 `NSGlassEffectView` API。
- 不增加老版本兼容分支。
- 标注 UI 必须位于现有 `ScreenshotOverlayWindow` 内，不能跳转到独立编辑窗口。
- 不改变 Phase 1 的屏幕录制权限、冻结快照和单屏选区约束。

---

## 2. 已确认的关键决策

| 决策点 | 选择 |
|---|---|
| 编辑位置 | 原截图覆盖层内直接标注 |
| 编辑模型 | 可编辑对象模型，不把操作立即烘焙到底图 |
| 渲染架构 | AppKit 对象模型 + Core Graphics 统一渲染 |
| 预览与导出 | 共用同一个 `AnnotationRenderer` |
| 工具栏 | 参考 Xnip 的底部单行主工具栏 + 下方属性条 |
| 材质与颜色 | Velto Liquid Glass、系统强调色与系统语义色 |
| 图标 | 全部自绘矢量路径，不混用 Unicode 或来源不同的系统图标 |
| Shift 直线辅助 | 拖拽过程中实时吸附到最近的 45° 方向并带切换滞回 |
| Shift 图形辅助 | 矩形、椭圆和裁剪锁定 1:1 |
| 马赛克 | 首版为可编辑矩形像素化区域，不做自由笔刷马赛克 |
| 裁剪 | 只修改最终输出区域，不缩放或改写标注对象 |
| 默认完成动作 | 合成后复制到剪贴板并结束会话 |

---

## 3. 会话状态机

```text
Idle
  └─ 全局快捷键 → Capturing
                       └─ 快照完成 → Selecting
                                         └─ 框选 / 选窗 → Selected
                                                               ├─ 选择工具 → Annotating
                                                               │              ├─ 新增/编辑对象
                                                               │              ├─ 撤销/重做
                                                               │              └─ 返回 Selected
                                                               ├─ 裁剪 → Cropping
                                                               ├─ 复制/完成 → Rendering → Clipboard → Idle
                                                               ├─ 保存 → Rendering → File → Idle
                                                               └─ 取消 → Idle
```

- `Selecting`：保留 Phase 1 的框选、窗口识别、选区移动和八手柄缩放。
- `Selected`：选区形成后显示工具栏，但不默认激活绘图工具，避免只想复制时误画。
- `Annotating`：鼠标事件进入标注画布；标注对象保持可编辑。
- `Cropping`：只调整 `AnnotationDocument.cropRect`。
- `Rendering`：冻结文档快照，统一合成预览模型与底图。

一次会话只能有一个活动选区。多屏场景下，选区第一次形成后锁定当前覆盖窗口；其他屏幕继续显示冻结画面，但不允许建立第二个选区。

---

## 4. 模块与文件边界

新增目录：

```text
Sources/Velto/Screenshot/Annotation/
├── AnnotationTool.swift               # 工具枚举、工具能力与属性条配置
├── AnnotationStyle.swift              # 颜色、线宽、填充、字号、透明度、像素粒度
├── AnnotationElement.swift            # 全部可编辑对象的值模型
├── AnnotationDocument.swift           # 画布、对象层级、选择、裁剪与序号状态
├── AnnotationHistory.swift            # 最多 100 步、按完整手势合并的撤销/重做
├── AnnotationGeometry.swift           # 命中、控制点、缩放、约束与 Shift 角度吸附
├── AnnotationRenderer.swift           # 预览与最终导出的统一 Core Graphics 渲染器
├── AnnotationCanvasView.swift         # 选区内事件、对象选择与局部重绘
├── AnnotationToolbarView.swift        # NSGlassEffectView 主工具栏
├── AnnotationPropertyBarView.swift    # 随工具变化的属性条
├── AnnotationIconLibrary.swift        # 统一 24×24 自绘 CGPath 图标
├── AnnotationTextEditor.swift         # NSTextView 原位文字编辑
└── AnnotationMosaicRenderer.swift     # 原始截图矩形像素化与缓存
```

修改现有文件：

| 文件 | 改动 |
|---|---|
| `ScreenshotOverlayView.swift` | 保留选区职责；选区形成后挂载标注画布、工具栏和属性条 |
| `ScreenshotOverlayWindow.swift` | 扩展 delegate，使会话能接收活动选区、文档与输出动作 |
| `ScreenshotSession.swift` | 管理唯一活动覆盖窗口；输出时调用统一渲染器 |
| `ScreenshotPreferences.swift` | 增加标注默认值与最近使用样式 |
| `ScreenshotPage.swift` | 增加标注默认样式设置，不改变已有截图设置结构 |
| `ScreenshotImageWriter.swift` | 输出改为可报告失败的结果，失败时保留会话 |

`ScreenshotOverlayView` 不继续承载具体标注工具实现。它只负责 Phase 1 选择交互、子视图生命周期和坐标桥接。

---

## 5. 对象模型

`AnnotationDocument` 保存：

```swift
struct AnnotationDocument {
  var canvasSize: CGSize
  var cropRect: CGRect
  var elements: [AnnotationElement]
  var selectedElementID: UUID?
  var activeTool: AnnotationTool?
  var nextSequenceNumber: Int
}
```

所有几何数据使用选区内的 AppKit 点坐标，原点为选区左下角。Retina 倍率只在渲染边界处理，不进入对象模型。

`AnnotationElement` 使用值语义枚举承载具体对象：

```swift
enum AnnotationElement {
  case rectangle(RectangleAnnotation)
  case ellipse(EllipseAnnotation)
  case line(LineAnnotation)
  case arrow(ArrowAnnotation)
  case freehand(FreehandAnnotation)
  case mosaic(MosaicAnnotation)
  case text(TextAnnotation)
  case highlight(HighlightAnnotation)
  case sequence(SequenceAnnotation)
}
```

每个对象包含稳定 `UUID`、几何数据和对应样式。`elements` 数组顺序就是矢量对象的绘制层级。

马赛克是特殊背景效果：无论创建顺序如何，都只采样和像素化原始截图，渲染在全部矢量标注下方，避免箭头、文字和序号被马赛克破坏。

---

## 6. 坐标与输出管线

1. Phase 1 选区仍使用覆盖窗口左下原点点坐标。
2. 建立文档时，把选区左下角映射为标注画布 `(0, 0)`。
3. 标注对象只存点坐标；预览直接绘制到选区大小的 `AnnotationCanvasView`。
4. 输出时先从原始 `DisplaySnapshot` 裁出选区底图。
5. `AnnotationRenderer` 按 backing scale 把对象转换到像素坐标。
6. 先应用马赛克背景效果，再按 `elements` 顺序绘制矢量标注。
7. 最后应用 `cropRect`，交给剪贴板或 PNG writer。

预览和最终输出必须调用同一套对象路径生成与样式解析逻辑。预览允许使用当前屏幕 scale，导出使用原始快照 scale，但不能出现路径形状、文字位置或马赛克区域差异。

色彩空间优先沿用原始快照的 `CGColorSpace`；无法取得时使用设备 RGB。PNG 编码不得主动降采样。

---

## 7. 工具栏与图标规范

主工具栏顺序固定为：

```text
矩形 → 椭圆 → 直线 → 箭头 → 画笔 → 马赛克 → 文字 → 高亮 → 序号 → 裁剪
| 撤销 → 重做
| 取消 → 保存 → 复制 → 完成
```

### 几何标准

- 主工具栏高度：`54pt`。
- 工具栏材质：`NSGlassEffectView.style = .regular`。
- 按钮：`36×36pt`，相邻间距 `2pt`。
- 图标画布：`24×24pt`。
- 图标可见路径：归一到统一光学边界，目标不超过 `18×18pt`。
- 图标笔画：`2pt`，`round` line cap，`round` line join。
- 分隔线：`1×24pt`，分组外边距 `4pt`。
- Hover、按下、禁用状态不缩放按钮或图标。

所有图标由 `AnnotationIconLibrary` 返回自绘 `CGPath`。不得用 Unicode 字符充当图标，也不得混用尺寸和笔画不可控的符号。

### 颜色

- 普通图标：`NSColor.labelColor`。
- 当前工具：背景 `NSColor.controlAccentColor`，图标白色。
- 取消：`NSColor.systemRed`。
- 完成：Velto `mgGreen` 对应的 AppKit 颜色。
- 禁用：`NSColor.disabledControlTextColor`。
- 工具栏与属性条使用系统 Liquid Glass，不能硬编码不随系统外观变化的白色底板。

### 定位

- 主工具栏默认位于选区下方，与选区间隔 `10pt`。
- 属性条位于主工具栏下方，间隔 `6pt`。
- 底部空间不足时，主工具栏与属性条作为整体翻到选区上方。
- 左右越界时整体夹回活动屏幕可见区域，不压缩按钮或改变间距。

---

## 8. 属性条

属性条根据当前工具动态显示：

| 工具 | 属性 |
|---|---|
| 矩形 / 椭圆 | 描边颜色、线宽、填充颜色、填充透明度 |
| 直线 / 箭头 | 颜色、线宽 |
| 画笔 | 颜色、线宽 |
| 马赛克 | 像素块粒度 |
| 文字 | 颜色、字号、粗体、左/中/右对齐 |
| 高亮 | 颜色、宽度、透明度 |
| 序号 | 前景色、背景色、尺寸 |
| 裁剪 | 当前宽高，只读显示 |

默认调色板：系统红、系统强调色、系统绿、系统橙、系统紫、黑、白。颜色最终以解析后的 RGBA 保存到文档，确保导出不受会话结束后的系统动态色变化影响。

---

## 9. 各工具交互

### 9.1 矩形与椭圆

- 拖拽创建，默认透明填充。
- 按住 `Shift` 时锁定为正方形或正圆。
- 按住 `Option` 时以起点为中心向外扩展。
- `Shift + Option` 可同时生效。
- 创建后显示八个缩放控制点。

### 9.2 直线与箭头

- 起点在 `mouseDown` 固定，终点随拖拽更新。
- 不按 `Shift` 时完全跟随光标。
- 按住 `Shift` 时实时吸附到八个方向：`0°/45°/90°/135°/180°/225°/270°/315°`。
- 保留当前拖拽半径，只量化方向。
- 横线输出点的 Y 必须严格等于起点 Y；竖线输出点的 X 必须严格等于起点 X。
- 箭头头部随线宽等比例变化，但保持统一视觉比例。

### 9.3 Shift 方向吸附算法

```text
delta = cursor - anchor
radius = hypot(delta.x, delta.y)
rawAngle = atan2(delta.y, delta.x)
candidate = round(rawAngle / 45°) × 45°
snappedEnd = anchor + radius × (cos(candidate), sin(candidate))
```

为避免光标在两个扇区临界线附近抖动：

- 首次按下 `Shift` 时立即选择最近方向。
- 当前方向保持到原始角度越过扇区中线后额外 `4°`。
- 越过滞回边界后切到新的最近方向。
- 松开 `Shift` 后立即恢复原始光标位置，不保留吸附状态。

### 9.4 画笔

- 收集拖拽采样点并进行曲线平滑，不能直接以折线连接所有原始事件点。
- 最短采样距离用于去除高频重复点。
- 对象保存平滑前的必要控制点，渲染器生成一致曲线。

### 9.5 文字

- 单击创建原位 `NSTextView`；输入结束后转换为 `TextAnnotation`。
- 双击已有文字重新进入原位编辑。
- 空文字退出编辑时不创建对象。
- 支持字号、颜色、粗体和左/中/右对齐。
- 文字框可移动和调整宽度，高度按排版结果自动计算。

### 9.6 高亮

- 使用带圆头的宽半透明笔画。
- 默认透明度 `35%`。
- 路径平滑规则与画笔一致，但保持独立宽度和透明度设置。

### 9.7 马赛克

- 拖拽创建矩形像素化区域。
- 默认粒度 `12px`，属性条可调整。
- 马赛克对象只引用区域和粒度，不复制整张底图。
- 预览缓存按区域与粒度失效，避免每次鼠标移动重新像素化整张截图。

### 9.8 序号

- 每次创建使用 `nextSequenceNumber`，初始为 1。
- 删除已有序号不会自动重排其他对象，避免说明语义改变。
- 新对象继续递增。
- 序号对象可移动和缩放。

### 9.9 裁剪

- 初始 `cropRect` 等于完整选区。
- 裁剪控制点只改变 `cropRect`，不改变对象坐标与尺寸。
- 按住 `Shift` 锁定 1:1。
- 最小裁剪区域 `16×16pt`。
- 裁剪外对象保留在文档中；撤销或扩大裁剪后重新出现。

---

## 10. 对象选择与编辑

- 新对象创建完成后保持选中。
- 单击已有对象可重新选择，不要求增加额外选择工具图标。
- 命中检测从最上层对象向下进行。
- 线条命中容差至少为 `max(6pt, lineWidth / 2 + 4pt)`。
- 控制点保持固定屏幕尺寸，不随对象缩放。
- 拖动对象主体移动；拖动控制点缩放。
- 直线和箭头显示起点、终点两个控制点。
- `Delete` / `Forward Delete` 删除当前对象。
- 方向键移动 `1pt`；`Shift + 方向键` 移动 `10pt`。
- 点击空白区域取消对象选择；当前绘图工具仍保持激活，可继续创建同类对象。

任意对象编辑都必须被限制在文档画布坐标中；允许对象部分位于裁剪区域外，但不能产生无穷值、负尺寸或不可逆几何状态。

---

## 11. 撤销与重做

`AnnotationHistory` 最多保留 100 步。

- 新增、删除、一次完整移动、一次完整缩放、一次样式修改、一次文字编辑、一次裁剪分别形成一条历史记录。
- `mouseDragged` 期间只更新临时预览；`mouseUp` 时合并为单条命令。
- 没有实际变化的操作不入历史。
- 新操作发生后清空 redo 栈。
- `⌘Z` 撤销，`⌘⇧Z` 重做。
- 工具栏按钮的 enabled 状态与 history 栈同步。

---

## 12. 键盘与结束动作

| 输入 | 行为 |
|---|---|
| `Shift` | 拖拽时方向吸附；矩形、椭圆、裁剪锁定 1:1 |
| `Option` | 矩形、椭圆从中心绘制 |
| `⌘Z` | 撤销 |
| `⌘⇧Z` | 重做 |
| `Delete` | 删除当前对象 |
| 方向键 | 移动 1pt |
| `Shift + 方向键` | 移动 10pt |
| 空格 | 合成并复制，结束会话 |
| `Enter` | 默认完成动作：合成并复制，结束会话 |
| `⌘S` | 合成并静默保存，结束会话 |
| 右键 | 与分层 `Esc` 一致 |

`Esc` / 右键按以下顺序消费：

1. 正在编辑文字：结束文字编辑。
2. 正在拖拽变换：取消本次变换，恢复变换前状态。
3. 有选中对象：取消选择。
4. 有活动绘图工具：退出工具，回到 `Selected`。
5. 无局部状态可取消：取消整个截图会话。

工具栏动作：

- 红色取消：不输出，结束会话。
- 保存：等同 `⌘S`。
- 复制：等同空格。
- 绿色完成：等同 `Enter`，默认合成并复制。

---

## 13. 配置

在 `ScreenshotPreferences` 中增加：

```swift
var annotationColor: AnnotationColor          // 默认 systemRed 解析值
var annotationLineWidth: CGFloat              // 默认 3pt
var annotationFontSize: CGFloat               // 默认 18pt
var annotationHighlightOpacity: CGFloat       // 默认 0.35
var annotationMosaicBlockSize: Int             // 默认 12px
var annotationFillOpacity: CGFloat             // 默认 0
```

- 使用 `decodeIfPresent` 回退默认值，兼容旧配置。
- 最近使用的颜色、线宽、字号、透明度和马赛克粒度跨会话保留。
- 活动工具和对象历史不持久化；每次新截图从无活动工具开始。

---

## 14. 性能策略

Phase 1 已验证全屏快照在每次鼠标移动中重绘会造成卡顿，也验证过使用透明 `clear` 挖洞会导致窗口点击穿透。因此 Phase 2 遵守以下限制：

- 不改回透明挖洞或会透传事件的窗口结构。
- 父 `ScreenshotOverlayView` 继续使用已验证的单次快照绘制 + even-odd 暗罩。
- 选区稳定后，父视图不随标注鼠标移动反复置为全屏脏区。
- `AnnotationCanvasView` 只覆盖选区并刷新局部脏矩形。
- 标注子视图不调用 `CGContext.clear` 修改窗口最终 alpha。
- 马赛克按区域和粒度缓存。
- 画笔采样做最小距离过滤，避免单次笔画产生无界点数。
- 工具栏和属性条使用独立 `NSGlassEffectView`，不参与快照重绘。

---

## 15. 错误处理

| 情况 | 处理 |
|---|---|
| 图形或线条尺寸小于 2pt | 丢弃，不写入历史 |
| 文字为空 | 结束编辑时删除临时对象 |
| 裁剪小于 16×16pt | 夹到最小尺寸 |
| 马赛克采样失败 | 记录日志，保留对象边界并继续会话 |
| 合成失败 | 日志 + 轻提示，保留会话和全部对象供重试 |
| 保存失败 | 不结束会话；提示失败并允许重新选择目录或复制 |
| 工具栏空间不足 | 整组翻转或夹回当前屏幕可见区域 |
| 会话外部取消 | 结束文字编辑并释放画布、缓存、工具栏和 history |

输出 API 需要返回成功或失败结果，不能在失败时无条件 teardown 导致用户丢失标注。

---

## 16. 测试与验证

测试代码遵守仓库约定：照写照跑，但不加入最终提交。

### 纯逻辑测试

- 八方向角度吸附。
- 水平线 Y 精确锁定、竖直线 X 精确锁定。
- 22.5° 扇区边界与额外 4° 滞回。
- 松开 `Shift` 立即恢复自由端点。
- `Shift` 约束矩形、椭圆和裁剪 1:1。
- `Option` 中心绘制与 `Shift + Option` 组合。
- 对象命中顺序、线宽容差、控制点缩放。
- 方向键 1pt / 10pt 移动。
- 撤销手势合并、redo 清空、100 步上限。
- 序号递增与删除后不重排。
- 裁剪不修改对象坐标。

### 渲染测试

- 每种 `AnnotationElement` 的固定输入渲染。
- 马赛克只影响底图，不影响矢量标注。
- 预览与导出使用相同路径和样式解析。
- Retina 1x/2x 下位置和线宽一致。
- crop 后像素尺寸正确。

### 图标几何测试

逐个验证 16 个按钮：

- 按钮为 `36×36pt`。
- 图标画布为 `24×24pt`。
- 图标中心与按钮中心均为 `(18, 18)`。
- 可见路径落在统一光学边界内。
- 笔画为 `2pt`，端点与连接均为 round。
- 取消、保存、复制、完成不允许使用不同字号或字体字形。

### 实机验证

- 全部工具创建、选择、移动、缩放、改样式、删除。
- 文字创建、双击编辑和焦点切换。
- `Shift` 横线、竖线与斜线吸附无抖动。
- 多屏与不同 Retina scale。
- 工具栏上下翻转和左右夹回。
- 连续画笔、连续马赛克和 100 个对象时交互流畅。
- 空格复制、`⌘S` 保存、取消与完成。
- 合成失败或保存失败时会话不丢失。

---

## 17. 验收标准

1. 原覆盖层内完成全部标注，不打开独立编辑窗口。
2. 十种工具均可用，标注对象可再次编辑。
3. `Shift` 能实时画出严格水平、垂直和 45° 斜线，并在临界角保持稳定。
4. 工具栏排版与已确认视觉稿一致，16 个按钮和自绘图标通过几何校验。
5. 撤销/重做覆盖全部可见编辑操作。
6. 预览与复制/保存结果一致，Retina 输出清晰。
7. 标注过程中不重新引入全屏重绘卡顿或透明区域点击穿透。
8. 输出失败不会丢失当前标注。
9. Release 构建成功后，结束旧进程、覆盖 `/Applications/Velto.app` 并启动新包完成实机验收。

---

## 18. 不在本阶段范围

- Phase 3 滚动长截图与逐帧拼接。
- 跨屏选区或跨屏标注画布。
- 自由笔刷马赛克。
- 任意角度旋转矩形、椭圆、文字或马赛克。
- 图层面板、手动前移/后移层级。
- 自定义字体家族、富文本或文字阴影。
- 标注工程文件持久化与重新打开。
