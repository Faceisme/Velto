import Cocoa
import ScreenCaptureKit
import Synchronization

/// 用 ScreenCaptureKit 抓窗口缩略图。
///
/// 性能优化(对照 alt-tab WindowCaptureScreenshots):
///   - **5 路并发** —— TaskGroup 同时跑 5 个 SCK 调用
///   - **SCWindow 缓存** —— SCShareableContent IPC 5 秒 TTL
///   - **`captureSampleBuffer` + CVPixelBuffer** —— IOSurface 零拷贝路径,
///     CALayer.contents 直接接 IOSurfaceRef,跳过 CGImage 桥接
///   - **CGSHWCaptureWindowList 兜底** —— 见 captureMinimizedFallback,
///     SCK 抓不到的最小化窗口走这条
///
/// 静默降级 —— 权限缺失 / SCK 失败时不报错,UI 端 thumbnail==nil → 退回大图标。
@MainActor
final class SwitcherThumbnails {
    static let shared = SwitcherThumbnails()

    /// 缩略图最大边长(像素)。tile 显示约 190px,256 源足够。
    private static let maxDimension: CGFloat = 256
    /// 并发抓取上限。M1/M2 Pro 8 个性能核 —— 8 路是 alt-tab 同款选择,
    /// 用满性能核但不挤压 efficiency 核。
    private static let maxConcurrent = 8

    private static let cache = SCWindowCache()

    private init() {}

    /// 给一组窗口异步抓缩略图。每抓到一张就调一次 `onThumbnailReady`,在主线程
    /// 回到 caller。`completion` 在所有窗口都跑完后回调(也回主线程)。
    ///
    /// **重要**:已有 `window.thumbnail` 的窗口会被跳过 —— 我们把 8 个并发槽位
    /// 都留给真正没图的窗口(典型场景:新开 app、Space 切换、长时间没召唤过
    /// 切换器)。已有图的窗口已经被预热路径覆盖过了,session 中不需要立刻刷新。
    func captureThumbnails(
        for windows: [SwitcherWindow],
        onThumbnailReady: @escaping @MainActor (SwitcherWindow, CALayerContents) -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        let needsCapture = windows.filter { $0.thumbnail == nil }
        guard !needsCapture.isEmpty else {
            // 所有窗口都有缓存图了 —— 直接完事,session 全程不抓 SCK
            completion()
            return
        }
        let widMap: [CGWindowID: SwitcherWindow] = Dictionary(
            uniqueKeysWithValues: needsCapture.map { ($0.cgWindowId, $0) }
        )
        Task.detached(priority: .userInitiated) {
            await Self.runCaptureSession(
                widMap: widMap,
                onThumbnailReady: onThumbnailReady,
                completion: completion
            )
        }
    }

    /// 预热节流间隔:同一窗口该时间内不重抓。
    /// focus 变化每次都触发预热,频繁切窗时等于持续的后台 SCK 抓图(CPU/GPU/功耗);
    /// 而切换器对几秒内的陈旧缩略图毫无感知 —— 召唤后没图的窗口照常异步刷新。
    /// 新窗口首抓无历史记录,不受节流影响。
    private nonisolated static let warmThrottleInterval: CFAbsoluteTime = 5
    /// wid → 上次预热时刻。warmThumbnail 可被任意线程调,用 Mutex 保护。
    private nonisolated static let lastWarmAt = Mutex<[CGWindowID: CFAbsoluteTime]>([:])

    /// 单窗口预热抓取入口 —— 供 WindowList 在窗口创建 / focus 变化时调用。
    /// 跟主路径的不同:只抓一个,结果直接存进 window.thumbnail。
    /// 异步,不阻塞调用方。同窗口 `warmThrottleInterval` 内的重复预热直接丢弃。
    ///
    /// 优先级走 `.userInitiated` 而不是 `.background` —— 后者会被 GCD 排到所有
    /// 用户活动后面,新开 app 后立刻 Cmd+Tab 会看到"先 fallback 后图"的过程。
    /// userInitiated 让预热跟用户切换 app 同级,体感即时。
    nonisolated func warmThumbnail(for window: SwitcherWindow) {
        let wid = window.cgWindowId
        let now = CFAbsoluteTimeGetCurrent()
        let throttled = Self.lastWarmAt.withLock { table in
            if let last = table[wid], now - last < Self.warmThrottleInterval {
                return true
            }
            table[wid] = now
            return false
        }
        if throttled { return }
        let widBox = SwitcherWindowBox(window: window)
        Task.detached(priority: .userInitiated) {
            await Self.warmOne(box: widBox)
        }
    }

    // MARK: - 后台捕获 session

