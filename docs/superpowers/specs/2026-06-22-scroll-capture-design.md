# 滚动长截图(Scroll Capture)设计

日期:2026-06-22
状态:已确认,待实现

## 背景与范围

截图模块(Phase 1/2)已完成区域选择、窗口识别、标注编辑、复制/保存闭环。滚动长截图原属 Phase 3,
此前仅在会话内留有占位:按滚动键 `S` → `overlayDidRequest(.scroll)` → 打日志 + 蜂鸣,不做任何拼接。

本设计实现 **v1 滚动长截图**:用户**手动滚动**目标 App,Velto 实时抓取选区帧、按帧间重叠**自动拼接**成
一张长图,完成后直接**复制或保存**(跳过标注)。

参考 CleanShot X 的可观察行为后确认两点:
- CleanShot 主推**自动滚动**,但公开评价"有点反直觉、要调";其**手动滚动**变体更通用稳健。v1 取**手动**。
- 连 CleanShot 都未解决"固定头部随帧重复"问题(用户实测吐槽)。v1 因此**不做固定头部裁除**,靠用户框选避开。

### 平台约束

- 仅支持 macOS 26+,沿用 Phase 1 的 ScreenCaptureKit(`SCScreenshotManager`)与屏幕录制权限。
- 复用现有 `ScreenshotOverlayWindow` / `ScreenshotSession` / `ScreenshotImageWriter`,不引入独立编辑窗口。
- 不改变冻结快照、单屏选区、坐标模型(NSScreen 左下原点 ↔ CGWindowList 左上原点)等既有约束。

### 非目标(YAGNI,留作后续迭代)

- 自动滚动(Velto 模拟滚轮驱动目标 App)。
- 固定头部/底部/悬浮栏自动识别与裁除。
- 横向滚动、向上滚动拼接。
- 滚动长图进入标注编辑器(v1 完成后直接复制/保存)。
- 分页打印、长图再编辑。

## 交互流程与状态机

进入条件:**已有有效选区且选区已激活**(即普通框选完成那一刻的状态)。选区应由用户**避开滚动条与固定头部**。

```
[选区已激活]
   │ 按滚动键 S(ScreenshotPreferences.scrollKeyCode)
   ▼
[滚动捕获中] ── Enter / 空格 ──▶ 定稿 → 复制到剪贴板 → teardown
   │  ├─ ⌘S ─────────────────▶ 定稿 → 保存到预设目录 → teardown
   │  └─ Esc ────────────────▶ 丢弃长图 → 回到 [选区已激活]
   │
   │ 进入时:活动屏 overlay 置 ignoresMouseEvents = true(滚轮直达光标下目标 App);
   │         弹出 ScrollCaptureHUD(key 窗口,接键盘);起 ~10fps 定时器。
   ▼
 每拍:抓选区帧 → 行指纹 → 与画布尾比对 → 追加新行 → 刷新 HUD 缩略与高度。
```

- **不压暗整屏**:进入滚动模式后,活动屏 overlay 透传鼠标、停止绘制选区 chrome;用户看到真实目标 App。
- **HUD**:屏幕一角的小浮窗(`level = .screenSaver`,`canJoinAllSpaces`),显示:
  - 当前长图缩略预览(随拼接增长,等比缩放)、当前像素高度;
  - 提示文案:"向下滚动目标窗口(滚慢一点) · Enter/空格 完成 · ⌘S 保存 · Esc 取消";
  - 滚太快/对不上时,提示行临时变为"滚慢一点,刚才那段没接上"。
  - HUD 是 key 窗口接键盘;滚轮事件落在**光标下的窗口**(与 key 焦点无关),两者不冲突。
- **键位**:`Enter`(36)/`空格`(`copyKeyCode`,默认 49)= 完成并复制;`⌘S`(`saveShortcut`)= 完成并保存;
  `Esc`(`cancelKeyCode`,默认 53)= 取消滚动、回到选区(长图丢弃,选区保留可重来)。

## 捕获机制(M1:定时抓取)

- 进入滚动模式后起 `DispatchSourceTimer`(主队列,间隔 ~100ms ≈ 10fps)。
- 每拍调用 `ScreenshotCapturer.captureRegion(globalRect:)`:用 `SCScreenshotManager.captureImage` +
  `SCStreamConfiguration.sourceRect`(或抓整屏后裁)只取选区像素,`showsCursor = false`,按 `scale` 输出像素图。
- 抓帧为 async;用串行化保证同一时刻只有一帧在飞,避免乱序(到帧后再调度下一拍)。
- 选区为全局点 rect(`currentSelectionGlobal`),换算同现有 `crop`。

不选 M2(SCStream 实时流):生命周期/背压/CMSampleBuffer 复杂度对 v1 过重。

## 拼接算法

### 行指纹(AppKit 侧)

`ScrollStitcher` 把每帧 `CGImage` 转成逐行指纹 `[UInt64]`:
- 每行在宽度上等距取 N 个采样点(如 N=32),每点取亮度/RGB 量化到若干位,拼成 `UInt64` 哈希。
- 降采样 + 量化使指纹对抗锯齿/亚像素渲染的微小帧间差异具一定鲁棒性。

### 重叠检测(纯逻辑,`VeltoAnnotationCore`,重点单测)

`ScrollOverlapDetector`:

```
/// 竖直向下滚动:新帧顶部与已拼画布底部重叠。返回应追加的新行数;无可信重叠返回 nil。
static func appendableRowCount(
  canvasTail: [UInt64],   // 画布底部最后若干行的指纹(取 min(画布高, 帧高) 行即可)
  frame: [UInt64],        // 新帧逐行指纹
  tolerance: Double       // 每行允许的不匹配采样比例阈值(0...1),用于近似匹配
) -> Int?
```

