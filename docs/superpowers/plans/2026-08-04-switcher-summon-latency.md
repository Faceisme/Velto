# 窗口切换器候选列表弹出延迟修复实施文档

**目标：** 降低窗口切换热键触发后，候选列表因主线程同步系统调用而延迟出现的概率，同时保持现有窗口存活、幽灵窗口和多 Space 判定语义不变。

**实施原则：** 修复已采样确认的主线程阻塞点，不重写候选卡片、缩略图或窗口索引架构；复用既有 `AXCallQueue` 和现有 detached ghost probe。

**技术环境：** Swift 6.2、macOS 26、AppKit、Accessibility、Core Graphics / SkyLight、Swift Testing。

---

## 1. 问题与证据

切换热键虽然由独立的 `SwitcherKeyTap` 线程接收，但真正的候选快照和 `panel.show` 在 `MainActor` 上执行。因此，触发瞬间任何主线程同步 IPC 都会直接变成“按下快捷键后列表晚一点出现”。

本次诊断得到两项直接证据：

1. 对正在运行的 Velto 采样时，主线程连续约 175 ms 停在以下调用链：

   `workspaceDidLaunchApp → addApp → SwitcherApp.startObserving → AXObserverAddNotification`

   `AXObserverAddNotification` 是跨进程 Accessibility IPC；目标 App 启动中或不响应时，耗时不可控。它与候选列表渲染无关，但会占住负责弹出面板的主线程。

   对全部调用点继续审计后，窗口新增、AX 树重建和窗口移除路径也会在主线程直接执行 `AXObserverAddNotification` / `AXObserverRemoveNotification`。它们与采样命中的 App 级注册属于同一个阻塞源，必须一并移出主线程，否则修复不完整。

2. `runGhostProbeNow()` 虽然把主要探测放进了 `Task.detached`，却在进入后台任务前，仍于 `MainActor` 同步执行：

   - `SwitcherSpaces.allSpaceIds()`
   - `SwitcherSpaces.visibleSpaceIds()`

   两者属于 SkyLight / WindowServer 查询，不应留在召唤热路径的主线程上。

同时，以下路径没有证据表明是首屏延迟主因：

- 面板在启动时预热，弹出动画已关闭；
- 缩略图抓取在 `panel.show` 之后异步开始；
- 候选视图已有可复用时的快速更新路径；
- `CGWindowListCreateDescriptionFromArray` 对 14 个窗口的只读基准：最小 0.183 ms、中位数 0.206 ms、P95 0.301 ms、最大 2.500 ms。

因此不以“删掉渲染”或“删除同步窗口校验”作为本次修复手段。

## 2. 修改范围

### 2.1 AX 通知注册与反注册移出主线程

文件：

- `Sources/Velto/Switcher/SwitcherApp.swift`
- `Sources/Velto/Switcher/SwitcherWindowList.swift`

保留在 `MainActor`：

- `AXObserverCreate`
- 保存 `axObserver`
- 将 observer 的 source 挂到 main run loop

移到既有 `AXCallQueue.shared`：

- App 级五次 `AXObserverAddNotification`
- 窗口级四次 `AXObserverAddNotification`
- 窗口移除或 AX element 替换时的四次 `AXObserverRemoveNotification`

实现方式：增加一个仅保存 immutable Core Foundation 引用、通知列表和 refcon 的 `@unchecked Sendable` 小值类型，由它在 AX 后台串行队列执行注册或反注册。App 级与窗口级调用复用同一个值类型，不新增协议、工厂或新队列。此类一次性生命周期操作使用既有 `AXCallQueue.submit`，避免节流取消掉必须执行的反注册。

顺序保证：`addApp` 先提交 App 通知注册，随后提交 `syncWindowsForApp`；两者使用同一个串行 AX 队列。窗口级注册只会在该扫描完成、结果回到主线程并创建窗口对象后提交。AX element 替换时，旧 element 的反注册先提交，新 element 的注册随后提交。即使注册期间发生状态变化，紧随其后的全量扫描仍负责收敛当前窗口清单。

生命周期保证：后台任务强持有 observer 注册值直至注册结束；App 提前退出时，主线程仍可移除 run-loop source，迟到的注册结果只会失败或落到即将释放的 observer，不访问已释放对象。

### 2.2 Ghost probe 的 Space 查询移入后台任务

文件：`Sources/Velto/Switcher/SwitcherWindowList.swift`

主线程仅保留：

- `ghostProbeInFlight` 判定与置位
- 当前 `windows` 快照

移入已有 `Task.detached(priority: .userInitiated)`：

- `SwitcherSpaces.allSpaceIds()`
- `SwitcherSpaces.visibleSpaceIds()`
- `SwitcherGhostDetector.probe(across:)`

