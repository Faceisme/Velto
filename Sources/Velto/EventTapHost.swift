@preconcurrency import CoreFoundation
import CoreGraphics
import Foundation

/// 在专用线程上运行一个事件 tap。回调不走主线程:主线程被 SwiftUI 设置页、文件 IO
/// 卡住时输入照常响应。
///
/// 系统会在回调超时、快速用户切换时禁用 tap,这段时间的事件全丢。host 收到通知后
/// 立刻重新启用,再交给 `onDisabled` 复位各模块的瞬态。
///
/// `@unchecked Sendable`:生命周期字段由 `lock` 保护;回调属性在 `start()` 之前设好,
/// 之后只读。
final class EventTapHost: @unchecked Sendable {
    typealias Handler = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    /// 低频健康检查的决定,见 `healthAction`。
    enum HealthAction: Equatable {
        case keep
        case start
        case restart
        case stop
    }

    /// 系统禁用过 tap,已重新启用。在 tap 线程调用。
    var onDisabled: ((CGEventType) -> Void)?
    /// 线程起来之后、tap 启用之前。在 tap 线程调用。
    var onThreadStart: ((CFRunLoop) -> Void)?
    /// runloop 退出之后。在 tap 线程调用。
    var onThreadExit: (() -> Void)?

    private let name: String
    private let location: CGEventTapLocation
    private let place: CGEventTapPlacement
    private let mask: CGEventMask
    private let handler: Handler

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var threadStopped: DispatchSemaphore?

    init(
        name: String,
        location: CGEventTapLocation,
        place: CGEventTapPlacement,
        mask: CGEventMask,
        handler: @escaping Handler
    ) {
        self.name = name
        self.location = location
        self.place = place
        self.mask = mask
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// 权限不够时返回 false。
    func start() -> Bool {
        lock.lock()
        let alreadyStarted = tap != nil
        lock.unlock()
        guard !alreadyStarted else { return true }

        guard let tap = CGEvent.tapCreate(
            tap: location,
            place: place,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        let ready = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            defer { stopped.signal() }
            guard let runLoop = CFRunLoopGetCurrent() else {
                ready.signal()
                return
            }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            self?.installRunLoop(runLoop)
            self?.onThreadStart?(runLoop)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            self?.onThreadExit?()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive

        lock.lock()
        self.tap = tap
        self.source = source
        self.thread = thread
        threadStopped = stopped
        lock.unlock()

        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// `waitForThread`:等 tap 线程真正退出。在 tap 线程上调用时不等,否则死锁。
    func stop(waitForThread: Bool = false) {
        lock.lock()
        let tap = tap
        let source = source
        let runLoop = runLoop
        let thread = thread
        let stopped = threadStopped
        self.tap = nil
        self.source = nil
        self.runLoop = nil
        self.thread = nil
        threadStopped = nil
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        if waitForThread, let thread, let stopped, Thread.current !== thread {
            stopped.wait()
        }
    }

    /// 把 `work` 排到 tap 线程上。tap 线程没在跑时直接丢弃。
    func perform(_ work: @escaping () -> Void) {
        lock.lock()
        let runLoop = runLoop
        lock.unlock()
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    /// tap 还在但被停用时试着重新启用,返回 tap 是否在正常工作。
    func ensureEnabled() -> Bool {
        lock.lock()
        let tap = tap
        lock.unlock()
        guard let tap else { return false }
        if CGEvent.tapIsEnabled(tap: tap) { return true }
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// 权限撤销后 tap 继续挂着没有意义,甚至会挡住输入,所以停掉,等授权恢复再启动。
    static func healthAction(running: Bool, tapsEnabled: Bool, trusted: Bool) -> HealthAction {
        switch (running, trusted) {
        case (false, false): return .keep
        case (false, true): return .start
        case (true, false): return .stop
        case (true, true): return tapsEnabled ? .keep : .restart
        }
    }

    private func installRunLoop(_ runLoop: CFRunLoop) {
        lock.lock()
        self.runLoop = runLoop
        lock.unlock()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else {
            return handler(type, event)
        }

        lock.lock()
        let tap = tap
        lock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        onDisabled?(type)
        return Unmanaged.passUnretained(event)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        return Unmanaged<EventTapHost>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
}
