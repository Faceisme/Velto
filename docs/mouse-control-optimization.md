# 鼠标控制模块 优化实施方案

> 目标读者:维护者(review 后再决定动手)
> 范围:`Sources/Velto/MouseControl/*` 及其在 `EventTapManager` 的接入点
> 部署目标:`.macOS(.v26)`(`CADisplayLink` / `os.Logger` 等现代 API 全部可用)
> 代码骨架仅示意改造点,落地时以仓库现有 4 空格 Swift 风格为准。

---

## 0. 背景

鼠标控制模块是把 **Mos 的 ScrollCore** 移植进来的(见 `MouseControlController.swift:530` 注释,CC BY-NC)。
功能完整,但**平滑滚动引擎(约 700/1226 行)的并发模型和项目其它部分割裂**:

- 手势 / 拖拽 / 缩放:跑在一条专用高 QoS **tap 线程**,"每事件零跨线程同步"(`EventTapManager` 类注释)。
- 滚动:scroll tap 挂在**主线程** runloop(`EventTapManager.swift:425`),再扇出到 CVDisplayLink 私有线程 + `mouse-scroll.post` 串行队列。

最高频、最在意延迟的路径反而放主线程。CVDisplayLink 弃用只是这条割裂线最表层的一根刺。

### 现状数据流(一次平滑滚动)

```
scroll tap 回调(主线程)
  └─ handleScrollWheel → animator.submit
       ├─ dispatchContext.capture        ← CGEvent.copy() #1
       ├─ os_unfair_lock 状态计算
       └─ post → preparePostingSnapshot   ← CGEvent.copy() #2
            └─ enqueue → postQueue.async   ← GCD 跳到第 3 个上下文
                 └─ postToPid

CVDisplayLink 回调(私有线程)每帧
  └─ processing → post → copy + enqueue → postQueue.async → postToPid

HID tap 线程(鼠标按下)
  └─ animator.stop → CVDisplayLinkStop(阻塞 HID 线程)
```

4 个执行上下文协调一次滚动,靠手写 generation + TTL(5s,基本不命中)兜底。

---

## 1. 问题清单(落地时逐条对应)

| # | 等级 | 位置 | 问题 |
|---|------|------|------|
| 1 | 🔴 架构 | `EventTapManager.swift:425` | scroll tap 挂主线程 runloop |
| 2 | 🔴 架构 | 全引擎 | 4 个执行上下文 + generation/TTL 兜底,3 线程争用同一 CVDisplayLink |
| 3 | 🔴 并发 | `MouseControlController.swift:1169→946` | `CVDisplayLinkStop` 从回调线程自身调用 |
| 4 | 🔴 并发 | `MouseControlController.swift:246` | HID tap 线程被 `CVDisplayLinkStop` 阻塞 |
| 5 | 🟠 API | `MouseControlController.swift:803,975` | CVDisplayLink 弃用 + 每帧 lerp **帧率相关** |
| 6 | 🟠 UI | `MouseControlPage.swift:187` / `Models.swift:103` | "持续时间…秒"是假单位 |
| 7 | 🟠 性能 | `MouseControlController.swift:166,249,338` | 每事件 `NSRunningApplication` 查询;enabled 检查在其后 |
| 8 | 🟠 性能 | `MouseControlController.swift:685` | `polish` 每帧每轴堆分配 5 元素数组,索引 2/3/4 死值 |
| 9 | 🟠 性能 | `MouseControlController.swift:716,764` | 每帧 2~3 次 `CGEvent.copy()` |
| 10 | 🟠 性能 | `MouseControlController.swift:369` | normalized flag 重复计算(`handle()` 已算过) |
| 11 | 🟠 性能 | `MouseControlController.swift:54` | debug logger 关闭时仍每事件加锁 |
| 12 | 🟡 正确性 | `MouseControlPage.swift:317` | `ForEach(indices, id:\.self)` + 按 index 删除,越界/错乱 |
| 13 | 🟡 正确性 | `MouseControlController.swift:7,301` | `consumedTriggers` key 不含 modifier |
| 14 | 🟡 健壮 | `EventTapManager.swift:334,346` | 键盘/纯修饰键绑定可全局吞键,无防呆 |
| 15 | 🟡 健壮 | `MouseControlController.swift:328` | `runScript` 用 login shell + `try?` 静默,无超时 |
| 16 | 🟡 质量 | 整文件 | 1226 行七职责;自造文件日志可换 `os.Logger` |

---

## 2. P0 — 并发模型归一(根因,顺手解决 CVDisplayLink)

