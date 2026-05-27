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

    var displayName: String {
        switch self {
        case .windowUnderPointer:
            return "鼠标指针下方的应用程序和窗口"
        case .activeWindow:
            return "活动的应用程序和窗口"
        }
    }
}

struct AppPreferences: Codable, Equatable {
    var gesturesEnabled: Bool
    var showTrail: Bool
    var showMenuBarIcon: Bool
    var recognitionThreshold: Double
    var gestureTimeoutSeconds: Double
    var gestureTargetPolicy: GestureTargetPolicy
    var windowMoveModifierFlags: UInt64
    var windowResizeModifierFlags: UInt64
    var contentZoomModifierFlags: UInt64
    var windowMaximizeShortcut: Shortcut?
    /// 窗口切换器的全部配置 —— 子结构定义在 Switcher/SwitcherPreferences.swift。
    /// 嵌进来跟手势/窗口管理共享一份 JSON 持久化。
    var switcher: SwitcherPreferences

    init(
        gesturesEnabled: Bool,
        showTrail: Bool,
        showMenuBarIcon: Bool,
        recognitionThreshold: Double,
        gestureTimeoutSeconds: Double,
        gestureTargetPolicy: GestureTargetPolicy,
        windowMoveModifierFlags: UInt64,
        windowResizeModifierFlags: UInt64,
        contentZoomModifierFlags: UInt64,
        windowMaximizeShortcut: Shortcut?,
        switcher: SwitcherPreferences
    ) {
        self.gesturesEnabled = gesturesEnabled
        self.showTrail = showTrail
        self.showMenuBarIcon = showMenuBarIcon
        self.recognitionThreshold = recognitionThreshold
        self.gestureTimeoutSeconds = gestureTimeoutSeconds
        self.gestureTargetPolicy = gestureTargetPolicy
        self.windowMoveModifierFlags = windowMoveModifierFlags
        self.windowResizeModifierFlags = windowResizeModifierFlags
        self.contentZoomModifierFlags = contentZoomModifierFlags
        self.windowMaximizeShortcut = windowMaximizeShortcut
        self.switcher = switcher
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gesturesEnabled = try container.decodeIfPresent(Bool.self, forKey: .gesturesEnabled) ?? Self.defaults.gesturesEnabled
        showTrail = try container.decodeIfPresent(Bool.self, forKey: .showTrail) ?? Self.defaults.showTrail
        showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? Self.defaults.showMenuBarIcon
        recognitionThreshold = try container.decodeIfPresent(Double.self, forKey: .recognitionThreshold) ?? Self.defaults.recognitionThreshold
        gestureTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .gestureTimeoutSeconds) ?? Self.defaults.gestureTimeoutSeconds
        gestureTargetPolicy = try container.decodeIfPresent(GestureTargetPolicy.self, forKey: .gestureTargetPolicy) ?? Self.defaults.gestureTargetPolicy
        windowMoveModifierFlags = try container.decodeIfPresent(UInt64.self, forKey: .windowMoveModifierFlags) ?? Self.defaults.windowMoveModifierFlags
        windowResizeModifierFlags = try container.decodeIfPresent(UInt64.self, forKey: .windowResizeModifierFlags) ?? Self.defaults.windowResizeModifierFlags
        contentZoomModifierFlags = try container.decodeIfPresent(UInt64.self, forKey: .contentZoomModifierFlags) ?? Self.defaults.contentZoomModifierFlags
        windowMaximizeShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .windowMaximizeShortcut) ?? Self.defaults.windowMaximizeShortcut
        switcher = try container.decodeIfPresent(SwitcherPreferences.self, forKey: .switcher) ?? Self.defaults.switcher
    }

    static let defaults = AppPreferences(
        gesturesEnabled: true,
        showTrail: true,
        showMenuBarIcon: true,
        recognitionThreshold: 0.34,
        gestureTimeoutSeconds: 3.0,
        gestureTargetPolicy: .windowUnderPointer,
        windowMoveModifierFlags: 0,
        windowResizeModifierFlags: 0,
        contentZoomModifierFlags: 0,
        windowMaximizeShortcut: nil,
        switcher: .defaults
    )
}