    private static func runCaptureSession(
        widMap: [CGWindowID: SwitcherWindow],
        onThumbnailReady: @escaping @MainActor (SwitcherWindow, CALayerContents) -> Void,
        completion: @escaping @MainActor () -> Void
    ) async {
        let scBoxes = await cache.boxes(forWids: Array(widMap.keys))
        guard !scBoxes.isEmpty else {
            await MainActor.run { completion() }
            return
        }

        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for (wid, box) in scBoxes {
                guard let switcherWindow = widMap[wid] else { continue }
                let switcherWindowBox = SwitcherWindowBox(window: switcherWindow)
                group.addTask {
                    if let contents = await captureOne(
                        scBox: box,
                        allowProtectedDisplayCapture: false
                    ) {
                        await MainActor.run {
                            onThumbnailReady(switcherWindowBox.window, contents)
                        }
                    }
                }
                inFlight += 1
                if inFlight >= maxConcurrent {
                    await group.next()
                    inFlight -= 1
                }
            }
            await group.waitForAll()
        }
        await MainActor.run { completion() }
    }

    private static func warmOne(box: SwitcherWindowBox) async {
        let wid = await MainActor.run { box.window.cgWindowId }
        let scBoxes = await cache.boxes(forWids: [wid])
        guard let scBox = scBoxes[wid] else { return }
        guard let contents = await captureOne(
            scBox: scBox,
            allowProtectedDisplayCapture: true
        ) else { return }
        await MainActor.run {
            box.window.thumbnail = contents
        }
    }

    /// 真正干活的 SCK 调用。返回 CALayerContents.pixelBuffer —— IOSurface 零拷贝路径。
    /// 抄自 alt-tab `WindowCaptureScreenshots.oneTimeCapture` + `CMSampleBuffer.pixelBuffer()`。
    /// 失败时先降级到 CGSHWCaptureWindowList 兜底最小化窗口；如果目标是当前
    /// 屏幕上可见的 sharingNone 窗口，再复用截图模块的 AV 整屏捕获并裁出窗口。
    private static func captureOne(
        scBox: SCWindowBox,
        allowProtectedDisplayCapture: Bool
    ) async -> CALayerContents? {
        let scWindow = scBox.scWindow
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let scale: CGFloat = 2.0
        let maxPixels = Self.maxDimension * scale
        let sourceWidth = max(1, scWindow.frame.width * scale)
        let sourceHeight = max(1, scWindow.frame.height * scale)
        let thumbnailScale = min(1, maxPixels / max(sourceWidth, sourceHeight))
        config.width = max(1, Int((sourceWidth * thumbnailScale).rounded()))
        config.height = max(1, Int((sourceHeight * thumbnailScale).rounded()))
        config.showsCursor = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        do {
            let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(
                contentFilter: filter,
                configuration: config
            )
            if let pixelBuffer = sampleBuffer.thumbnailPixelBuffer() {
                return .pixelBuffer(pixelBuffer)
            }
            return await captureFallback(
                for: scWindow,
                allowProtectedDisplayCapture: allowProtectedDisplayCapture
            )
        } catch {
            return await captureFallback(
                for: scWindow,
                allowProtectedDisplayCapture: allowProtectedDisplayCapture
            )
        }
    }

    private static func captureFallback(
        for window: SCWindow,
        allowProtectedDisplayCapture: Bool
    ) async -> CALayerContents? {
        if let privateCapture = captureViaPrivateApi(wid: window.windowID) {
            return privateCapture
        }
        guard allowProtectedDisplayCapture else { return nil }
        return await captureProtectedWindowViaDisplay(wid: window.windowID)
    }

    /// 单窗口 API 会把 sharingNone 窗口返回成黑帧。仅在窗口此刻真的可见时，
    /// 抓它所在显示器并裁出可见窗口区域；其他 Space / 已关闭窗口不能这样做，
    /// 否则会误把后方内容当成窗口预览。
    private static func captureProtectedWindowViaDisplay(wid: CGWindowID) async -> CALayerContents? {
        guard let target = protectedWindowTarget(wid: wid) else { return nil }
        guard await MainActor.run(body: { !SwitcherSession.isActive }) else { return nil }
        guard let image = try? await ScreenshotCapturer.captureCompatibilityDisplayImage(
            displayID: target.displayID,
            cropRect: target.cropRect,
            scaleFactor: target.scaleFactor
        ) else { return nil }
        guard await MainActor.run(body: { !SwitcherSession.isActive }) else { return nil }
        return .cgImage(image)
    }

    private static func protectedWindowTarget(wid: CGWindowID) -> ProtectedWindowTarget? {
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]] ?? []
        guard let row = rows.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == wid
        }),
        (row[kCGWindowSharingState as String] as? NSNumber)?.uint32Value
            == CGWindowSharingType.none.rawValue,
        (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
        (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
        let boundsDictionary = row[kCGWindowBounds as String] as? NSDictionary,
        let windowFrame = CGRect(dictionaryRepresentation: boundsDictionary),
        !windowFrame.isEmpty
        else { return nil }

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else { return nil }
        return displayIDs.prefix(Int(count)).compactMap { displayID -> ProtectedWindowTarget? in
            let displayFrame = CGDisplayBounds(displayID)
            let intersection = windowFrame.intersection(displayFrame)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            guard let cropRect = compatibilityAVCropRect(
                windowFrame: windowFrame,
                displayFrame: displayFrame
            ) else { return nil }
            let nativeScale = CGDisplayCopyDisplayMode(displayID).map {
                CGFloat($0.pixelWidth) / displayFrame.width
            } ?? 1
            let maxPixels = Self.maxDimension * 2
            let scaleFactor = min(
                1,
                maxPixels / (max(cropRect.width, cropRect.height) * nativeScale)
            )
            return ProtectedWindowTarget(
                displayID: displayID,
                cropRect: cropRect,
                scaleFactor: scaleFactor,
                visibleArea: intersection.width * intersection.height
            )
        }.max { $0.visibleArea < $1.visibleArea }
    }

    static func compatibilityAVCropRect(
        windowFrame: CGRect,
        displayFrame: CGRect
    ) -> CGRect? {
        let visible = windowFrame.intersection(displayFrame)
        guard !visible.isNull, !visible.isEmpty, displayFrame.width > 0, displayFrame.height > 0 else {
            return nil
        }
        return CGRect(
            x: visible.minX - displayFrame.minX,
            y: displayFrame.maxY - visible.maxY,
            width: visible.width,
            height: visible.height
        )
    }

    /// `CGSHWCaptureWindowList` 私有 API 兜底。
    /// **唯一**能抓最小化窗口最后一帧的方法。返回 `.cgImage`(CG 路径,不是 IOSurface
    /// 零拷贝,但比"没图"好太多)。
    /// 抄自 alt-tab `WindowCaptureScreenshotsPrivateApi.oneTimeCapture`。
    private static func captureViaPrivateApi(wid: CGWindowID) -> CALayerContents? {
        var widCopy = wid
        // 选项:忽略系统全局裁剪 + 最高分辨率 + 全尺寸(应对 Stage Manager)
        let options: CGSWindowCaptureOptions = [.ignoreGlobalClipShape, .bestResolution, .fullSize]
        let resultRaw = CGSHWCaptureWindowList(CGS_CONNECTION, &widCopy, 1, options)
        let array = resultRaw.takeRetainedValue() as? [CGImage] ?? []
        guard let cgImage = array.first else { return nil }
        return .cgImage(cgImage)
    }
}

