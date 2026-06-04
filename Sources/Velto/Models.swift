import AppKit
import CoreGraphics
import Foundation
import Observation

struct StrokePoint: Codable, Hashable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

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

struct GestureCommand: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var templates: [[StrokePoint]]
    var shortcut: Shortcut?

    init(id: UUID = UUID(), name: String, templates: [[StrokePoint]], shortcut: Shortcut?) {
        self.id = id
        self.name = name
        self.templates = templates
        self.shortcut = shortcut
    }
}

enum GestureTargetPolicy: String, Codable, Equatable {
    case windowUnderPointer
    case activeWindow
}

struct AppPreferences: Codable, Equatable {
    var gesturesEnabled: Bool
    /// 窗口管理(拖窗 / 内容缩放 / 窗口快捷键)总开关。关掉只停这三项,不影响手势 /
    /// 鼠标控制。带默认值,旧配置(无此字段)解码时按 `decodeIfPresent` 回退到 true。
    var windowManagementEnabled: Bool = true
    var showTrail: Bool
    var showMenuBarIcon: Bool
    var recognitionThreshold: Double
    var gestureTimeoutSeconds: Double
    /// 开启后,手势进行中"来回乱划几下"会立即判为无效并取消,无需等待超时。
    var scribbleCancelEnabled: Bool
    /// 调试模式总开关(默认关)。开启后诊断日志(如手势轨迹)会写入
    /// ~/Library/Logs/Velto/,便于排查与迭代;关闭时几乎零开销。
    var debugLoggingEnabled: Bool
    var gestureTargetPolicy: GestureTargetPolicy
    var windowMoveModifierFlags: UInt64
    var windowResizeModifierFlags: UInt64
    var contentZoomModifierFlags: UInt64
    var windowMaximizeShortcut: Shortcut?
    var mouseControl: MouseControlPreferences
    /// 窗口切换器的全部配置 —— 子结构定义在 Switcher/SwitcherPreferences.swift。
    /// 嵌进来跟手势/窗口管理共享一份 JSON 持久化。
    var switcher: SwitcherPreferences
    /// 输入法自动切换的全部配置 —— 子结构定义在
    /// InputSourceSwitch/InputSourceSwitchPreferences.swift。
    var inputSourceSwitch: InputSourceSwitchPreferences

    init(
        gesturesEnabled: Bool,
        showTrail: Bool,
        showMenuBarIcon: Bool,
        recognitionThreshold: Double,
        gestureTimeoutSeconds: Double,
        scribbleCancelEnabled: Bool,
        debugLoggingEnabled: Bool,
        gestureTargetPolicy: GestureTargetPolicy,
        windowMoveModifierFlags: UInt64,
        windowResizeModifierFlags: UInt64,
        contentZoomModifierFlags: UInt64,
        windowMaximizeShortcut: Shortcut?,
        mouseControl: MouseControlPreferences,
        switcher: SwitcherPreferences,
        inputSourceSwitch: InputSourceSwitchPreferences
    ) {
        self.gesturesEnabled = gesturesEnabled
        self.showTrail = showTrail
        self.showMenuBarIcon = showMenuBarIcon
        self.recognitionThreshold = recognitionThreshold
        self.gestureTimeoutSeconds = gestureTimeoutSeconds
        self.scribbleCancelEnabled = scribbleCancelEnabled
        self.debugLoggingEnabled = debugLoggingEnabled
        self.gestureTargetPolicy = gestureTargetPolicy
        self.windowMoveModifierFlags = windowMoveModifierFlags
        self.windowResizeModifierFlags = windowResizeModifierFlags
        self.contentZoomModifierFlags = contentZoomModifierFlags
        self.windowMaximizeShortcut = windowMaximizeShortcut
        self.mouseControl = mouseControl
        self.switcher = switcher
        self.inputSourceSwitch = inputSourceSwitch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gesturesEnabled = try container.decodeIfPresent(Bool.self, forKey: .gesturesEnabled) ?? Self.defaults.gesturesEnabled
        windowManagementEnabled = try container.decodeIfPresent(Bool.self, forKey: .windowManagementEnabled) ?? Self.defaults.windowManagementEnabled
        showTrail = try container.decodeIfPresent(Bool.self, forKey: .showTrail) ?? Self.defaults.showTrail
        showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? Self.defaults.showMenuBarIcon
        recognitionThreshold = try container.decodeIfPresent(Double.self, forKey: .recognitionThreshold) ?? Self.defaults.recognitionThreshold
        gestureTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .gestureTimeoutSeconds) ?? Self.defaults.gestureTimeoutSeconds
        scribbleCancelEnabled = try container.decodeIfPresent(Bool.self, forKey: .scribbleCancelEnabled) ?? Self.defaults.scribbleCancelEnabled
        debugLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .debugLoggingEnabled) ?? Self.defaults.debugLoggingEnabled
        gestureTargetPolicy = try container.decodeIfPresent(GestureTargetPolicy.self, forKey: .gestureTargetPolicy) ?? Self.defaults.gestureTargetPolicy
        windowMoveModifierFlags = try container.decodeIfPresent(UInt64.self, forKey: .windowMoveModifierFlags) ?? Self.defaults.windowMoveModifierFlags
        windowResizeModifierFlags = try container.decodeIfPresent(UInt64.self, forKey: .windowResizeModifierFlags) ?? Self.defaults.windowResizeModifierFlags
        contentZoomModifierFlags = try container.decodeIfPresent(UInt64.self, forKey: .contentZoomModifierFlags) ?? Self.defaults.contentZoomModifierFlags
        windowMaximizeShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .windowMaximizeShortcut) ?? Self.defaults.windowMaximizeShortcut
        mouseControl = try container.decodeIfPresent(MouseControlPreferences.self, forKey: .mouseControl) ?? Self.defaults.mouseControl
        switcher = try container.decodeIfPresent(SwitcherPreferences.self, forKey: .switcher) ?? Self.defaults.switcher
        inputSourceSwitch = try container.decodeIfPresent(InputSourceSwitchPreferences.self, forKey: .inputSourceSwitch) ?? Self.defaults.inputSourceSwitch
    }

    static let defaults = AppPreferences(
        gesturesEnabled: true,
        showTrail: true,
        showMenuBarIcon: true,
        recognitionThreshold: 0.34,
        gestureTimeoutSeconds: 3.0,
        scribbleCancelEnabled: true,
        debugLoggingEnabled: false,
        gestureTargetPolicy: .windowUnderPointer,
        windowMoveModifierFlags: 0,
        windowResizeModifierFlags: 0,
        contentZoomModifierFlags: 0,
        windowMaximizeShortcut: nil,
        mouseControl: .defaults,
        switcher: .defaults,
        inputSourceSwitch: .defaults
    )
}

