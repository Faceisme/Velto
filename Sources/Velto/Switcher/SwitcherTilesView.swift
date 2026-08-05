import Cocoa
import QuartzCore

/// 切换器面板里的 tiles 网格容器。
///
/// 根据 SwitcherAppearanceStyle 切换布局:
///   - `thumbnails`:多行网格(grid),每行 ≤ 6 个
///   - `appIcons`:单行(像 macOS 原生 Cmd+Tab),最多 12 个换行
///   - `titles`:单列(像列表),每行 1 个
final class SwitcherTilesView: NSView {
    static let selectionAnimationDuration: CFTimeInterval = 0.10

    private static let tileSpacing: CGFloat = 8
    private static let containerInset: CGFloat = 24
    private static let highlightBorderWidth: CGFloat = 3

    /// 一个高亮层在 tiles 之间移动。快速连按时从 presentation layer 的当前位置
    /// 和速度继续滑向新目标，不会跳回旧位置或让每个 tile 自己弹跳。
    private let selectionLayer = CALayer()
    private var lastSelectionPosition: CGPoint?
    private var lastSelectionSampleTime: CFTimeInterval?

    private(set) var tiles: [SwitcherTileView] = []

    /// 上次 rebuild 的参数 —— 复用判定用。快速连按 ⌘Tab 时窗口集合几乎不变,
    /// 全量重建视图(每 tile 5 个子视图 + tracking area)是召唤路径的大头开销。
    private var lastStyle: SwitcherAppearanceStyle?
    private var lastHideWindowTitle = false
    private var lastMaxSize: NSSize = .zero
    private var lastContentSize: NSSize = .zero

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        selectionLayer.opacity = 0
        selectionLayer.cornerCurve = .continuous
        selectionLayer.allowsEdgeAntialiasing = true
        updateSelectionLayerScale()
        updateSelectionLayerColors()
        layer?.insertSublayer(selectionLayer, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionLayerColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSelectionLayerScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSelectionLayerScale()
    }

    /// 用 windows 列表重建整张网格。返回内容尺寸,Panel 拿去调整自己。
    /// `hideWindowTitle`:perApp 分组时为 true,tile 只显示 app 名。
    /// `maxSize`:面板可用的屏幕区域。据此①按宽度自动算每行列数(一行绝不超出屏幕);
    /// ②多行也超高时,整体等比缩小 tile 塞进一屏。
    ///
    /// 快路径:同一批窗口(对象恒等集合)+ 同参数 → 复用现有 tile 视图,只按新
    /// MRU 序重排 frame + 轻量刷新(标题/缩略图),零视图重建。快速交替切换时
    /// 每次召唤只变顺序不变集合,正好全走这条。
    @discardableResult
    func rebuild(
        with windows: [SwitcherWindow],
        style: SwitcherAppearanceStyle = .thumbnails,
        hideWindowTitle: Bool = false,
        maxSize: NSSize = NSSize(width: 1_000_000, height: 1_000_000)
    ) -> NSSize {
        guard !windows.isEmpty else {
            for t in tiles { t.removeFromSuperview() }
            tiles.removeAll()
            lastStyle = nil
            return NSSize(width: 200, height: 80)
        }

        let layout = SwitcherTilesLayout(
            count: windows.count, style: style, maxSize: maxSize,
            spacing: Self.tileSpacing, inset: Self.containerInset
        )

        if style == lastStyle, hideWindowTitle == lastHideWindowTitle, maxSize == lastMaxSize,
           let reordered = reusableTiles(for: windows)
        {
            tiles = reordered
            for (idx, tile) in tiles.enumerated() {
                tile.frame = layout.frame(at: idx)
                tile.refreshForReuse()
            }
            return lastContentSize
        }

        for t in tiles { t.removeFromSuperview() }
        tiles.removeAll()

        for (idx, w) in windows.enumerated() {
            let tile = SwitcherTileView(window: w, style: style, hideWindowTitle: hideWindowTitle)
            tile.frame = layout.frame(at: idx)
            // 缩放:让 tile 的坐标系(bounds)保持满尺寸,frame 是缩放后的 ——
            // AppKit 会把内容(缩略图 / 图标 / 文字)整体等比缩小填进去。scale==1 不动。
            if layout.scale < 1 {
                tile.bounds = NSRect(origin: .zero, size: layout.tileSize)
            }
            tile.onHover = { [weak self] t in
                guard let self else { return }
                if let i = self.tiles.firstIndex(where: { $0 === t }) {
                    self.onHover?(i)
                }
            }
            tile.onClick = { [weak self] t in
                guard let self else { return }
                if let i = self.tiles.firstIndex(where: { $0 === t }) {
                    self.onClick?(i)
                }
            }
            addSubview(tile)
            tiles.append(tile)
        }

        lastStyle = style
        lastHideWindowTitle = hideWindowTitle
        lastMaxSize = maxSize
        lastContentSize = layout.contentSize
        return layout.contentSize
    }

    /// 窗口集合与现有 tiles 一一对应(对象恒等)且没有 tile 的副标题显隐需要
    /// 翻转(那会改布局)时,返回按新顺序重排的 tiles;否则 nil → 全量重建。
    private func reusableTiles(for windows: [SwitcherWindow]) -> [SwitcherTileView]? {
        guard tiles.count == windows.count else { return nil }
        var byWindow = [ObjectIdentifier: SwitcherTileView](minimumCapacity: tiles.count)
        for t in tiles { byWindow[ObjectIdentifier(t.window_)] = t }
        var result: [SwitcherTileView] = []
        result.reserveCapacity(windows.count)
        for w in windows {
            guard let t = byWindow[ObjectIdentifier(w)], !t.subtitleVisibilityWouldFlip else { return nil }
            result.append(t)
        }
        return result
    }

