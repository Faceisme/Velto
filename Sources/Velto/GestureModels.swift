import CoreGraphics
import Foundation

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

struct GestureCommand: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var templates: [[StrokePoint]]
    /// 鼠标按钮触发,和轨迹二选一或并存。旧配置没有这个字段,解码为 nil。
    var buttonTrigger: MouseButtonTrigger?
    var shortcut: Shortcut?

    init(
        id: UUID = UUID(),
        name: String,
        templates: [[StrokePoint]],
        buttonTrigger: MouseButtonTrigger? = nil,
        shortcut: Shortcut?
    ) {
        self.id = id
        self.name = name
        self.templates = templates
        self.buttonTrigger = buttonTrigger
        self.shortcut = shortcut
    }
}

enum GestureTargetPolicy: String, Codable, Equatable {
    case windowUnderPointer
    case activeWindow
}

/// 某个 App 专属的一套手势。手势目标(按「手势作用目标」取光标下 / 活动窗口)落在这个
/// App 上时,先匹配这一套;`includesGlobalGestures` 开着时全局手势也参与,同形状的以
/// 本 App 的为准(见 `GestureAppScope`)。
struct GestureAppProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var bundleIdentifier: String
    var displayName: String
    var path: String
    var includesGlobalGestures: Bool
    var gestures: [GestureCommand]

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        displayName: String,
        path: String,
        includesGlobalGestures: Bool = true,
        gestures: [GestureCommand] = []
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.path = path
        self.includesGlobalGestures = includesGlobalGestures
        self.gestures = gestures
    }
}