探测结果仍通过 `MainActor.run` 应用，`ghostProbeInFlight`、窗口对象状态和节流时间戳的所有写入规则不变。

## 3. 明确不改的内容

- 不删除 `snapshot` 中的同步 WindowServer 批量存活/在屏校验。它通常低于 1 ms，且负责避免微信 `orderOut`、AX 树重建及已关闭窗口残留等正确性回归。
- 不改 `SwitcherPanel`、`SwitcherTilesView` 的布局与复用逻辑。
- 不改 `SwitcherThumbnails` 的 ScreenCaptureKit / 私有 API 抓取路径。
- 不增加缓存、配置开关、并行 AX 队列或新的性能框架。
- 不修改工作区内用户已有的未跟踪测试文件。

## 4. 回归风险与控制

| 风险 | 控制方式 |
|---|---|
| 通知注册晚于 observer source 挂载，短窗口内漏事件 | 注册与首次全量扫描在同一串行 AX 队列，扫描紧随注册并收敛最终状态 |
| App 或窗口在注册任务执行前退出 | 操作值强持有 AX 引用；run-loop source 仍由主线程正常移除；迟到操作只作用于即将释放的 observer / element |
| 节流取消导致旧窗口通知未解绑 | 注册与反注册使用不节流的 `submit`，保留每个生命周期操作及提交顺序 |
| 后台读取 Space 时窗口集合变化 | 与现状一致：先保存窗口对象快照，回主线程时用对象身份检查过滤已被替换/删除的窗口 |
| 移除同步校验造成幽灵窗口重新出现 | 本次明确保留同步 WindowServer 批量校验 |
| Swift 6 并发检查不通过 | 仅对 immutable CF 引用容器作局部 `@unchecked Sendable` 声明，并以完整 build 验证 |

## 5. 实施与测试步骤

- [x] 新增一个最小热路径源码回归测试，约束 App 级和窗口级 AX 通知注册/反注册必须提交到 `AXCallQueue`，并约束两次 Space 查询必须位于 `Task.detached` 内。
- [x] 在修改生产代码前运行该测试，确认它因当前同步实现而失败。
- [x] 修改 `SwitcherApp.startObserving`，后台串行注册 App 级 AX 通知。
- [x] 修改 `SwitcherWindowList`，后台串行注册/反注册窗口级 AX 通知。
- [x] 修改 `SwitcherWindowList.runGhostProbeNow`，后台读取 Space。
- [x] 运行新增的定向回归测试。
- [x] 运行全部 Switcher 测试。
- [x] 运行完整 `swift test`。
- [x] 运行 Velto 产品构建、`git diff --check` 和最终差异检查。

测试采用源码结构约束，是因为系统 AX IPC 没有可控的延迟注入点；为了构造行为测试而新增生产协议/依赖注入，会让本次两处调度修复膨胀成架构改造。已有逻辑测试与完整编译负责验证功能和并发类型安全。

## 6. 验收标准

同时满足以下条件才算完成：

1. 主线程的 `startObserving` 不再直接执行 `AXObserverAddNotification`。
2. 窗口新增、AX element 替换和移除路径不再直接执行 AX 通知注册/反注册 IPC。
3. `runGhostProbeNow` 在进入 detached task 前不调用 Space 查询。
4. 同步 WindowServer 存活校验、候选排序、过滤与缩略图行为保持不变。
5. 新增定向测试、全部 Switcher 测试和完整测试套件通过。
6. Velto 可完整构建，`git diff --check` 无格式错误。
7. 最终差异只包含本文档、一个回归测试和上述两处生产代码修复；用户原有未跟踪文件未被修改。

## 7. 回滚

若出现 AX 通知缺失或窗口索引不收敛，只需回退两处源码中的后台通知操作；若出现 Space / ghost 判定异常，只需把两次 Space 查询移回 detached task 外。两项改动互相独立，不涉及数据迁移或配置兼容。

## 8. 实施结果（2026-08-04）

- 修复前定向回归：3 项测试均按预期失败，共命中 8 个约束问题。
- 修复后定向回归：3 项全部通过。
- 全部 Switcher 测试：16 项 XCTest + 15 项 Swift Testing，共 31 项全部通过。
- 完整测试套件：28 项 XCTest + 31 项 Swift Testing，共 59 项全部通过。
- `swift build -c debug --product Velto`：通过。
- `git diff --check`：通过，无空白或补丁格式错误。
- 编译仍报告一条既有的 `SwitcherTilesView` actor-isolation warning；该文件未改动，与本次修复无关。
- 未覆盖安装 `/Applications/Velto.app`，避免把代码验证擅自扩大为本机部署；本次完成的是源码、测试和产品构建验收。