    func setSelectedIndex(_ index: Int, animated: Bool = true) {
        guard tiles.indices.contains(index) else {
            for tile in tiles { tile.isSelected = false }
            lastSelectionPosition = nil
            lastSelectionSampleTime = nil
            selectionLayer.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selectionLayer.opacity = 0
            CATransaction.commit()
            return
        }

        for (i, tile) in tiles.enumerated() { tile.isSelected = (i == index) }
        let tile = tiles[index]
        let now = CACurrentMediaTime()
        let currentPosition = selectionLayer.presentation()?.position ?? selectionLayer.position
        let wasAnimating = selectionLayer.animation(forKey: "selectionSlide") != nil
        let previousPosition = lastSelectionPosition
        let previousTime = lastSelectionSampleTime
        let wasVisible = selectionLayer.presentation()?.opacity ?? selectionLayer.opacity
        let targetFrame = tile.frame
        let scale = targetFrame.width / max(tile.bounds.width, 1)

        selectionLayer.removeAnimation(forKey: "selectionSlide")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = targetFrame
        selectionLayer.cornerRadius = SwitcherPanel.cellCornerRadius * scale
        selectionLayer.borderWidth = Self.highlightBorderWidth * scale
        selectionLayer.opacity = 1
        CATransaction.commit()

        guard animated,
              wasVisible > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              currentPosition != selectionLayer.position
        else {
            lastSelectionPosition = selectionLayer.position
            lastSelectionSampleTime = now
            return
        }

        let targetPosition = selectionLayer.position
        var initialVelocity: CGFloat = 0
        if wasAnimating, let previousPosition, let previousTime {
            initialVelocity = Self.projectedSelectionVelocity(
                current: currentPosition,
                target: targetPosition,
                previous: previousPosition,
                elapsed: now - previousTime
            )
        }
        lastSelectionPosition = currentPosition
        lastSelectionSampleTime = now

        // 临界阻尼：保留重定向前的速度，但不允许位置过冲或回弹。
        let spring = CASpringAnimation(keyPath: "position")
        spring.fromValue = currentPosition
        spring.toValue = targetPosition
        spring.mass = 1
        spring.stiffness = 3600
        spring.damping = 120
        spring.initialVelocity = initialVelocity
        spring.duration = Self.selectionAnimationDuration
        selectionLayer.add(spring, forKey: "selectionSlide")
    }

    static func projectedSelectionVelocity(
        current: CGPoint,
        target: CGPoint,
        previous: CGPoint,
        elapsed: CFTimeInterval
    ) -> CGFloat {
        let dx = target.x - current.x
        let dy = target.y - current.y
        let distanceSquared = dx * dx + dy * dy
        guard elapsed > 0.001, distanceSquared > 1 else { return 0 }
        let vx = (current.x - previous.x) / elapsed
        let vy = (current.y - previous.y) / elapsed
        return max(-8, min(8, (vx * dx + vy * dy) / distanceSquared))
    }

    private func updateSelectionLayerScale() {
        selectionLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    private func updateSelectionLayerColors() {
        let accent = NSColor.controlAccentColor
        selectionLayer.backgroundColor = accent.withAlphaComponent(0.2).cgColor
        selectionLayer.borderColor = accent.cgColor
    }

    func setHoveredIndex(_ index: Int) {
        for (i, t) in tiles.enumerated() {
            t.isHovered = (i == index)
        }
    }

    func clearHover() {
        for t in tiles { t.isHovered = false }
        onHover?(-1)
    }
}

/// 网格布局纯计算:列数、缩放、每个下标的 frame。从 rebuild 里抽出来,
/// 复用路径与全量路径共享同一份数学,也便于单测。
struct SwitcherTilesLayout {
    let perRow: Int
    /// 满尺寸 tile(缩放前)—— scale<1 时 tile.bounds 用它。
    let tileSize: NSSize
    let scale: CGFloat
    let contentSize: NSSize
    private let tW: CGFloat
    private let tH: CGFloat
    private let ssp: CGFloat
    private let sInset: CGFloat

    init(count: Int, style: SwitcherAppearanceStyle, maxSize: NSSize, spacing: CGFloat, inset: CGFloat) {
        let tileSize = SwitcherTileView.tileSize(for: style)
        // ① 每行列数 = 在可用宽度内能放下几个 tile(至少 1,至多窗口数)。
        //    宽屏多排、窄屏少排,一行绝不顶出屏幕。
        let availW = max(tileSize.width, maxSize.width - inset * 2)
        let fitPerRow = max(1, Int((availW + spacing) / (tileSize.width + spacing)))
        let perRow = min(fitPerRow, count)
        let rows = Int(ceil(Double(count) / Double(perRow)))
        // ② 满尺寸下的内容尺寸;若超出可用宽/高,算一个统一缩放比 ≤1。
        let fullW = CGFloat(perRow) * tileSize.width + CGFloat(perRow - 1) * spacing + inset * 2
        let fullH = CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * spacing + inset * 2
        let scale = min(1, min(maxSize.width / fullW, maxSize.height / fullH))
        self.perRow = perRow
        self.tileSize = tileSize
        self.scale = scale
        self.tW = tileSize.width * scale
        self.tH = tileSize.height * scale
        self.ssp = spacing * scale
        self.sInset = inset * scale
        self.contentSize = NSSize(width: fullW * scale, height: fullH * scale)
    }

    func frame(at idx: Int) -> NSRect {
        let row = idx / perRow
        let col = idx % perRow
        let x = sInset + CGFloat(col) * (tW + ssp)
        let yFromTop = sInset + CGFloat(row) * (tH + ssp)
        return NSRect(x: x, y: contentSize.height - yFromTop - tH, width: tW, height: tH)
    }
}
