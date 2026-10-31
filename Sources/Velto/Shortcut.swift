import CoreGraphics
import Foundation

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: UInt64
    var displayName: String

    /// 是否含至少一个「真」修饰键(⌘ / ⌃ / ⌥;⇧ 单独不算)。用于校验全局触发键
    /// 不被裸键占用 —— 裸键作为切换器触发键会全局吞普通输入、且无 modifier 松开可确认。
    var hasRealModifier: Bool {
        let real = UInt64(
            CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskControl.rawValue
                | CGEventFlags.maskAlternate.rawValue
        )
        return (modifierFlags & real) != 0
    }
}

/// 鼠标按钮触发:按下这个按钮(+ 修饰键)即执行动作 —— 手势发快捷键、窗口管理最大化窗口。
/// 按钮号同 CGEvent 的 `mouseEventButtonNumber`:2 中键、3 后退侧键、4 前进侧键、5+ 其它
/// 按钮。左右键不可用 —— 左键是日常点击,右键归画手势。
struct MouseButtonTrigger: Codable, Hashable, Sendable {
    var button: Int
    /// 修饰键,`ModifierFormatter.normalizedRawValue` 规整过,判定时要求完全相等。
    var modifierFlags: UInt64

    /// 可用作触发的最小按钮号(中键)。
    static let minimumButton = 2

    var buttonName: String {
        switch button {
        case 2: "中键"
        case 3: "后退侧键"
        case 4: "前进侧键"
        default: "按钮 \(button + 1)"
        }
    }

    /// 键帽式展示:修饰键各一枚 + 按钮名(修饰键顺序同 `Shortcut.kbdKeys`)。
    var kbdKeys: [String] {
        let flags = CGEventFlags(rawValue: CGEventFlags.RawValue(modifierFlags))
        var keys: [String] = []
        if flags.contains(.maskControl) { keys.append("⌃") }
        if flags.contains(.maskAlternate) { keys.append("⌥") }
        if flags.contains(.maskShift) { keys.append("⇧") }
        if flags.contains(.maskCommand) { keys.append("⌘") }
        if flags.contains(.maskSecondaryFn) { keys.append("Fn") }
        return keys + [buttonName]
    }

    var displayName: String {
        kbdKeys.joined()
    }
}

enum VirtualKeyCode {
    static let escape: UInt16 = 53
    static let equal: UInt16 = 24
    static let minus: UInt16 = 27
    static let w: UInt16 = 13
    static let t: UInt16 = 17
    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
    static let leftBracket: UInt16 = 33
    static let rightBracket: UInt16 = 30
}

extension CGEventFlags {
    var storedRawValue: UInt64 {
        UInt64(rawValue)
    }
}