struct VeltoBackupFile: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var appName: String
    var exportedAt: Date
    var gestures: [GestureCommand]
    var preferences: AppPreferences

    init(
        gestures: [GestureCommand],
        preferences: AppPreferences
    ) {
        formatVersion = Self.currentFormatVersion
        appName = "Velto"
        exportedAt = Date()
        self.gestures = gestures
        self.preferences = preferences
    }
}

enum GestureBackupError: LocalizedError {
    case unsupportedVersion(Int)
    case emptyGestureList

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "不支持的备份版本：\(version)"
        case .emptyGestureList:
            return "备份文件里没有手势配置。"
        }
    }
}

extension Notification.Name {
    static let gestureStoreDidChange = Notification.Name("Velto.gestureStoreDidChange")
}

enum GestureStoreChangeReason: String {
    case gestures
    case preferences
    case backupImport
}

extension Notification {
    var gestureStoreChangeReason: GestureStoreChangeReason? {
        guard let rawValue = userInfo?[GestureStore.changeReasonUserInfoKey] as? String else {
            return nil
        }
        return GestureStoreChangeReason(rawValue: rawValue)
    }
}

enum VirtualKeyCode {
    static let escape: UInt16 = 53
    static let equal: UInt16 = 24
    static let minus: UInt16 = 27
    static let w: UInt16 = 13
    static let t: UInt16 = 17
    static let leftBracket: UInt16 = 33
    static let rightBracket: UInt16 = 30
}

extension CGEventFlags {
    var storedRawValue: UInt64 {
        UInt64(rawValue)
    }
}

/// 应用级配置 / 手势列表的单例。`@MainActor`:SwiftUI View / AppDelegate /
/// EventTapManager 的 init 都在主线程上访问;tap 线程要读最新偏好走的是
/// `EventTapManager` 内的快照副本,从不直接触及这个对象。
@MainActor
@Observable
final class GestureStore {
    static let shared = GestureStore()

    private let gesturesKey = "Velto.gestures"
    private let preferencesKey = "Velto.preferences"
    // `Notification` 的 userInfo 是字符串 key 的 dictionary,extension 上的
    // accessor 必须 nonisolated 才能从任意 actor 读取。
    nonisolated static let changeReasonUserInfoKey = "reason"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var gestures: [GestureCommand]
    private(set) var preferences: AppPreferences
    /// Monotonically incrementing version, bumped every time `gestures` changes.
    /// Consumers (e.g. GestureRecognizer) use this as a cheap O(1) cache key
    /// instead of doing a deep `==` comparison on the gesture list.
    private(set) var gesturesVersion: UInt64 = 0

    private init() {
        gestures = Self.load(
            [GestureCommand].self,
            key: gesturesKey,
            decoder: decoder
        ) ?? Self.defaultGestures()
        preferences = Self.load(
            AppPreferences.self,
            key: preferencesKey,
            decoder: decoder
        ) ?? .defaults
        // 不再强制开启手势:用户在 UI 里的暂停状态应当跨重启持久化(解耦总开关)。
        localizeBuiltInGestureNames()
        gesturesVersion = 1
        syncDebugLog()
    }

