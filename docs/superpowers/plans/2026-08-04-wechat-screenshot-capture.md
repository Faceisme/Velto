# 微信窗口截图兼容修复实施文档

**目标：** 在 macOS 27 上，普通截图能够包含微信等 `sharingNone` 可见窗口，同时保持其他截图场景继续使用现有 ScreenCaptureKit 快速路径。

**实施原则：** 只修复已实测确认的捕获入口；不修改覆盖层、选区、标注和写图逻辑，不引入微信 bundle ID 特判。

**技术环境：** Swift 6.2、macOS 27、AppKit、AVFoundation、ScreenCaptureKit、Core Graphics、VideoToolbox。

---

## 1. 问题与实测证据

当前 `ScreenshotCapturer.captureAllDisplays()` 使用 `SCScreenshotManager.captureImage` 获取冻结快照。微信 4.1.11 的主窗口虽然可见，但其 `kCGWindowSharingState` 为 `0`；在当前 macOS 27 Beta 上：

- ScreenCaptureKit 整屏截图会用后方窗口替代微信；
- `desktopIndependentWindow` 直接捕获返回 `SCStreamErrorDomain -3811`；
- 正确等待 `updateContentFilter` 完成并丢弃 5 帧后，持续捕获仍不包含微信；
- `CGSHWCaptureWindowList` 返回空数组；
- `CGDisplayCreateImage` 同样遗漏微信；
- `AVCaptureScreenInput` 在同一进程内先确认微信 on-screen 后，成功捕获 3456×2234 完整显示器帧，画面包含微信。

因此根因不是覆盖层隐藏微信，而是当前冻结快照选择的捕获 API 无法返回该窗口像素。

## 2. 修改范围

文件：

- `Sources/Velto/Screenshot/ScreenshotCapturer.swift`
- `Tests/VeltoTests/ScreenshotProtectedWindowCaptureTests.swift`

实现：

1. 每次启动截图只读取一次当前 on-screen 窗口信息。
2. 对每块 `SCDisplay` 判断是否与以下窗口相交：
   - layer 为 0；
   - alpha 大于 0；
   - sharing state 为 `CGWindowSharingType.none`；
   - bounds 非空且与显示器 frame 相交。
3. 命中时，仅该显示器改用 `AVCaptureScreenInput`，取首个 BGRA 视频帧并通过 VideoToolbox 转成 `CGImage`。
4. 未命中时保持现有 `SCScreenshotManager.captureImage` 实现。
5. AV 捕获在独立串行队列启动，2 秒内没有有效帧则失败并结束会话，避免阻塞主线程或无限等待。
6. AV 兼容捕获失败时记录原因并退回原 ScreenCaptureKit 路径，避免整个截图入口失效。

## 3. 明确不改

- 不写死微信进程名或 bundle ID；任何真实可见的 `sharingNone` 普通窗口走同一兼容规则。
- 不把所有截图都切到 AVFoundation，避免无关场景承担额外会话启动成本。
- 不修改普通截图输出流程；它已经直接裁剪启动冻结快照。
- 不修改滚动长截图。该模式捕获期间仍显示 Velto 选区边框、HUD 和操作栏，直接切换到显示器级 AV 捕获会把自身 UI 写进拼接结果，需要独立设计。
- 不修改用户已有的未跟踪测试文件。

## 4. 风险与控制

| 风险 | 控制方式 |
|---|---|
| AV 会话阻塞主线程 | 创建、启动、停机和帧处理全部在专用串行队列执行 |
| delegate / continuation 重复完成 | 单队列内用 continuation 与 outcome 状态守卫，只允许首次有效帧或超时完成 |
| AV 会话异常导致无法截图 | 记录错误并退回原 ScreenCaptureKit 路径 |
| 多屏误用兼容路径 | 用窗口 bounds 与每块 `SCDisplay.frame` 精确相交判断 |
| Retina 尺寸不匹配 | 使用显示器原生 AVCapture 输出；实机验收要求图像尺寸等于 `CGDisplayPixelsWide/High` |
| 未保护窗口截图变慢 | 未命中策略时完全保留现有 SCK 路径 |
| Swift 6 并发检查失败 | AV worker 限定在私有串行队列，并以完整产品构建验证 |

## 5. 测试与验收

- [x] 修复前运行策略回归测试，确认生产代码尚无兼容策略而失败。
- [x] 单测覆盖：相交的 sharing-none 窗口命中；read-only、透明、非零 layer、屏外窗口不命中。
- [x] 运行全部截图相关测试。
- [x] 运行完整 `swift test`。
- [x] 运行 `swift build -c debug --product Velto` 与 `git diff --check`。
- [x] 覆盖安装并启动新 Velto。
- [x] 激活当前微信窗口，通过 Velto 快捷键启动截图并完成一次选区复制；验证剪贴板图片包含微信。
- [x] 清理测试生成的临时截图（移入废纸篓）。

## 6. 验收标准

1. 微信位于前台时，普通截图冻结画面与最终复制图片都包含微信。
2. `sharingNone` 检测不依赖微信名称或版本。
3. 普通窗口仍使用 ScreenCaptureKit。
4. 主线程不执行 `AVCaptureSession.startRunning()` / `stopRunning()`。
5. 定向测试、完整测试和产品构建全部通过。

## 7. 实施结果

- 完成日期：2026-08-05。
- 已覆盖安装并启动 `/Applications/Velto.app`，版本 `2026.8.4`，签名验证通过。
- 策略测试 2/2、截图相关测试 9/9、完整测试 61/61 通过；产品构建及 `git diff --check` 通过。
- 实机目标为微信窗口 `wid=18656`：`sharing=0`、`layer=0`、`alpha=1`，窗口范围 981×893 点。
- 微信置前后触发实际配置快捷键 `⇧⌘D`，Velto 冻结覆盖层完整显示微信，而非后方窗口。
- 框选微信中央标识并按 Enter 复制：剪贴板 change count 从 550 增至 551，输出 408×350 像素图片，目视确认包含微信标识。
- 验证图片及其临时目录已移入废纸篓，没有保留在 `/tmp`。
