import AppKit
import CoreGraphics
import Foundation
import Observation
import betterfinder

struct VeltoBackupFile: Codable {
    static let currentFormatVersion = 3

    var formatVersion: Int
    var appName: String
    var exportedAt: Date
    var gestures: [GestureCommand]
    /// 按 App 的手势。旧备份没有这个字段(nil),导入时保留当前的,不清空。
    var gestureAppProfiles: [GestureAppProfile]?
    var preferences: AppPreferences
    var betterFinderPreferences: BetterFinderPreferences?
    var keyRemapRules: [KeyRemapRule]?
    var keyRemapEnabled: Bool?

    init(
        gestures: [GestureCommand],
        gestureAppProfiles: [GestureAppProfile]? = nil,
        preferences: AppPreferences,
        betterFinderPreferences: BetterFinderPreferences? = nil,
        keyRemapRules: [KeyRemapRule]? = nil,
        keyRemapEnabled: Bool? = nil
    ) {
        formatVersion = Self.currentFormatVersion
        appName = "Velto"
        exportedAt = Date()
        self.gestures = gestures
        self.gestureAppProfiles = gestureAppProfiles
        self.preferences = preferences
        self.betterFinderPreferences = betterFinderPreferences
        self.keyRemapRules = keyRemapRules
        self.keyRemapEnabled = keyRemapEnabled
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
    static let configStoreDidChange = Notification.Name("Velto.configStoreDidChange")
}

enum ConfigStoreChangeReason: String {
    case gestures
    case preferences
    case backupImport
}

/// 一次配置变化的前后快照。所有模块共用一个通知,各自只比较关心的那部分,没变就不动:
/// 否则改一个滑块也会让切换器重注册热键、输入法清空缓存。
struct PreferencesChange {
    let previous: AppPreferences
    let current: AppPreferences

    func changed<Value: Equatable>(_ keyPath: KeyPath<AppPreferences, Value>) -> Bool {
        previous[keyPath: keyPath] != current[keyPath: keyPath]
    }
}

extension Notification {
    var configStoreChangeReason: ConfigStoreChangeReason? {
        guard let rawValue = userInfo?[ConfigStore.changeReasonUserInfoKey] as? String else {
            return nil
        }
        return ConfigStoreChangeReason(rawValue: rawValue)
    }

    /// 配置变了才有;只改手势时是 nil。
    var preferencesChange: PreferencesChange? {
        userInfo?[ConfigStore.preferencesChangeUserInfoKey] as? PreferencesChange
    }
}

/// 应用级配置 / 手势列表的单例。`@MainActor`:SwiftUI View / AppDelegate /
/// EventTapManager 的 init 都在主线程上访问;tap 线程要读最新偏好走的是
/// `EventTapManager` 内的快照副本,从不直接触及这个对象。
@MainActor
@Observable
final class ConfigStore {
    static let shared = ConfigStore()

    private let gesturesKey = "Velto.gestures"
    private let appProfilesKey = "Velto.gestureAppProfiles"
    private let preferencesKey = "Velto.preferences"
    // `Notification` 的 userInfo 是字符串 key 的 dictionary,extension 上的
    // accessor 必须 nonisolated 才能从任意 actor 读取。
    nonisolated static let changeReasonUserInfoKey = "reason"
    nonisolated static let preferencesChangeUserInfoKey = "preferencesChange"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var gestures: [GestureCommand]
    /// 按 App 的手势,和全局 `gestures` 一起由手势页保存、共用 `gesturesVersion`。
    private(set) var appProfiles: [GestureAppProfile]
    private(set) var preferences: AppPreferences
    /// Monotonically incrementing version, bumped every time `gestures` or `appProfiles` changes.
    /// Consumers (e.g. GestureRecognizer) use this as a cheap O(1) cache key
    /// instead of doing a deep `==` comparison on the gesture list.
    private(set) var gesturesVersion: UInt64 = 0

    private init() {
        gestures = Self.load(
            [GestureCommand].self,
            key: gesturesKey,
            decoder: decoder
        ) ?? Self.defaultGestures()
        appProfiles = Self.load(
            [GestureAppProfile].self,
            key: appProfilesKey,
            decoder: decoder
        ) ?? []
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
    func saveGestureSets(global: [GestureCommand], appProfiles: [GestureAppProfile]) -> Bool {
        gestures = global
        self.appProfiles = appProfiles
        gesturesVersion &+= 1
        let persisted = saveGestures()
        notifyChanged(reason: .gestures)
        return persisted
    }

    func updatePreferences(_ update: (inout AppPreferences) -> Void) {
        let previous = preferences
        update(&preferences)
        // 写回同一个值时什么都不做:不重写配置,也不惊动各模块。
        guard preferences != previous else { return }
        savePreferences()
        syncDebugLog()
        notifyChanged(
            reason: .preferences,
            preferencesChange: PreferencesChange(previous: previous, current: preferences)
        )
    }

    func exportBackupData() throws -> Data {
        let backup = VeltoBackupFile(
            gestures: gestures,
            gestureAppProfiles: appProfiles,
            preferences: preferences,
            betterFinderPreferences: BetterFinderPreferencesStore.shared.preferences,
            keyRemapRules: KeyRemapStore.shared.rules,
            keyRemapEnabled: KeyRemapStore.shared.masterEnabled
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

        let previousPreferences = preferences
        gestures = backup.gestures
        if let profiles = backup.gestureAppProfiles {
            appProfiles = profiles
        }
        preferences = backup.preferences
        if let betterFinderPreferences = backup.betterFinderPreferences {
            BetterFinderPreferencesStore.shared.replace(with: betterFinderPreferences)
        }
        // 旧备份没有按键映射:和上面两项一样保留现有的,不清空。
        if let keyRemapRules = backup.keyRemapRules {
            KeyRemapStore.shared.replaceAll(
                rules: keyRemapRules,
                masterEnabled: backup.keyRemapEnabled ?? true
            )
        }
        // 尊重备份里的开关状态,不再强制开启(与启动逻辑一致)。
        localizeBuiltInGestureNames()
        gesturesVersion &+= 1
        saveGestures()
        savePreferences()
        syncDebugLog()
        notifyChanged(
            reason: .backupImport,
            preferencesChange: PreferencesChange(previous: previousPreferences, current: preferences)
        )
    }

    /// 全局手势和按 App 的手势一起写。
    @discardableResult
    private func saveGestures() -> Bool {
        guard let data = try? encoder.encode(gestures),
              let profilesData = try? encoder.encode(appProfiles) else { return false }
        UserDefaults.standard.set(data, forKey: gesturesKey)
        UserDefaults.standard.set(profilesData, forKey: appProfilesKey)
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
        WindowManagementDebugLog.setEnabled(preferences.windowManagementDebugLoggingEnabled)
    }

    private func notifyChanged(reason: ConfigStoreChangeReason, preferencesChange: PreferencesChange? = nil) {
        var userInfo: [String: Any] = [Self.changeReasonUserInfoKey: reason.rawValue]
        userInfo[Self.preferencesChangeUserInfoKey] = preferencesChange
        NotificationCenter.default.post(name: .configStoreDidChange, object: self, userInfo: userInfo)
    }

    private static func load<T: Decodable>(
        _ type: T.Type,
        key: String,
        decoder: JSONDecoder
    ) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return ConfigRecovery.decode(T.self, from: data, key: key, decoder: decoder)
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