### 2.1 设计原则

**一条线程拥有滚动的一切**:scroll tap source、动画 displayLink、引擎可变状态,全部 affine 到一条专用高 QoS runloop 线程上。与 HID tap 线程对称。这样:

- 滚动彻底离开主线程(问题 1)。
- displayLink 回调、submit、stop 都在同一线程 → **无需 `stateLock`**,无需 generation/TTL(问题 2)。
- stop 用 `isPaused`,不再有跨线程阻塞 / 回调内 stop(问题 3、4)。
- 投递直接在该线程同步做,删掉 `postQueue` 一跳(问题 2、9)。

> 注:HID tap 线程鼠标按下时仍要"叫停滚动"。改为 `CFRunLoopPerformBlock(scrollRunLoop){ animator.pause() }` + `CFRunLoopWakeUp`,异步投递、不阻塞 HID 线程(对应 `EventTapManager` 已有的 `performOnTapThread` 模式)。

### 2.2 线程 / runloop 拥有模型

在 `EventTapManager` 复用现成套路,新增一条 scroll 线程(或与 HID tap 合用一条都可,推荐独立以隔离延迟):

```swift
// EventTapManager
private var scrollTapThread: Thread?
private var scrollTapRunLoop: CFRunLoop?

private func startScrollEventTap() -> Bool {
  guard scrollEventTap == nil else { return true }
  let mask = eventMask(for: .scrollWheel)
  guard let tap = CGEvent.tapCreate(
    tap: .cgAnnotatedSessionEventTap,
    place: .tailAppendEventTap,
    options: .defaultTap,
    eventsOfInterest: mask,
    callback: veltoScrollEventTapCallback,
    userInfo: Unmanaged.passUnretained(self).toOpaque()
  ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
    return false
  }
  scrollEventTap = tap
  scrollRunLoopSource = source

  let ready = DispatchSemaphore(value: 0)
  let thread = Thread { [weak self] in
    guard let rl = CFRunLoopGetCurrent() else { ready.signal(); return }
    CFRunLoopAddSource(rl, source, .commonModes)
    self?.scrollTapRunLoop = rl
    self?.mouseControlController.attachScrollRunLoop(rl)   // 动画器在这条线程建 CADisplayLink
    ready.signal()
    CFRunLoopRun()
    CFRunLoopRemoveSource(rl, source, .commonModes)
  }
  thread.name = "com.face.velto.scrolltap"
  thread.qualityOfService = .userInteractive
  scrollTapThread = thread
  thread.start()
  ready.wait()
  CGEvent.tapEnable(tap: tap, enable: true)
  return true
}
```

`stop()` 里对称地 `CFRunLoopStop(scrollTapRunLoop)`、invalidate source/tap。

### 2.3 CADisplayLink 接入(替换 CVDisplayLink)

macOS 没有公开的 `CADisplayLink(target:selector:)`,从 `NSScreen` 取:

```swift
private final class MouseSmoothScrollAnimator {
  private var displayLink: CADisplayLink?
  private weak var runLoop: CFRunLoop?     // 由 attachScrollRunLoop 注入

  func attach(runLoop: CFRunLoop) {
    self.runLoop = runLoop
    rebuildDisplayLink()
    // 屏幕变化(refresh rate / 接显示器)时重建
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in self?.scheduleRebuildOnScrollThread() }
  }

  private func rebuildDisplayLink() {
    displayLink?.invalidate()
    guard let screen = NSScreen.main else { return }
    let link = screen.displayLink(target: self, selector: #selector(frameTick(_:)))
    link.isPaused = true
    // 关键:加到滚动线程自己的 runloop,回调就在本线程触发
    link.add(to: RunLoop.current, forMode: .common)
    displayLink = link
  }

  @objc private func frameTick(_ link: CADisplayLink) {
    let dt = link.targetTimestamp - link.timestamp   // 本帧应跨越的真实秒数
    processing(dt: dt)
  }

  func start() { displayLink?.isPaused = false }     // 不再 CVDisplayLinkStart
  func pause() { displayLink?.isPaused = true }      // 不再 CVDisplayLinkStop(无阻塞)
}
```

`frameTick`、`submit`、`pause` 全在滚动线程 → 去掉 `os_unfair_lock stateLock`,所有 `current/buffer/delta/phase` 变普通字段。

### 2.4 帧率无关步进(问题 5)

现状 `frame = (buffer - current) * frameFactor` 是**每帧固定比例**,120Hz 比 60Hz 收敛快一倍。
改为时间常数 τ 的连续指数趋近,用本帧 `dt` 离散化:

```swift
// τ 为"追赶时间常数"(秒),由 profile.duration 映射而来,语义明确
let alpha = 1 - exp(-dt / tau)          // dt=1/120 与 dt=1/60 自动等价
let frame = (y: (buffer.y - current.y) * alpha,
             x: (buffer.x - current.x) * alpha)
```

- `tau` 取值范围用真实秒(如 0.04…0.30s),UI 标签可老实写"平滑时长"且**真的是秒**(同时修问题 6)。
- 删除 `MouseScrollProfile.transitionFactor` 那段 `1 - sqrt(...)` 魔法公式,或保留为兼容旧 JSON 的换算。
- momentum 段同理用 `dt` 离散化。

### 2.5 投递简化(问题 2、9)

回调已在非主线程 → 直接同步投递,删除 `MouseScrollDispatchContext` 的 `postQueue` / generation / TTL:

```swift
// 复用单个事件模板,只改 delta/phase/marker 后投递,避免每帧 clone
private func post(_ value: (y: Double, x: Double), phase: (scroll: Double, momentum: Double)?) {
  guard let ev = templateEvent else { return }
  if let p = phase {
    ev.setDoubleValueField(.scrollWheelEventScrollPhase, value: p.scroll)
    ev.setDoubleValueField(.scrollWheelEventMomentumPhase, value: p.momentum)
  }
  ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: value.y)
  ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: value.x)
  ev.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1)
  ev.setIntegerValueField(.eventSourceUserData, value: MouseControlController.syntheticScrollMarker)
  ev.postToPid(targetPID)            // 同线程同步,确定性顺序
}
```

方向突变 / 停止时改为直接重置 `templateEvent` + filter,不再靠 generation 丢弃在途帧(因为已无"在途")。

---

## 3. P1 — 热路径瘦身

### 3.1 enabled 原子闸门(问题 7)

最顶端一条指令短路,关功能时零成本:

```swift
private let enabledFlag = ManagedAtomic<Bool>(false)   // 或 os_unfair_lock 保护的 Bool

func handleTriggerEvent(type: CGEventType, event: CGEvent) -> Bool {
  guard enabledFlag.load(ordering: .relaxed) else { return false }
  ... // 原逻辑
}
func handleScrollWheel(event: CGEvent) -> Bool {
  guard enabledFlag.load(ordering: .relaxed) else { return false }
  ...
}
```

`updatePreferences` 里同步写 `enabledFlag`。

### 3.2 frontmost bundleID / profile 缓存(问题 7)

复用 `EventTapManager` 已订阅的 `didActivateApplicationNotification`,把当前 app 的解析结果缓存,热路径只读:

```swift
private struct ResolvedSnapshot { let bundleID: String?; let profile: ...; let hotkeys: ...; let bindings: ... }
private var cached: ResolvedSnapshot = ...    // 仅滚动线程读写(P0 后免锁)

func updateFrontmostApp(_ app: NSRunningApplication) {  // 由 manager 在滚动线程投递
  cached = resolve(bundleID: app.bundleIdentifier)
}
```

干掉 `bundleIdentifier(for:)` 里每事件的 `NSRunningApplication(processIdentifier:)` 与 `appRules.first(where:)` 线性扫描。
偏好变更时重算一次缓存即可。

### 3.3 filter 去分配(问题 8)

`polish` 只用到索引 0(输出)和 1(下帧状态),改持两个标量:

```swift
private final class MouseScrollFilter {
  private var prevY = 0.0, stateY = 0.0
  private var prevX = 0.0, stateX = 0.0
  func fill(_ next: (y: Double, x: Double)) -> (y: Double, x: Double) {
    let outY = prevY; stateY = prevY + 0.23 * (next.y - prevY); prevY = stateY  // 等价两 tap
    let outX = prevX; stateX = prevX + 0.23 * (next.x - prevX); prevX = stateX
    return (outY, outX)
  }
}
```
> 落地时按原 `polish` 的语义精确核对(index 0 = 上次的 `values[1]`),保证手感不变后再删多余项。

### 3.4 复用 raw(问题 10)

`handle()` 已算 `raw`,把它透传进 `handleTriggerEvent(..., normalizedFlags: raw)`,`MouseTriggerEvent.init` 直接用,不再 `normalizedRawValue(from:)` 二次计算。

### 3.5 logger 免锁(问题 11)

`nextEventID()` 先读原子 `enabled` 再决定是否加锁;或整段 debug 路径用 `os.Logger` + `OSSignposter`,生产期零开销。

---