struct VibeGesturesBackupFile: Codable {
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
        appName = "VibeGestures"
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
    static let gestureStoreDidChange = Notification.Name("VibeGestures.gestureStoreDidChange")
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

    private let gesturesKey = "VibeGestures.gestures"
    private let preferencesKey = "VibeGestures.preferences"
    // `Notification` 的 userInfo 是字符串 key 的 dictionary,extension 上的
    // accessor 必须 nonisolated 才能从任意 actor 读取。
    nonisolated static let changeReasonUserInfoKey = "reason"
    private static let legacyBundleIdentifiers = [
        "com.local.MyGestures",
        "com.local.MouseGestureLite"
    ]
    private static let legacyMyGesturesKey = "MyGestures.gestures"
    private static let legacyMyGesturesPreferencesKey = "MyGestures.preferences"
    private static let legacyGesturesKey = "MouseGestureLite.gestures"
    private static let legacyPreferencesKey = "MouseGestureLite.preferences"
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
            legacyKeys: [Self.legacyMyGesturesKey, Self.legacyGesturesKey],
            decoder: decoder
        ) ?? Self.defaultGestures()
        preferences = Self.load(
            AppPreferences.self,
            key: preferencesKey,
            legacyKeys: [Self.legacyMyGesturesPreferencesKey, Self.legacyPreferencesKey],
            decoder: decoder
        ) ?? .defaults
        let needsPreferencesWrite = !preferences.gesturesEnabled
        preferences.gesturesEnabled = true
        localizeBuiltInGestureNames()
        gesturesVersion = 1
        if needsPreferencesWrite {
            savePreferences()
        }
    }

    func updateGestures(_ update: (inout [GestureCommand]) -> Void) {
        update(&gestures)
        gesturesVersion &+= 1
        saveGestures()
        notifyChanged(reason: .gestures)
    }

    func updatePreferences(_ update: (inout AppPreferences) -> Void) {
        update(&preferences)
        savePreferences()
        notifyChanged(reason: .preferences)
    }

    func exportBackupData() throws -> Data {
        let backup = VibeGesturesBackupFile(
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

        let backup = try decoder.decode(VibeGesturesBackupFile.self, from: data)
        guard backup.formatVersion <= VibeGesturesBackupFile.currentFormatVersion else {
            throw GestureBackupError.unsupportedVersion(backup.formatVersion)
        }
        guard !backup.gestures.isEmpty else {
            throw GestureBackupError.emptyGestureList
        }

        gestures = backup.gestures
        preferences = backup.preferences
        preferences.gesturesEnabled = true
        localizeBuiltInGestureNames()
        gesturesVersion &+= 1
        saveGestures()
        savePreferences()
        notifyChanged(reason: .backupImport)
    }

    private func saveGestures() {
        if let data = try? encoder.encode(gestures) {
            UserDefaults.standard.set(data, forKey: gesturesKey)
        }
    }

    private func savePreferences() {
        if let data = try? encoder.encode(preferences) {
            UserDefaults.standard.set(data, forKey: preferencesKey)
        }
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
        legacyKeys: [String],
        decoder: JSONDecoder
    ) -> T? {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? decoder.decode(T.self, from: data) {
            return decoded
        }

        for legacyKey in legacyKeys {
            if let data = UserDefaults.standard.data(forKey: legacyKey),
               let decoded = try? decoder.decode(T.self, from: data) {
                UserDefaults.standard.set(data, forKey: key)
                return decoded
            }
        }

        for bundleIdentifier in legacyBundleIdentifiers {
            guard let legacyDefaults = UserDefaults(suiteName: bundleIdentifier) else {
                continue
            }

            for legacyKey in legacyKeys {
                if let data = legacyDefaults.data(forKey: legacyKey),
                   let decoded = try? decoder.decode(T.self, from: data) {
                    UserDefaults.standard.set(data, forKey: key)
                    return decoded
                }
            }
        }

        return nil
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
