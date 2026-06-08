# Velto 触控板双指手势 — 设计文档

- 日期:2026-06-05
- 状态:已批准设计,待转实现计划
- 参考:Swish for macOS 演示视频(`~/Desktop/general.mp4`)

## 1. 目标

在触控板上用**双指滑动**对**光标下的窗口**执行三个动作:

| 手势(光标压在标题栏时) | 动作 |
|---|---|
| 双指上滑 | 最大化(填满可见屏幕区) |
| 双指下滑 | 最小化(收进 Dock) |
| 双指**左**滑 | 关闭窗口 |

刻意只做这三个;不做 App 级手势(视频「Apps.」段的隐藏/切换/退出)。

## 2. 交互模型(已锁定)

- **激活条件**:光标悬停在某窗口的**标题栏顶部条带**(约 28pt)内时,双指滑动才被识别为手势并被消费;其余任何位置零干扰、滚动照常。
- **目标窗口**:光标正下方的那个窗口。
- **方向映射**:上=最大化、下=最小化、左=关闭。右滑不映射动作(在标题栏上被消费但不触发,无副作用)。
- **不用 pinch/magnify**:三个动作全部用双指滑动方向表达,刻意避开难以可靠拦截的 magnify 手势事件。

## 3. 拦截层 —— 复用现有 scroll tap(Plan A)

双指滑动在底层即 `scrollWheel` 事件。项目已有专用滚动 tap:`EventTapManager.handleAnnotatedScroll`(`.cgAnnotatedSessionEventTap` / `.tailAppendEventTap`),内容缩放与平滑滚动已经在该回调里用 `return nil` 吞事件。

- **不用** `NSEvent` 全局 monitor(Plan B 无法阻止系统默认行为,会与滚动冲突)。
- 在 `handleAnnotatedScroll` 内、内容缩放判断**之前**插入 `TrackpadGestureController.handle(event:)`。仅当"本控制器拥有当前这一段滑动"时 `return nil`,否则原样放行交给平滑滚动。
- 与内容缩放互斥:内容缩放要求按住修饰键(`raw != 0`),触控板手势要求**无修饰键**(`raw == 0`)且光标在标题栏,二者条件不重叠,插入顺序安全。

## 4. 识别状态机:`TrackpadGestureController`

新文件,结构仿 `ContentZoomController`(tap 线程入口 + 私有串行 queue + `NSLock` 保护快照)。`@unchecked Sendable`。

按 `scrollWheel` 的 phase 字段(`kCGScrollPhaseBegan` / `Changed` / `Ended`)管理一次手势的生命周期:

1. **began**:做门控检查 ——
   - 触控板手势开关已开?
   - 是连续/触控板事件(`scrollWheelEventIsContinuous != 0`)?
   - 光标是否在某窗口标题栏条带内(见 §6)?
   - 全部满足 → 开 session,记下目标窗口 AXUIElement,清零累加器,开始累加 dx/dy,并**消费本段所有后续事件**。
   - 不满足 → 标记"本段不归我",全程放行(滚动正常)。
2. **changed**:归我 → 累加 dx/dy 并消费;不归我 → 放行。
3. **ended**:归我且累加量 ≥ 激活阈值 → 判主轴方向 → 派发对应动作一次 → 清 session;低于阈值视为误触,忽略。
4. **momentum 阶段**:归我则一并消费,不触发二次动作。

设计取舍:**在 ended 才触发动作**(非边滑边触发)——最稳、最不易误关窗口,贴合视频"松手才动作"。

### 方向判定

- 累加整段 dx、dy。`ended` 时:
  - `|dy| > |dx|` → 竖直:上→最大化,下→最小化。
  - 否则 → 水平:**左→关闭**;右→无动作(忽略)。
- 激活阈值约 30–40pt(可调常量),小于阈值忽略,防止标题栏上的微小滑动误触发。
- **delta 符号方向必须实测标定**(自然滚动开/关会反号),靠调试日志现场校准,不硬编码假设。

## 5. 三个动作的落地

动作全部走 AX;实际 AX 写入派发到 `DispatchQueue.global(qos: .userInteractive)`,**绝不**在 tap 线程同步执行。