    /// 返回是否成功写盘。失败时内存状态仍已更新并通知(本次会话有效),但调用方应
    /// 据此提示用户"重启后会丢失",而不是像以前那样静默吞掉、UI 仍显示已保存。
    @discardableResult
    func updateGestures(_ update: (inout [GestureCommand]) -> Void) -> Bool {
        update(&gestures)
        gesturesVersion &+= 1
        let persisted = saveGestures()
        notifyChanged(reason: .gestures)
        return persisted
    }

    func updatePreferences(_ update: (inout AppPreferences) -> Void) {
        update(&preferences)
        savePreferences()
        syncDebugLog()
        notifyChanged(reason: .preferences)
    }

    func exportBackupData() throws -> Data {
        let backup = VeltoBackupFile(
            gestures: gestures,
            preferences: preferences
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    func importBackupData(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let backup = try decoder.decode(VeltoBackupFile.self, from: data)
        guard backup.formatVersion <= VeltoBackupFile.currentFormatVersion else {
            throw GestureBackupError.unsupportedVersion(backup.formatVersion)
        }
        guard !backup.gestures.isEmpty else {
            throw GestureBackupError.emptyGestureList
        }

        gestures = backup.gestures
        preferences = backup.preferences
        // 尊重备份里的开关状态,不再强制开启(与启动逻辑一致)。
        localizeBuiltInGestureNames()
        gesturesVersion &+= 1
        saveGestures()
        savePreferences()
        syncDebugLog()
        notifyChanged(reason: .backupImport)
    }

    @discardableResult
    private func saveGestures() -> Bool {
        guard let data = try? encoder.encode(gestures) else { return false }
        UserDefaults.standard.set(data, forKey: gesturesKey)
        return true
    }

    private func savePreferences() {
        if let data = try? encoder.encode(preferences) {
            UserDefaults.standard.set(data, forKey: preferencesKey)
        }
    }

    /// 把"调试模式"开关同步给 `DebugLog` —— 覆盖启动加载 / UI 改动 / 配置导入。
    private func syncDebugLog() {
        DebugLog.setEnabled(preferences.debugLoggingEnabled)
    }

    private func notifyChanged(reason: GestureStoreChangeReason) {
        NotificationCenter.default.post(
            name: .gestureStoreDidChange,
            object: self,
            userInfo: [Self.changeReasonUserInfoKey: reason.rawValue]
        )
    }

    private static func load<T: Decodable>(
        _ type: T.Type,
        key: String,
        decoder: JSONDecoder
    ) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private static func defaultGestures() -> [GestureCommand] {
        let command = CGEventFlags.maskCommand.storedRawValue

        return [
            GestureCommand(
                name: "后退",
                templates: [line(from: CGPoint(x: 130, y: 80), to: CGPoint(x: 20, y: 80))],
                shortcut: Shortcut(
                    keyCode: VirtualKeyCode.leftBracket,
                    modifierFlags: command,
                    displayName: "⌘["
                )
            ),
            GestureCommand(
                name: "前进",
                templates: [line(from: CGPoint(x: 20, y: 80), to: CGPoint(x: 130, y: 80))],
                shortcut: Shortcut(
                    keyCode: VirtualKeyCode.rightBracket,
                    modifierFlags: command,
                    displayName: "⌘]"
                )
            ),
            GestureCommand(
                name: "新建标签页",
                templates: [line(from: CGPoint(x: 80, y: 130), to: CGPoint(x: 80, y: 20))],
                shortcut: Shortcut(
                    keyCode: VirtualKeyCode.t,
                    modifierFlags: command,
                    displayName: "⌘T"
                )
            ),
            GestureCommand(
                name: "关闭标签页",
                templates: [line(from: CGPoint(x: 80, y: 20), to: CGPoint(x: 80, y: 130))],
                shortcut: Shortcut(
                    keyCode: VirtualKeyCode.w,
                    modifierFlags: command,
                    displayName: "⌘W"
                )
            )
        ]
    }

    private static func line(from start: CGPoint, to end: CGPoint) -> [StrokePoint] {
        let steps = 12
        return (0...steps).map { index in
            let t = CGFloat(index) / CGFloat(steps)
            return StrokePoint(CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            ))
        }
    }

    private func localizeBuiltInGestureNames() {
        let nameMap = [
            "Back": "后退",
            "Forward": "前进",
            "New Tab": "新建标签页",
            "Close Tab": "关闭标签页",
            "New Gesture": "新手势",
            "Untitled": "未命名"
        ]
        let shortcutDisplayMap = [
            "Cmd+[": "⌘[",
            "Cmd+]": "⌘]",
            "Cmd+T": "⌘T",
            "Cmd+W": "⌘W"
        ]

        var changed = false
        gestures = gestures.map { gesture in
            var localized = gesture
            if let name = nameMap[gesture.name] {
                localized.name = name
                changed = true
            }
            if let shortcut = gesture.shortcut,
               let displayName = shortcutDisplayMap[shortcut.displayName] {
                var localizedShortcut = shortcut
                localizedShortcut.displayName = displayName
                localized.shortcut = localizedShortcut
                changed = true
            }
            return localized
        }

        if changed {
            gesturesVersion &+= 1
            saveGestures()
        }
    }
}
