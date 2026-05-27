import Cocoa

/// 缩略图的两种载体:
///   - `pixelBuffer`:从 SCK 拿到的 CVPixelBuffer,可直接喂给 CALayer.contents
///     (走 IOSurface,GPU 零拷贝)—— 这是丝滑的关键
///   - `cgImage`:CG 私有 API 抓回的图(最小化窗口 fallback 用)
///
/// 抄自 alt-tab `kit/LightImageView.swift`。
///
/// `@unchecked Sendable`:CGImage / CVPixelBuffer 都是 CF 类型,引用跨线程
/// 传递是安全的(它们内部有自己的锁)。Swift 看不出来,显式标注。
enum CALayerContents: @unchecked Sendable {
    case cgImage(CGImage?)
    case pixelBuffer(CVPixelBuffer?)
}

/// CALayer 子类,展示图像。比 NSImageView 轻得多:
///   - 没 AppKit responder chain / layout pass / drag-and-drop 包袱
///   - `layerContentsRedrawPolicy = .never` —— 内容更新只走 contents,不走 redraw
///   - `delegate = NoAnimationDelegate.shared` —— 关闭所有隐式动画
///
/// 抄自 alt-tab `kit/LightImageLayer.swift`。
final class SwitcherImageLayer: CALayer {
    override init() {
        super.init()
        contentsGravity = .resize
        magnificationFilter = .trilinear
        minificationFilter = .trilinear
        delegate = NoAnimationDelegate.shared
    }

    required init?(coder: NSCoder) {
        fatalError("not implemented")
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    /// 喂图。优先 pixelBuffer 路径(零拷贝),不行降级到 cgImage。
    func updateContents(_ caLayerContents: CALayerContents) {
        switch caLayerContents {
        case .pixelBuffer(let buf?):
            // CALayer.contents 接受 IOSurfaceRef,SCK 内部用的就是这个。
            contents = CVPixelBufferGetIOSurface(buf)?.takeUnretainedValue()
        case .cgImage(let img?):
            contents = img
        default:
            break
        }
    }

    func releaseImage() {
        contents = nil
    }
}

/// 想在 NSView 树里嵌图的薄包装(我们 tile 里要用)。
final class SwitcherImageView: NSView {
    let imageLayer: SwitcherImageLayer

    override init(frame frameRect: NSRect = .zero) {
        imageLayer = SwitcherImageLayer()
        super.init(frame: frameRect)
        wantsLayer = true
        layer!.addSublayer(imageLayer)
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) {
        fatalError("not implemented")
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    func updateContents(_ caLayerContents: CALayerContents) {
        imageLayer.updateContents(caLayerContents)
    }

    func releaseImage() {
        imageLayer.releaseImage()
    }
}

/// 任何 CALayer 加它当 delegate,所有隐式动画(frame、position、opacity、bounds...
/// 全套)都会被禁掉。alt-tab 在所有跟切换器相关的 layer 上都挂这个 —— 切换器
/// 的所有交互都不要补间动画,即时显示就对了。
///
/// `@unchecked Sendable`:这个 delegate 完全无状态,`shared` 是只读引用,
/// 多线程访问没风险。
final class NoAnimationDelegate: NSObject, CALayerDelegate, @unchecked Sendable {
    static let shared = NoAnimationDelegate()
    func action(for layer: CALayer, forKey event: String) -> (any CAAction)? { NSNull() }
}
