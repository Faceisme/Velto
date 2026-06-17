import CoreGraphics

struct KeyCodeEntry: Equatable {
    let karabinerName: String
    let displayLabel: String
    let keyCode: UInt16
    let isModifier: Bool
}

enum KeyCodeMap {

    static let modifierKeys: [KeyCodeEntry] = [
        .init(karabinerName: "caps_lock",      displayLabel: "Caps Lock",     keyCode: 57,  isModifier: true),
        .init(karabinerName: "left_control",   displayLabel: "Left Control",  keyCode: 59,  isModifier: true),
        .init(karabinerName: "left_shift",     displayLabel: "Left Shift",    keyCode: 56,  isModifier: true),
        .init(karabinerName: "left_option",    displayLabel: "Left Option",   keyCode: 58,  isModifier: true),
        .init(karabinerName: "left_command",   displayLabel: "Left Command",  keyCode: 55,  isModifier: true),
        .init(karabinerName: "right_control",  displayLabel: "Right Control", keyCode: 62,  isModifier: true),
        .init(karabinerName: "right_shift",    displayLabel: "Right Shift",   keyCode: 60,  isModifier: true),
        .init(karabinerName: "right_option",   displayLabel: "Right Option",  keyCode: 61,  isModifier: true),
        .init(karabinerName: "right_command",  displayLabel: "Right Command", keyCode: 54,  isModifier: true),
        .init(karabinerName: "fn",             displayLabel: "Fn / Globe",    keyCode: 63,  isModifier: true),
    ]

    static let functionKeys: [KeyCodeEntry] = [
        .init(karabinerName: "f1",  displayLabel: "F1",  keyCode: 122, isModifier: false),
        .init(karabinerName: "f2",  displayLabel: "F2",  keyCode: 120, isModifier: false),
        .init(karabinerName: "f3",  displayLabel: "F3",  keyCode: 99,  isModifier: false),
        .init(karabinerName: "f4",  displayLabel: "F4",  keyCode: 118, isModifier: false),
        .init(karabinerName: "f5",  displayLabel: "F5",  keyCode: 96,  isModifier: false),
        .init(karabinerName: "f6",  displayLabel: "F6",  keyCode: 97,  isModifier: false),
        .init(karabinerName: "f7",  displayLabel: "F7",  keyCode: 98,  isModifier: false),
        .init(karabinerName: "f8",  displayLabel: "F8",  keyCode: 100, isModifier: false),
        .init(karabinerName: "f9",  displayLabel: "F9",  keyCode: 101, isModifier: false),
        .init(karabinerName: "f10", displayLabel: "F10", keyCode: 109, isModifier: false),
        .init(karabinerName: "f11", displayLabel: "F11", keyCode: 103, isModifier: false),
        .init(karabinerName: "f12", displayLabel: "F12", keyCode: 111, isModifier: false),
        .init(karabinerName: "f13", displayLabel: "F13", keyCode: 105, isModifier: false),
        .init(karabinerName: "f14", displayLabel: "F14", keyCode: 107, isModifier: false),
        .init(karabinerName: "f15", displayLabel: "F15", keyCode: 113, isModifier: false),
        .init(karabinerName: "f16", displayLabel: "F16", keyCode: 106, isModifier: false),
        .init(karabinerName: "f17", displayLabel: "F17", keyCode: 64,  isModifier: false),
        .init(karabinerName: "f18", displayLabel: "F18", keyCode: 79,  isModifier: false),
        .init(karabinerName: "f19", displayLabel: "F19", keyCode: 80,  isModifier: false),
        .init(karabinerName: "f20", displayLabel: "F20", keyCode: 90,  isModifier: false),
    ]

