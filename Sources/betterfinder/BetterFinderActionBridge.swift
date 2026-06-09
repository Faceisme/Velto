import AppKit
import Foundation

public enum BetterFinderActionRequestKind: String, Codable, Sendable {
    case open
    case copyPath
}

public struct BetterFinderActionRequest: Codable, Equatable, Sendable {
    public var kind: BetterFinderActionRequestKind
    public var app: BetterFinderApp?
    public var urlPaths: [String]
    public var escapesCopiedPaths: Bool

    public init(
        action: BetterFinderMenuEntryAction,
        urls: [URL],
        preferences: BetterFinderPreferences
    ) {
        switch action {
        case .open(let app):
            kind = .open
            self.app = app
        case .copyPath:
            kind = .copyPath
            app = nil
        }
        urlPaths = urls.map(\.path)
        escapesCopiedPaths = preferences.escapesCopiedPaths
    }

    public init(jsonString: String) throws {
        let data = Data(jsonString.utf8)
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    public var urls: [URL] {
        urlPaths.map { URL(fileURLWithPath: $0) }
    }
}

public enum BetterFinderActionBridgeError: LocalizedError {
    case invalidCallbackURL
    case missingPayload
    case cannotOpenCallbackURL

    public var errorDescription: String? {
        switch self {
        case .invalidCallbackURL:
            "无效的增强Finder回调链接"
        case .missingPayload:
            "增强Finder回调缺少动作数据"
        case .cannotOpenCallbackURL:
            "无法打开增强Finder回调链接"
        }
    }
}

public enum BetterFinderActionBridge {
    public static let callbackURLScheme = "velto-betterfinder"
    public static let callbackURLHost = "perform"
    public static let payloadQueryItemName = "payload"

    public static func post(_ request: BetterFinderActionRequest) throws {
        let url = try callbackURL(for: request)
        BetterFinderDebugLog.log("bridge post kind=\(request.kind.rawValue) app=\(request.app?.name ?? "-") urls=\(request.urlPaths.joined(separator: ",")) callbackLength=\(url.absoluteString.count)")
        let opened = NSWorkspace.shared.open(url)
        BetterFinderDebugLog.log("bridge openCallback result=\(opened)")
        guard opened else {
            throw BetterFinderActionBridgeError.cannotOpenCallbackURL
        }
    }

    public static func callbackURL(for request: BetterFinderActionRequest) throws -> URL {
        var components = URLComponents()
        components.scheme = callbackURLScheme
        components.host = callbackURLHost
        components.queryItems = [
            URLQueryItem(name: payloadQueryItemName, value: try request.jsonString())
        ]
        guard let url = components.url else {
            BetterFinderDebugLog.log("bridge callbackURL failed reason=invalid-components")
            throw BetterFinderActionBridgeError.invalidCallbackURL
        }
        return url
    }

    public static func request(from url: URL) throws -> BetterFinderActionRequest {
        guard url.scheme == callbackURLScheme, url.host == callbackURLHost else {
            BetterFinderDebugLog.log("bridge parse failed reason=invalid-url url=\(url.absoluteString)")
            throw BetterFinderActionBridgeError.invalidCallbackURL
        }
        guard let payload = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == payloadQueryItemName })?
            .value
        else {
            BetterFinderDebugLog.log("bridge parse failed reason=missing-payload url=\(url.absoluteString)")
            throw BetterFinderActionBridgeError.missingPayload
        }
        let request = try BetterFinderActionRequest(jsonString: payload)
        BetterFinderDebugLog.log("bridge parse ok kind=\(request.kind.rawValue) app=\(request.app?.name ?? "-") urls=\(request.urlPaths.joined(separator: ","))")
        return request
    }
}
