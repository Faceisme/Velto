import Foundation

public enum BetterFinderConstants {
    public static let preferencesSuiteName = "com.face.myapp.betterfinder"
    public static let legacyPreferencesSuiteName = "group.com.face.velto.betterfinder"
    public static let hostBundleIdentifier = "com.face.myapp"
    public static let finderExtensionBundleIdentifier = "com.face.myapp.betterfinder.FinderExtension"

    public static func sharedPreferencesFileURL() -> URL? {
        let fileManager = FileManager.default
        let baseURL: URL?
        if Bundle.main.bundleIdentifier == finderExtensionBundleIdentifier {
            baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        } else {
            baseURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Containers")
                .appendingPathComponent(finderExtensionBundleIdentifier)
                .appendingPathComponent("Data")
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
        }

        return baseURL?
            .appendingPathComponent("Velto")
            .appendingPathComponent("BetterFinder")
            .appendingPathComponent("preferences.json")
    }

    public static func sharedDebugLogFileURL() -> URL? {
        let fileManager = FileManager.default
        let baseURL: URL?
        if Bundle.main.bundleIdentifier == finderExtensionBundleIdentifier {
            baseURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        } else {
            baseURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Containers")
                .appendingPathComponent(finderExtensionBundleIdentifier)
                .appendingPathComponent("Data")
                .appendingPathComponent("Library")
        }

        return baseURL?
            .appendingPathComponent("Logs")
            .appendingPathComponent("Velto")
            .appendingPathComponent("betterfinder-debug.log")
    }
}

public final class BetterFinderPreferencesStore: @unchecked Sendable {
    public static let shared = BetterFinderPreferencesStore()
    public static let didChangeNotification = Notification.Name("Velto.betterfinder.preferencesDidChange")
    public static let preferencesKey = "BetterFinder.preferences"

    private struct FileStamp: Equatable {
        let size: Int64
        let mtime: TimeInterval
    }

    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults?
    private let fileURL: URL?
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedPreferences: BetterFinderPreferences
    private var cachedFileStamp: FileStamp?

    /// menu(for:) 每次开菜单(工具栏/右键)都同步读它。此前每次访问都"读文件+JSON 解码+
    /// 逐个查 UserDefaults",是 Finder 菜单显示"正在等待…"的元凶之一;现在先 stat 共享
    /// 文件,内容没变直接回内存缓存(微秒级),变了才重新读盘解码。
    public var preferences: BetterFinderPreferences {
        lock.lock()
        defer { lock.unlock() }
        let stamp = Self.fileStamp(at: fileURL)
        if stamp == nil || stamp != cachedFileStamp {
            if let persisted = loadPersistedPreferences() {
                cachedPreferences = persisted
                BetterFinderDebugLog.setEnabled(persisted.debugLoggingEnabled)
            }
            cachedFileStamp = stamp
        }
        return cachedPreferences
    }

    private static func fileStamp(at url: URL?) -> FileStamp? {
        guard let url else { return nil }
        var status = stat()
        guard stat(url.path, &status) == 0 else { return nil }
        return FileStamp(
            size: Int64(status.st_size),
            mtime: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    public init(
        defaults: UserDefaults? = nil,
        legacyDefaults: UserDefaults? = nil,
        fileURL: URL? = BetterFinderConstants.sharedPreferencesFileURL()
    ) {
        let usesInjectedDefaults = defaults != nil
        self.defaults = defaults ?? UserDefaults(suiteName: BetterFinderConstants.preferencesSuiteName) ?? .standard
        self.legacyDefaults = legacyDefaults
        self.fileURL = fileURL
        let shouldWriteMigratedPreferences = fileURL.map {
            usesInjectedDefaults || !FileManager.default.fileExists(atPath: $0.path)
        } ?? true
        if let decoded = Self.loadPersistedPreferences(
            defaults: self.defaults,
            legacyDefaults: legacyDefaults,
            fileURL: fileURL,
            decoder: decoder
        ) {
            cachedPreferences = decoded
            if shouldWriteMigratedPreferences {
                persist(cachedPreferences)
            }
        } else {
            cachedPreferences = .defaults
            persist(cachedPreferences)
        }
        BetterFinderDebugLog.setEnabled(cachedPreferences.debugLoggingEnabled)
    }

    public func update(_ update: (inout BetterFinderPreferences) -> Void) {
        lock.lock()
        update(&cachedPreferences)
        let preferences = cachedPreferences
        lock.unlock()

        persist(preferences)
        BetterFinderDebugLog.setEnabled(preferences.debugLoggingEnabled)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self
        )
    }

    public func replace(with preferences: BetterFinderPreferences) {
        lock.lock()
        cachedPreferences = preferences
        lock.unlock()

        persist(preferences)
        BetterFinderDebugLog.setEnabled(preferences.debugLoggingEnabled)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self
        )
    }

    public func reset() {
        replace(with: .defaults)
    }

    private func persist(_ preferences: BetterFinderPreferences) {
        if let data = try? encoder.encode(preferences) {
            defaults.set(data, forKey: Self.preferencesKey)
            persistToFile(data)
        }
    }

    private func persistToFile(_ data: Data) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            // 自己写入的内容无需下次重读:同步刷新 stamp,保持 preferences 走内存缓存。
            lock.lock()
            cachedFileStamp = Self.fileStamp(at: fileURL)
            lock.unlock()
        } catch {
            NSLog("BetterFinder preferences file write failed: %@", error.localizedDescription)
        }
    }

    private func loadPersistedPreferences() -> BetterFinderPreferences? {
        Self.loadPersistedPreferences(
            defaults: defaults,
            legacyDefaults: legacyDefaults,
            fileURL: fileURL,
            decoder: decoder
        )
    }

    private static func loadPersistedPreferences(
        defaults: UserDefaults,
        legacyDefaults: UserDefaults?,
        fileURL: URL?,
        decoder: JSONDecoder
    ) -> BetterFinderPreferences? {
        // 惰性求值:数组字面量会把四个来源全部执行(cfprefsd IPC + 两次遗留文件读取),
        // 即便首个来源已命中。共享文件命中(常态)时后面三个不再执行。
        let sources: [() -> Data?] = [
            { fileURL.flatMap { try? Data(contentsOf: $0) } },
            { defaults.data(forKey: preferencesKey) },
            { legacyDefaults?.data(forKey: preferencesKey) },
            { legacyGroupContainerPreferencesData() }
        ]

        for source in sources {
            guard let data = source(),
                  let preferences = try? decoder.decode(BetterFinderPreferences.self, from: data)
            else {
                continue
            }
            return preferences
        }
        return nil
    }

    private static func legacyGroupContainerPreferencesData() -> Data? {
        guard Bundle.main.bundleIdentifier != BetterFinderConstants.finderExtensionBundleIdentifier else {
            return nil
        }
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Group Containers")
            .appendingPathComponent(BetterFinderConstants.legacyPreferencesSuiteName)
            .appendingPathComponent("Library")
            .appendingPathComponent("Preferences")
            .appendingPathComponent("\(BetterFinderConstants.legacyPreferencesSuiteName).plist")

        guard let plistData = try? Data(contentsOf: fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dictionary = plist as? [String: Any]
        else {
            return nil
        }
        return dictionary[preferencesKey] as? Data
    }
}