    static let letterKeys: [KeyCodeEntry] = [
        .init(karabinerName: "a", displayLabel: "A", keyCode: 0,  isModifier: false),
        .init(karabinerName: "b", displayLabel: "B", keyCode: 11, isModifier: false),
        .init(karabinerName: "c", displayLabel: "C", keyCode: 8,  isModifier: false),
        .init(karabinerName: "d", displayLabel: "D", keyCode: 2,  isModifier: false),
        .init(karabinerName: "e", displayLabel: "E", keyCode: 14, isModifier: false),
        .init(karabinerName: "f", displayLabel: "F", keyCode: 3,  isModifier: false),
        .init(karabinerName: "g", displayLabel: "G", keyCode: 5,  isModifier: false),
        .init(karabinerName: "h", displayLabel: "H", keyCode: 4,  isModifier: false),
        .init(karabinerName: "i", displayLabel: "I", keyCode: 34, isModifier: false),
        .init(karabinerName: "j", displayLabel: "J", keyCode: 38, isModifier: false),
        .init(karabinerName: "k", displayLabel: "K", keyCode: 40, isModifier: false),
        .init(karabinerName: "l", displayLabel: "L", keyCode: 37, isModifier: false),
        .init(karabinerName: "m", displayLabel: "M", keyCode: 46, isModifier: false),
        .init(karabinerName: "n", displayLabel: "N", keyCode: 45, isModifier: false),
        .init(karabinerName: "o", displayLabel: "O", keyCode: 31, isModifier: false),
        .init(karabinerName: "p", displayLabel: "P", keyCode: 35, isModifier: false),
        .init(karabinerName: "q", displayLabel: "Q", keyCode: 12, isModifier: false),
        .init(karabinerName: "r", displayLabel: "R", keyCode: 15, isModifier: false),
        .init(karabinerName: "s", displayLabel: "S", keyCode: 1,  isModifier: false),
        .init(karabinerName: "t", displayLabel: "T", keyCode: 17, isModifier: false),
        .init(karabinerName: "u", displayLabel: "U", keyCode: 32, isModifier: false),
        .init(karabinerName: "v", displayLabel: "V", keyCode: 9,  isModifier: false),
        .init(karabinerName: "w", displayLabel: "W", keyCode: 13, isModifier: false),
        .init(karabinerName: "x", displayLabel: "X", keyCode: 7,  isModifier: false),
        .init(karabinerName: "y", displayLabel: "Y", keyCode: 16, isModifier: false),
        .init(karabinerName: "z", displayLabel: "Z", keyCode: 6,  isModifier: false),
    ]

    static let numberKeys: [KeyCodeEntry] = [
        .init(karabinerName: "1", displayLabel: "1", keyCode: 18, isModifier: false),
        .init(karabinerName: "2", displayLabel: "2", keyCode: 19, isModifier: false),
        .init(karabinerName: "3", displayLabel: "3", keyCode: 20, isModifier: false),
        .init(karabinerName: "4", displayLabel: "4", keyCode: 21, isModifier: false),
        .init(karabinerName: "5", displayLabel: "5", keyCode: 23, isModifier: false),
        .init(karabinerName: "6", displayLabel: "6", keyCode: 22, isModifier: false),
        .init(karabinerName: "7", displayLabel: "7", keyCode: 26, isModifier: false),
        .init(karabinerName: "8", displayLabel: "8", keyCode: 28, isModifier: false),
        .init(karabinerName: "9", displayLabel: "9", keyCode: 25, isModifier: false),
        .init(karabinerName: "0", displayLabel: "0", keyCode: 29, isModifier: false),
    ]

    static let arrowKeys: [KeyCodeEntry] = [
        .init(karabinerName: "left_arrow",  displayLabel: "←",  keyCode: 123, isModifier: false),
        .init(karabinerName: "right_arrow", displayLabel: "→",  keyCode: 124, isModifier: false),
        .init(karabinerName: "down_arrow",  displayLabel: "↓",  keyCode: 125, isModifier: false),
        .init(karabinerName: "up_arrow",    displayLabel: "↑",  keyCode: 126, isModifier: false),
    ]