private struct ProtectedWindowTarget {
    let displayID: CGDirectDisplayID
    let cropRect: CGRect
    let scaleFactor: CGFloat
    let visibleArea: CGFloat
}

// MARK: - CMSampleBuffer 提取 PixelBuffer

extension CMSampleBuffer {
    /// 抄自 alt-tab `CMSampleBuffer.pixelBuffer()` —— 看 SampleBuffer 的 frame status
    /// 确认是真新帧(complete / started)才返回 imageBuffer,避免拿到 stale 帧。
    /// 命名加 `thumbnail` 前缀避免跟 Apple 未来可能加的 system extension 冲突。
    func thumbnailPixelBuffer() -> CVPixelBuffer? {
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attachments = attachmentsArray.first,
           let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRawValue),
           status == .complete || status == .started
        {
            return imageBuffer
        }
        return nil
    }
}

// MARK: - SCWindow 缓存

/// SCShareableContent 单次 IPC ~100ms。缓存 5 秒,避免高频 Cmd+Tab 重复调用。
private actor SCWindowCache {
    private var lastRefreshedAt: TimeInterval = 0
    private var cachedBoxes: [CGWindowID: SCWindowBox] = [:]
    private let ttl: TimeInterval = 5.0

    func boxes(forWids wids: [CGWindowID]) async -> [CGWindowID: SCWindowBox] {
        let now = CFAbsoluteTimeGetCurrent()
        let stale = (now - lastRefreshedAt) > ttl
        let allCached = wids.allSatisfy { cachedBoxes[$0] != nil }
        if !stale && allCached {
            return cachedBoxes.filter { wids.contains($0.key) }
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        ) else {
            return cachedBoxes.filter { wids.contains($0.key) }
        }
        var fresh = [CGWindowID: SCWindowBox]()
        for sc in content.windows {
            fresh[sc.windowID] = SCWindowBox(scWindow: sc)
        }
        cachedBoxes = fresh
        lastRefreshedAt = now
        return cachedBoxes.filter { wids.contains($0.key) }
    }
}

// MARK: - 跨线程容器

private struct SCWindowBox: @unchecked Sendable {
    let scWindow: SCWindow
}

private struct SwitcherWindowBox: @unchecked Sendable {
    let window: SwitcherWindow
}
