import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Synchronization

/// Carbon 全局热键,给事件 tap 做安全输入兜底。
///
/// 安全输入(密码框、终端「安全键盘输入」等)开着时,系统把 keyDown 从所有 event tap 里
/// 滤掉(flagsChanged 不滤),光靠 tap 按了毫无反应、调试日志也一条不记。Carbon 热键不受
/// 影响,而且在 tap 之后才匹配:平时 tap 已吞掉 keyDown,热键不会响,两条路天然互斥
/// (实测;alt-tab 同款)。
///
/// 功能关着时不能注册:tap 放行的组合键会被热键抢走。释放实例即注销。
/// 创建、释放和回调都在主线程。
final class GlobalHotKey: @unchecked Sendable {
    typealias Action = @Sendable () -> Void

    private static let signature: OSType = 0x5645_4C54  // "VELT"
    private static let actions = Mutex<[UInt32: Action]>([:])
    private static let nextID = Mutex<UInt32>(0)
    private static let eventHandlerInstalled = Mutex(false)

    private let id: UInt32
    private let ref: EventHotKeyRef

    /// `modifierFlags` 是 CGEventFlags 的位。Carbon 不支持的组合、或注册失败(比如别的
    /// App 占了)时返回 nil,后者会把状态码交给 `logFailure`。
    init?(
        keyCode: UInt16,
        modifierFlags: UInt64,
        logFailure: (OSStatus) -> Void = { _ in },
        action: @escaping Action
    ) {
        guard let modifiers = Self.carbonModifiers(modifierFlags) else { return nil }
        Self.installEventHandler()

        let id = Self.nextID.withLock { next in
            next &+= 1
            return next
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            logFailure(status)
            return nil
        }

        self.id = id
        self.ref = ref
        Self.actions.withLock { $0[id] = action }
    }

    deinit {
        UnregisterEventHotKey(ref)
        Self.actions.withLock { $0[id] = nil }
    }

    /// CGEventFlags 的修饰位 → Carbon 修饰位。带 Fn 返回 nil:Carbon 没有 Fn 位,注册了
    /// 会误吃不带 Fn 的组合。
    static func carbonModifiers(_ modifierFlags: UInt64) -> UInt32? {
        let flags = CGEventFlags(rawValue: modifierFlags)
        guard !flags.contains(.maskSecondaryFn) else { return nil }
        var modifiers = 0
        if flags.contains(.maskCommand) { modifiers |= cmdKey }
        if flags.contains(.maskShift) { modifiers |= shiftKey }
        if flags.contains(.maskAlternate) { modifiers |= optionKey }
        if flags.contains(.maskControl) { modifiers |= controlKey }
        return UInt32(modifiers)
    }

    private static func installEventHandler() {
        eventHandlerInstalled.withLock { installed in
            guard !installed else { return }
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &spec, nil, nil)
        }
    }

    private static let callback: EventHandlerUPP = { _, event, _ in
        var id = EventHotKeyID()
        guard let event,
              GetEventParameter(
                  event,
                  EventParamName(kEventParamDirectObject),
                  EventParamType(typeEventHotKeyID),
                  nil,
                  MemoryLayout<EventHotKeyID>.size,
                  nil,
                  &id
              ) == noErr,
              id.signature == signature,
              let action = actions.withLock({ $0[id.id] })
        else { return OSStatus(eventNotHandledErr) }

        action()
        return noErr
    }
}
