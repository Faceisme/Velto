import Foundation
import IOKit
import IOKit.hidsystem

/// Caps Lock 物理状态控制 —— 通过 IOHIDSystem 参数连接把 caps 灯按回灭灯。
///
/// 为什么需要它:event tap 消费掉 caps 的 `flagsChanged` 并不能阻止 HID 层把
/// caps 物理 toggle 翻过去(灯照亮)。要把 Caps Lock 真正当成普通映射源,必须在
/// 每次它亮灯的瞬间用 IOKit 把状态按回关,这样它就不再当 caps 用。
///
/// 线程约束:静态状态(连接句柄)只在 tap 线程经 KeyRemapController 访问,串行,
/// 无需加锁;`nonisolated(unsafe)` 是经 tap 线程串行化保证的安全例外。
enum KeyRemapCapsLock {
  private nonisolated(unsafe) static var connect: io_connect_t = 0
  private nonisolated(unsafe) static var didOpen = false

  /// 把 Caps Lock 物理状态强制设为关(灭灯)。打不开连接时静默失败(返回 false)。
  @discardableResult
  static func forceOff() -> Bool {
    guard let c = handle() else { return false }
    let r = IOHIDSetModifierLockState(c, Int32(kIOHIDCapsLockState), false)
    if r != KERN_SUCCESS {
      KeyRemapDebugLog.log("KeyRemapCapsLock: IOHIDSetModifierLockState 失败 r=\(r)")
      return false
    }
    return true
  }

  /// 懒打开 IOHIDSystem 的参数连接,只开一次。失败后置 didOpen 不再重试。
  private static func handle() -> io_connect_t? {
    if didOpen { return connect != 0 ? connect : nil }
    didOpen = true
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else {
      KeyRemapDebugLog.log("KeyRemapCapsLock: 找不到 IOHIDSystem 服务,无法关闭 caps 物理 toggle")
      return nil
    }
    defer { IOObjectRelease(service) }
    var c: io_connect_t = 0
    let r = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &c)
    guard r == KERN_SUCCESS else {
      KeyRemapDebugLog.log("KeyRemapCapsLock: IOServiceOpen 失败 r=\(r)")
      return nil
    }
    connect = c
    KeyRemapDebugLog.log("KeyRemapCapsLock: IOHIDSystem 连接已建立")
    return connect
  }
}