    static let navigationKeys: [KeyCodeEntry] = [
        .init(karabinerName: "return_or_enter",   displayLabel: "Return",   keyCode: 36,  isModifier: false),
        .init(karabinerName: "escape",             displayLabel: "Escape",   keyCode: 53,  isModifier: false),
        .init(karabinerName: "delete_or_backspace",displayLabel: "⌫",       keyCode: 51,  isModifier: false),
        .init(karabinerName: "delete_forward",     displayLabel: "⌦",       keyCode: 117, isModifier: false),
        .init(karabinerName: "tab",                displayLabel: "Tab",      keyCode: 48,  isModifier: false),
        .init(karabinerName: "spacebar",           displayLabel: "Space",    keyCode: 49,  isModifier: false),
        .init(karabinerName: "home",               displayLabel: "Home",     keyCode: 115, isModifier: false),
        .init(karabinerName: "end",                displayLabel: "End",      keyCode: 119, isModifier: false),
        .init(karabinerName: "page_up",            displayLabel: "Page Up",  keyCode: 116, isModifier: false),
        .init(karabinerName: "page_down",          displayLabel: "Page Down",keyCode: 121, isModifier: false),
    ]

    static let symbolKeys: [KeyCodeEntry] = [
        .init(karabinerName: "hyphen",                    displayLabel: "-",  keyCode: 27, isModifier: false),
        .init(karabinerName: "equal_sign",                displayLabel: "=",  keyCode: 24, isModifier: false),
        .init(karabinerName: "open_bracket",              displayLabel: "[",  keyCode: 33, isModifier: false),
        .init(karabinerName: "close_bracket",             displayLabel: "]",  keyCode: 30, isModifier: false),
        .init(karabinerName: "backslash",                 displayLabel: "\\", keyCode: 42, isModifier: false),
        .init(karabinerName: "semicolon",                 displayLabel: ";",  keyCode: 41, isModifier: false),
        .init(karabinerName: "quote",                     displayLabel: "'",  keyCode: 39, isModifier: false),
        .init(karabinerName: "grave_accent_and_tilde",    displayLabel: "`",  keyCode: 50, isModifier: false),
        .init(karabinerName: "comma",                     displayLabel: ",",  keyCode: 43, isModifier: false),
        .init(karabinerName: "period",                    displayLabel: ".",  keyCode: 47, isModifier: false),
        .init(karabinerName: "slash",                     displayLabel: "/",  keyCode: 44, isModifier: false),
    ]

    // 禁用键（to 侧专用）
    static let vkNone = KeyCodeEntry(
        karabinerName: "vk_none", displayLabel: "禁用此键", keyCode: 0xFFFF, isModifier: false)

    static let allEntries: [KeyCodeEntry] =
        modifierKeys + functionKeys + letterKeys + numberKeys +
        arrowKeys + navigationKeys + symbolKeys

    // MARK: - 查找表（懒加载）

    static let byKarabinerName: [String: KeyCodeEntry] = {
        var d: [String: KeyCodeEntry] = [:]
        for e in allEntries { d[e.karabinerName] = e }
        d[vkNone.karabinerName] = vkNone
        return d
    }()

    static let byKeyCode: [UInt16: KeyCodeEntry] = {
        var d: [UInt16: KeyCodeEntry] = [:]
        for e in allEntries { d[e.keyCode] = e }
        return d
    }()

    // MARK: - UI Picker 分组

    static let pickerSections: [(title: String, entries: [KeyCodeEntry])] = [
        ("修饰键",   modifierKeys),
        ("功能键",   functionKeys),
        ("字母键",   letterKeys),
        ("数字键",   numberKeys),
        ("方向键",   arrowKeys),
        ("导航/控制", navigationKeys),
        ("符号",     symbolKeys),
    ]

    // to 侧 Picker 多一个"禁用"选项
    static let pickerSectionsForTo: [(title: String, entries: [KeyCodeEntry])] = [
        ("禁用",     [vkNone]),
    ] + pickerSections
}
