import AppKit
import CryptoKit
import Foundation

/// 记下本次解码有哪些字段没读出来。只有 `ConfigRecovery.decode` 会挂上它:挂了才容错,
/// 没挂的解码(比如导入备份)照旧严格报错,不会把坏备份静默导入成默认值。
private final class ConfigDecodeIssues: @unchecked Sendable {
    var fields: [String] = []
}

private extension CodingUserInfoKey {
    static let configDecodeIssues = CodingUserInfoKey(rawValue: "velto.configDecodeIssues")!
}

extension KeyedDecodingContainer {
    /// 配置字段专用的 `decodeIfPresent`:读本地配置时单个字段解不出来(比如回退版本后
    /// 遇到不认识的枚举值)只退回 nil,由调用方用默认值,不牵连整份配置。
    func decodeField<T: Decodable>(_ type: T.Type, forKey key: Key, in decoder: Decoder) throws -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            guard let issues = decoder.userInfo[.configDecodeIssues] as? ConfigDecodeIssues else { throw error }
            issues.fields.append((decoder.codingPath + [key]).map(\.stringValue).joined(separator: "."))
            return nil
        }
    }
}

/// 配置读不出来时保住原始数据。
///
/// 以前解码失败就静默回退默认值,下一次保存再把原数据覆盖掉,用户只看到设置全没了,
/// 而且找不回来。现在原始数据先原样另存一份,启动后弹窗告知。
@MainActor
enum ConfigRecovery {
    struct Notice {
        let key: String
        let fields: [String]
        let backupURL: URL
    }

    private(set) static var notices: [Notice] = []

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Velto/ConfigRecovery", isDirectory: true)

    /// 解码本地存的配置。整体解不出来返回 nil;只有部分字段解不出来时返回其余字段。
    /// 两种情况都会留下原始数据的备份。
    static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        key: String,
        decoder: JSONDecoder,
        directory: URL = defaultDirectory
    ) -> T? {
        let issues = ConfigDecodeIssues()
        decoder.userInfo[.configDecodeIssues] = issues
        defer { decoder.userInfo[.configDecodeIssues] = nil }

        do {
            let value = try decoder.decode(type, from: data)
            if !issues.fields.isEmpty {
                preserve(data, key: key, fields: issues.fields, directory: directory)
            }
            return value
        } catch {
            preserve(data, key: key, fields: [key], directory: directory)
            return nil
        }
    }

    /// 文件名带内容摘要:用户不改配置时每次启动都会读到同一份数据,只存一次、只提示一次。
    private static func preserve(_ data: Data, key: String, fields: [String], directory: URL) {
        let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("\(key)-\(digest).json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            notices.append(Notice(key: key, fields: fields, backupURL: url))
            NSLog("Velto 配置读取不完整,原始数据已备份: %@ 字段: %@", url.path, fields.joined(separator: ", "))
        } catch {
            NSLog("Velto 配置备份失败 %@: %@", url.path, error.localizedDescription)
        }
    }

    /// 启动完成后调用,没有问题时什么也不做。
    static func presentNotices() {
        guard !notices.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "部分配置没有读出来"
        alert.informativeText = """
            这些配置已改用默认值,改动前的原始数据已经备份:

            \(notices.flatMap(\.fields).joined(separator: "\n"))
            """
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(notices.map(\.backupURL))
        }
        notices = []
    }
}