- 思路:在 `canvasTail` 中找一个起点 `k`,使 `canvasTail[k...]` 与 `frame[0...]` 在容差内逐行匹配
  (匹配长度 = 重叠行数 `overlap`)。取**重叠最长且通过容差**的 `k`;`appendable = frame.count - overlap`。
- 边界:
  - 首帧(画布为空)→ 直接返回 `frame.count`(整帧即初始画布)。
  - `overlap == frame.count`(完全重叠/没滚)→ 返回 `0`。
  - 找不到通过容差的对齐(滚太快/内容跳变)→ 返回 `nil`。
  - 向上滚(新帧底部与画布顶部重叠)→ v1 不识别,落入"对不上"→ `nil`,忽略。

### 拼接(AppKit 侧)

`ScrollStitcher`:
- 持有增长位图(`CGContext`,RGBA,按 `scale`)与已拼行指纹尾巴。
- `append(frame:) -> StitchOutcome`:算帧指纹 → `appendableRowCount` →
  - `nil` → `.skippedNoOverlap`(画布不变,HUD 提示慢滚);
  - `0` → `.unchanged`(没滚);
  - `>0` → 把帧底部 `appendable` 行画进画布底部,更新尾指纹与高度 → `.grew(by:)`;
  - 超过最大高度上限 → `.reachedLimit`。
- `finalize() -> CGImage?`:产出最终长图。

## 组件与接口

| 组件 | 位置 | 职责 | 测试 |
|---|---|---|---|
| `ScrollOverlapDetector` | VeltoAnnotationCore | 纯重叠检测,`appendableRowCount(...)` | 行为单测(核心) |
| `ScrollStitcher` | Velto/Screenshot | 帧→指纹、调用 detector、增长位图、产出长图 | 源串 + 可选轻量 |
| `ScreenshotCapturer.captureRegion` | Velto/Screenshot | `SCScreenshotManager` 抓选区 | 源串 |
| `ScrollCaptureHUD` | Velto/Screenshot | 浮窗:缩略预览 + 提示 + 接键盘 | 源串 |
| `ScreenshotSession`(扩展) | Velto/Screenshot | scroll 模式编排:passthrough、定时器、喂帧、收键、输出 | 源串 |
| `ScreenshotOverlayView`(扩展) | Velto/Screenshot | 滚动键触发 `.scroll` 已存在;进入模式后置 passthrough | 源串 |

## 数据流

```
选区(globalRect) ──按 S──▶ ScreenshotSession.beginScrollCapture
   overlay.ignoresMouseEvents = true;present HUD;start timer
        │每拍
        ▼
ScreenshotCapturer.captureRegion(globalRect) ─▶ CGImage(选区像素)
        ▼
ScrollStitcher.append(frame) ─(ScrollOverlapDetector)─▶ 追加新行 / skip / unchanged / limit
        ▼
HUD.update(thumbnail, height, outcomeHint)
        │Enter/空格 → finalize → ScreenshotImageWriter.copyToClipboard
        │⌘S        → finalize → ScreenshotImageWriter.save(预设目录/格式)
        │Esc       → 丢弃,stop timer,overlay 复原,回选区
        ▼
teardown(还原前台 App 等,同现有)
```

## 错误处理

- **滚太快/对不上(`nil`)**:跳过该帧,画布不变,HUD 提示"滚慢一点";不报错、不退出。
- **没滚(`0`)**:静默跳过,不增长。
- **向上滚**:v1 落入"对不上"被忽略。
- **抓帧失败**:跳过这一拍,下一拍继续。
- **到达最大高度上限**:停止追加,HUD 显示"已达上限,可结束";Enter 仍可定稿输出。
- **结束时长图过短(仅初始一帧)**:直接输出该帧(等价一次普通区域截图)。
- **复制/保存失败**:复用现有失败处理(蜂鸣 + 非阻塞 toast),**保留**滚动结果不 teardown,可重试 Enter/⌘S。
- **调试日志**:复用 `ScreenshotDebugLog`,记录每拍 outcome(grew/skip/unchanged/limit)、当前高度、最终输出,
  便于按 [[velto-screenshot-debug-logging-workflow]] 排查拼接问题。

## 测试策略

- **`ScrollOverlapDetector` 行为单测(核心,VeltoAnnotationCore 可 `@testable import`)**,用合成 `[UInt64]` 序列:
  - 干净重叠(画布尾 = 帧顶若干行)→ 返回正确新行数;
  - 完全重叠/没滚 → `0`;
  - 无重叠/滚太快 → `nil`;
  - 容差内带噪声(部分采样位翻转但在阈值内)→ 仍正确对齐;
  - 首帧(空画布)→ 返回整帧行数。
- **源串测试**(executable 目标,按既有约定):
  - `ScreenshotCapturer` 含 `captureRegion` 与 `sourceRect`;
  - `ScrollStitcher` 调 `ScrollOverlapDetector.appendableRowCount`;
  - `ScreenshotSession` 含 scroll 模式入口与 passthrough(`ignoresMouseEvents`);
  - HUD 含提示文案与 Enter/空格/⌘S/Esc 处理。
- 测试文件按 [[no-committing-test-files]] **不入库**。

## 验收标准

1. 选区激活后按 `S` 进入滚动模式:整屏不压暗、出现 HUD、可正常滚动目标 App。
2. 缓慢向下滚动时,HUD 缩略实时变长,拼接无明显错位/重影。
3. `Enter`/空格完成并复制;`⌘S` 完成并保存到预设目录;`Esc` 丢弃回到选区。
4. 滚太快时不崩、不乱拼,提示慢滚;到底/到上限可正常结束。
5. `ScrollOverlapDetector` 单测全绿;`./scripts/build-app.sh --run` 打包通过并实测一次长截图。
