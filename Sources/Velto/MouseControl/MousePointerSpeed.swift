import CoreFoundation
import Foundation
import IOKit.hidsystem

/// 鼠标指针移动速度 —— 即系统「鼠标 → 跟踪速度」背后的 HIDMouseAcceleration。
///
/// 系统设置的滑块只有 0~3 的十档;`defaults write -g com.apple.mouse.scaling` 能写更大值,
/// 但要注销重登才生效。这里两步一起做:
///   - 经 IOHIDEventSystemClient 写系统级 HIDMouseAcceleration:立即生效,hidd 会下发到
///     所有鼠标服务(含之后新接入的),但它不落盘,重启即丢;
///   - 同时写全局偏好 com.apple.mouse.scaling:登录时系统按它恢复,重启后仍保持。
/// 数值属于系统设置本身,不进 Velto 偏好 / 配置导出,不受鼠标控制总开关影响,退出 Velto 也照样生效。
@MainActor
enum MousePointerSpeed {
    static let range: ClosedRange<Double> = 0.0...10.0
    static let step = 0.1
    /// HID 属性和偏好都取不到时的兜底:macOS 默认跟踪速度 0.6875,按一位小数取整。
    private static let fallbackSpeed = 0.7

    private static let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private static let accelerationKey = kIOHIDMouseAccelerationType as CFString
    private static let scalingPreferenceKey = "com.apple.mouse.scaling" as CFString

    /// 当前生效值:优先读 HID 系统级属性(IOFixed 16.16 定点数),取不到再退回全局偏好。
    static func current() -> Double {
        if let fixed = IOHIDEventSystemClientCopyProperty(client, accelerationKey) as? NSNumber {
            return quantized(fixed.doubleValue / 65536)
        }
        // 偏好可能是 `defaults write` 不带 -float 写成的字符串,两种都认。
        let stored = CFPreferencesCopyValue(
            scalingPreferenceKey,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        if let number = stored as? NSNumber {
            return quantized(number.doubleValue)
        }
        if let text = stored as? String, let value = Double(text) {
            return quantized(value)
        }
        return fallbackSpeed
    }

    static func apply(_ value: Double) {
        let speed = quantized(min(max(value, range.lowerBound), range.upperBound))
        IOHIDEventSystemClientSetProperty(
            client,
            accelerationKey,
            NSNumber(value: Int((speed * 65536).rounded()))
        )
        CFPreferencesSetValue(
            scalingPreferenceKey,
            NSNumber(value: speed),
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// 按一位小数取整。用 ×10 再 ÷10 而不是 ×0.1:后者会带出 7.6000000000000005 这类尾差。
    static func quantized(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
