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

    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults?
    private let fileURL: URL?
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedPreferences: BetterFinderPreferences

    public var preferences: BetterFinderPreferences {
        lock.lock()
        defer { lock.unlock() }
        if let persisted = loadPersistedPreferences() {
            cachedPreferences = persisted
            BetterFinderDebugLog.setEnabled(persisted.debugLoggingEnabled)
        }
        return cachedPreferences
    }

    public init(
        defaults: UserDefaults? = UserDefaults(suiteName: BetterFinderConstants.preferencesSuiteName),
        legacyDefaults: UserDefaults? = nil,
        fileURL: URL? = BetterFinderConstants.sharedPreferencesFileURL()
    ) {
        self.defaults = defaults ?? .standard
        self.legacyDefaults = legacyDefaults
        self.fileURL = fileURL
        if let decoded = Self.loadPersistedPreferences(
            defaults: self.defaults,
            legacyDefaults: legacyDefaults,
            fileURL: fileURL,
            decoder: decoder
        ) {
            cachedPreferences = decoded
        } else {
            cachedPreferences = .defaults
        }
        BetterFinderDebugLog.setEnabled(cachedPreferences.debugLoggingEnabled)
        persist(cachedPreferences)
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
            defaults.synchronize()
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
        let sources = [
            fileURL.flatMap { try? Data(contentsOf: $0) },
            defaults.data(forKey: preferencesKey),
            legacyDefaults?.data(forKey: preferencesKey),
            legacyGroupContainerPreferencesData()
        ]

        for data in sources {
            guard let data,
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