## 4. P2 — 正确性 / 健壮性 / 质量

### 4.1 ForEach 修复(问题 12)

`MouseButtonBinding: Identifiable`,改绑定式遍历,杜绝按 index 删除:

```swift
ForEach($bindings) { $binding in
  MouseBindingRow(binding: $binding, onDelete: { bindings.removeAll { $0.id == binding.id } })
}
```

### 4.2 consumedTriggers 带 modifier(问题 13)

```swift
private struct MouseRuntimeTriggerKey: Hashable {
  let kind: MouseInputKind; let code: UInt16; let modifierFlags: UInt64
}
```
插入 / 移除都用含 modifier 的 key,避免同键不同修饰键串台。

### 4.3 绑定防呆(问题 14)

保存校验:trigger 为纯修饰键 / 裸键(无 modifier 的普通键)时给出警告,默认不允许全局吞键,或仅在该 app 规则内生效。UI 层在 `MouseControlPage` 保存前提示。

### 4.4 runScript 收口(问题 15)

```swift
case .runScript(let script):
  DispatchQueue.global(qos: .utility).async {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", script]     // 去掉 -l,启动更快
    do { try p.run() } catch { Log.mouse.error("runScript failed: \(error)") }
    // 可选:超时 kill、退出码上报
  }
```

### 4.5 拆文件 + 日志(问题 16)

按职责拆:
- `MouseScrollAnimator.swift`(displayLink + 步进 + 投递)
- `MouseScrollPhase.swift`(相位状态机 + 映射表)
- `MouseScrollFilter.swift`
- `MouseControlController.swift`(只留事件分发 / 触发 / 缓存)
- `MouseScrollDebug.swift`(改 `os.Logger` / signpost,或保留 flight-recorder 但收敛)

---

## 5. 风险与回归验证

平滑滚动是"手感"代码,改完必须人工对比。建议保留 `debugLoggingEnabled` 这条 trace 直到验证完成。

回归清单:
- [ ] 普通鼠标垂直 / 水平平滑,加速键、方向转换键、禁用平滑键。
- [ ] 触控板事件仍直接透传(`isTrackpadLike`)。
- [ ] 方向突变、快速连滚、滚动中途按下鼠标 → 立即停。
- [ ] 60Hz 与 120Hz/ProMotion 手感一致(P0 的核心收益,需两种刷新率实测)。
- [ ] 切换 / 拔插显示器后 displayLink 重建,滚动正常。
- [ ] `simulateTrackpad` 开 / 关两种相位标记路径。
- [ ] 按应用规则:继承 vs 覆盖;按钮绑定(system / shortcut / openApp / openFile / runScript)。
- [ ] 关闭"启用鼠标控制"后,敲键 / 滚动零额外开销(用 signpost / Instruments 抽样确认)。
- [ ] 设置页增删绑定不再越界 crash。

度量(Instruments / signpost):
- 每帧 CGEvent 分配次数:目标 2~3 → ~1。
- `mouse-scroll.post` 队列消失;滚动期间主线程无相关采样。
- 功能关闭时 `handle*` 路径无 `NSRunningApplication` 调用。

---

## 6. 落地步骤(建议 PR 拆分)

1. **PR-1(P0 基座,不改手感)**:scroll tap 移到专用线程 + CVDisplayLink→CADisplayLink + 投递直连 + 去 stateLock/generation/TTL。先保持原 `frameFactor` 语义,确保"行为等价"再合。
2. **PR-2(帧率无关)**:引入 τ / `dt` 步进,修 UI "秒"单位与 `transitionFactor`。需双刷新率实测。
3. **PR-3(P1 热路径)**:enabled 闸门 + bundleID 缓存 + filter 去分配 + raw 透传 + logger 免锁。
4. **PR-4(P2 正确性/质量)**:ForEach、consumedTriggers、绑定防呆、runScript、拆文件 / 日志。

每个 PR 独立可回滚;PR-1/PR-2 是收益和风险都最大的部分,务必人工手感回归。

---

## 7. 预期目标

- **手感 / 延迟**:滚动脱离主线程,设置窗忙时不抖;120/60Hz 手感一致。
- **CPU / 分配**:每帧 "2~3 次 copy + 1 次 GCD 跳 + 2 次数组分配" → "~1 次投递 + 0 分配";关闭功能时每事件成本 ≈ 0。
- **稳定性**:消除三线程争用 displayLink、回调内 stop、HID 线程被阻塞;修掉 ForEach 越界 crash。
- **可维护性**:并发模型与项目统一;1226 行按职责拆分;去弃用 API。
