import Cocoa

/// 切换器面板里的 tiles 网格容器。
///
/// 根据 SwitcherAppearanceStyle 切换布局:
///   - `thumbnails`:多行网格(grid),每行 ≤ 6 个
///   - `appIcons`:单行(像 macOS 原生 Cmd+Tab),最多 12 个换行
///   - `titles`:单列(像列表),每行 1 个
final class SwitcherTilesView: NSView {
    private static let tileSpacing: CGFloat = 8
    private static let containerInset: CGFloat = 24

    private(set) var tiles: [SwitcherTileView] = []

    /// 上次 rebuild 时**单个 tile 自身**的几何参数。只有这些变了才全量重建。
    ///
    /// 关键是不含 `perRow`:列数是 `min(fitPerRow, count)`,窗口数一变它就变,
    /// 拿它当复用条件等于"增删任何一个窗口都全盘重建"—— 正是要治的病。列数只
    /// 影响每个 tile 摆在哪,而 frame 本来每轮都重算。
    /// 也不含原始 maxSize:屏幕 visibleFrame 抖几个点(Dock 自动隐藏、菜单栏)
    /// 算出来的布局往往一模一样,不该打断复用。
    private var lastLayoutKey: LayoutKey?

    private struct LayoutKey: Equatable {
        let style: SwitcherAppearanceStyle
        let hideWindowTitle: Bool
        /// 缩放靠改 tile 的 bounds 实现,变了就得重来。
        let scale: CGFloat
    }