| 动作 | 实现 | 状态 |
|---|---|---|
| 最大化 | 调 `GestureTargetController.maximizeWindowUnderPointer(at:)`(填满 `visibleAccessibilityFrame`) | 已存在,直接复用 |
| 最小化 | 新增 `GestureTargetController.minimizeWindow(_:)`:设 `kAXMinimizedAttribute = true`,失败回退按 `kAXMinimizeButtonAttribute` | 新增 |
| 关闭 | 新增 `GestureTargetController.closeWindow(_:)`:按 `kAXCloseButtonAttribute`(`AXUIElementPerformAction(_, kAXPressAction)`,等价点红灯,会正常触发"是否保存"对话框) | 新增(抽现有 `performDirectWindowCloseIfAvailable` 同款逻辑) |

- 最大化语义 = "填满可见屏幕区",**非原生全屏**(原生全屏会新建 Space、隐藏菜单栏,更难逆,不做)。
- 最大化**不做"再上滑还原"切换**(本期明确不做)。

## 6. 标题栏命中判定

- `GestureTargetController.windowUnderPointer(at:)` 取窗口 + `frame(ofWindow:)` 取 frame。判断光标 Y 是否落在窗口顶部约 28pt 条带内。
- 坐标"原始 vs 转换"双取沿用 `WindowDragController.initialDragPoint` 的同款处理(多屏场景)。
- **时机(v1)**:在 `began` 时**同步**做这次 AX 查询(消息超时收紧到约 0.1s);一次手势只查一次。
- **P2 优化(若 began 有顿挫再做)**:订阅现有 `.mouseMoved`,在后台预热缓存"当前光标是否压标题栏 + 哪个窗口",`began` 时只读缓存(瞬时),避免在 scroll tap 线程做同步跨进程 AX 调用(该线程同时驱动平滑滚动的 CADisplayLink)。

## 7. 开关与调试(照搬现有"每模块自管"架构)

- `AppPreferences`(`Models.swift`)新增两个字段(照 `gesturesEnabled` 同款直接并入 `AppPreferences`,**不**单独建偏好 struct):
  - `trackpadGesturesEnabled`(**默认 `false`** —— 用户装好后到新页面手动开,避免一上来就吞标题栏滑动)。
  - `trackpadGestureDebugLoggingEnabled`(默认 `false`)。
- `EventTapManager` 新增 tap 线程快照 `trackpadGesturesEnabledForTap`(init 设初值 + `storeObserver` 更新),与 `gesturesEnabledForTap` / `windowManagementEnabledForTap` 同款模式。
- 新增侧栏页「触控板手势」:启用开关 + 三个手势的图示说明 + 调试日志开关。
- 新增 `TrackpadGestureDebugLog` → `~/Library/Logs/Velto/trackpad-gesture-debug.log`;关掉零开销,与现有三套调试日志并列。

## 8. 文件清单

**新增**
- `Sources/Velto/TrackpadGesture/TrackpadGestureController.swift`
- `Sources/Velto/TrackpadGesture/TrackpadGesturePage.swift`
- `Sources/Velto/TrackpadGesture/TrackpadGestureDebugLog.swift`

**改动**
- `Sources/Velto/EventTapManager.swift`(挂控制器 + 快照 + 在 `handleAnnotatedScroll` 内分发)
- `Sources/Velto/GestureTargetController.swift`(加 `minimizeWindow` / `closeWindow`)
- `Sources/Velto/Models.swift`(偏好字段 + 默认值,注意 `Codable` 向后兼容/默认解码)
- `Sources/Velto/SidebarView.swift` + `Sources/Velto/SettingsRootView.swift`(挂页面)

## 9. 风险 / 待调参

1. **delta 符号方向**:自然滚动开/关反号 —— 靠调试日志打印 dx/dy 现场校准。
2. **began 同步 AX 查询延迟**:正常 1–5ms,挂死 App 才触超时;P2 预热可消除。
3. **App 兼容性**:个别 App 标题栏区域/关闭/最小化按钮 AX 暴露不标准 —— 届时按需加 `AppQuirks`。
4. **`Codable` 兼容**:新增偏好字段需有默认值,老配置文件能正常解码。

## 10. 明确不做(YAGNI)

- 仅三个动作;方向映射写死,不做可配置 UI。
- 不碰 pinch/magnify。
- 不做原生全屏、不做最大化还原切换。
- 不做 App 级手势(视频「Apps.」段)。

## 11. 验证

按项目规范,改完跑 `./scripts/build-app.sh --run` 完整打包部署,在真机上实测三个手势 + 确认非标题栏处滚动不受影响。