    /// 选中高亮 —— 一整块独立 layer,压在所有 tile 之下。
    ///
    /// 原来选中态画在每个 tile 自己的 `draw(_:)` 里:`setSelectedIndex` 要遍历
    /// **所有** tile 设 `isSelected`,一次 step 触发两次全 tile 重绘;而且高亮是
    /// 瞬移的 —— 敲 Tab 像拨老式拨号盘,没有连续性,这就是"太僵硬"的来源。
    ///
    /// 换成一块会滑的 layer 后:更快(1 次 layer 动画 vs N 次 draw),而且位移
    /// 动画是整个模块唯一的"跟手"载体。用 spring 不用 easing —— 系统级的选中框
    /// (Dock、聚焦环)都是弹性收敛的。它在纯装饰路径上,不挡任何输入。
    /// 非 private 只是为了让测试能断言它的位置/动画,外部不要动它。
    let selectionLayer = CALayer()

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        selectionLayer.cornerRadius = SwitcherTileView.cornerRadius
        selectionLayer.borderWidth = SwitcherTileView.highlightBorderWidth
        selectionLayer.isHidden = true
        // 手动挂的 CALayer 默认带 0.25s 隐式动画 —— isHidden / bounds / 颜色一改
        // 就会自己淡一下,选中框看着像有残影。全关掉,位移动画由我们显式 add。
        selectionLayer.delegate = NoAnimationDelegate.shared
        applySelectionColors()
        layer?.addSublayer(selectionLayer)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// controlAccentColor 是动态色(跟随系统强调色 + 明暗),必须在正确的
    /// appearance 下解析成 CGColor,否则切换深浅色后高亮色会卡在旧值。
    private func applySelectionColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySelectionColors()
    }

    /// 用 windows 列表重建整张网格。返回内容尺寸,Panel 拿去调整自己。
    /// `hideWindowTitle`:perApp 分组时为 true,tile 只显示 app 名。
    /// `maxSize`:面板可用的屏幕区域。据此①按宽度自动算每行列数(一行绝不超出屏幕);
    /// ②多行也超高时,整体等比缩小 tile 塞进一屏。
    ///
    /// 复用是**逐窗口认领**的,不是"整批恒等才复用"。
    ///
    /// 老规则要求窗口集合对象恒等,所以关掉一个窗口、剪掉一个 ghost、微信重建
    /// AX 树换 element……任何一点 churn 都会导致整盘 `removeFromSuperview` +
    /// 重建 N×5 个子视图,顺带把 tracking area 和 hover 状态全清空。现在只增删
    /// 差集:布局参数没变就留着老 tile,缺谁补谁,多谁删谁。
    @discardableResult
    func rebuild(
        with windows: [SwitcherWindow],
        style: SwitcherAppearanceStyle = .thumbnails,
        hideWindowTitle: Bool = false,
        maxSize: NSSize = NSSize(width: 1_000_000, height: 1_000_000)
    ) -> NSSize {
        // 每次 rebuild 都先收起高亮 —— 紧随其后的 setSelectedIndex 会把它直接
        // 摆到正确的格子上(不做位移动画)。见 setSelectedIndex。
        selectionLayer.isHidden = true

        guard !windows.isEmpty else {
            removeAllTiles()
            lastLayoutKey = nil
            return NSSize(width: 200, height: 80)
        }

        let layout = SwitcherTilesLayout(
            count: windows.count, style: style, maxSize: maxSize,
            spacing: Self.tileSpacing, inset: Self.containerInset
        )
        let layoutKey = LayoutKey(
            style: style, hideWindowTitle: hideWindowTitle, scale: layout.scale
        )
        // 缩放 / 样式 / 副标题显隐变了 → tile 的 bounds 与内部布局都得重算,没得复用。
        if layoutKey != lastLayoutKey { removeAllTiles() }

        var spare = [ObjectIdentifier: SwitcherTileView](minimumCapacity: tiles.count)
        for t in tiles { spare[ObjectIdentifier(t.window_)] = t }

        var next: [SwitcherTileView] = []
        next.reserveCapacity(windows.count)
        for w in windows {
            let key = ObjectIdentifier(w)
            // 副标题显隐翻转会改 tile 内部布局,那种只能重建(旧的留在 spare 里下线)
            if let t = spare[key], !t.subtitleVisibilityWouldFlip {
                spare.removeValue(forKey: key)
                t.refreshForReuse()
                next.append(t)
            } else {
                next.append(makeTile(for: w, style: style, hideWindowTitle: hideWindowTitle))
            }
        }
        // 这一轮没被认领的 tile 下线
        for (_, t) in spare { t.removeFromSuperview() }

        tiles = next
        for (idx, t) in tiles.enumerated() {
            t.frame = layout.frame(at: idx)
            // 缩放:frame 已经是缩小后的,再把 bounds 拉回满尺寸 —— AppKit 会把内容
            // (缩略图 / 图标 / 文字)整体等比缩小填进去。
            // **顺序不能反**:先设 bounds 再设 frame 的话,setFrame 会把 bounds
            // 尺寸同步成 frame 尺寸,缩放直接失效。
            if layout.scale < 1 {
                t.bounds = NSRect(origin: .zero, size: layout.tileSize)
            }
        }
        selectionScale = layout.scale
        // 高亮永远压在 tile 之下 —— 新加的 subview layer 会排到它上面,重新沉底。
        layer?.insertSublayer(selectionLayer, at: 0)

        lastLayoutKey = layoutKey
        return layout.contentSize
    }

    private func removeAllTiles() {
        for t in tiles { t.removeFromSuperview() }
        tiles.removeAll()
    }

    private func makeTile(
        for w: SwitcherWindow,
        style: SwitcherAppearanceStyle,
        hideWindowTitle: Bool
    ) -> SwitcherTileView {
        let tile = SwitcherTileView(window: w, style: style, hideWindowTitle: hideWindowTitle)
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
        return tile
    }

    // MARK: - 选中高亮

    /// 弹簧参数:接近临界阻尼(ζ≈0.92),几乎不过冲。
    /// 阶跃响应实测:走完 90% 用 0.072s、99% 用 0.111s —— 敲 Tab 的手还没抬起来
    /// 高亮就到位了。老参数(k=600 / c=45)是这个的两倍慢(90% 要 0.143s、
    /// 99% 要 0.221s),连按时高亮明显拖在手后面。
    /// **调速只动 stiffness,damping 要跟着按 ζ = c / (2√k) 同步改**,只改一个
    /// 会变成过冲(太软)或退化成瞬移(太硬)。
    private static let selectionSpringStiffness: CGFloat = 2400
    private static let selectionSpringDamping: CGFloat = 90

    /// 当前布局的缩放比 —— 高亮层的圆角 / 边框要跟着 tile 一起缩,否则窗口多到
    /// 需要缩放时,高亮会比格子明显更圆更粗。
    private var selectionScale: CGFloat = 1 {
        didSet {
            guard oldValue != selectionScale else { return }
            selectionLayer.cornerRadius = SwitcherTileView.cornerRadius * selectionScale
            selectionLayer.borderWidth = SwitcherTileView.highlightBorderWidth * selectionScale
        }
    }

    func setSelectedIndex(_ index: Int) {
        guard index >= 0, index < tiles.count else {
            selectionLayer.isHidden = true
            return
        }
        let target = tiles[index].frame
        let targetPosition = CGPoint(x: target.midX, y: target.midY)

        // 面板刚弹出来时高亮必须**第 0 帧**就在正确的格子上,不能从上一轮的
        // 位置飞过来。只有 session 进行中的 step 才做位移动画。
        guard !selectionLayer.isHidden else {
            selectionLayer.bounds = NSRect(origin: .zero, size: target.size)
            selectionLayer.position = targetPosition
            selectionLayer.isHidden = false
            return
        }
        guard selectionLayer.position != targetPosition || selectionLayer.bounds.size != target.size else {
            return
        }

        // 从**当前屏幕上的位置**起跳,连按 Tab 时上一段动画能被平滑接管。
        let from = selectionLayer.presentation()?.position ?? selectionLayer.position
        selectionLayer.bounds = NSRect(origin: .zero, size: target.size)
        selectionLayer.position = targetPosition

        let spring = CASpringAnimation(keyPath: "position")
        spring.mass = 1
        spring.stiffness = Self.selectionSpringStiffness
        spring.damping = Self.selectionSpringDamping
        spring.fromValue = NSValue(point: from)
        spring.toValue = NSValue(point: targetPosition)
        spring.duration = spring.settlingDuration
        selectionLayer.add(spring, forKey: "selection")
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
