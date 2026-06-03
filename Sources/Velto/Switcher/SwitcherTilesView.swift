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

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    /// 用 windows 列表重建整张网格。返回内容尺寸,Panel 拿去调整自己。
    /// `hideWindowTitle`:perApp 分组时为 true,tile 只显示 app 名。
    /// `maxSize`:面板可用的屏幕区域。据此①按宽度自动算每行列数(一行绝不超出屏幕);
    /// ②多行也超高时,整体等比缩小 tile 塞进一屏。
    @discardableResult
    func rebuild(
        with windows: [SwitcherWindow],
        style: SwitcherAppearanceStyle = .thumbnails,
        hideWindowTitle: Bool = false,
        maxSize: NSSize = NSSize(width: 1_000_000, height: 1_000_000)
    ) -> NSSize {
        for t in tiles { t.removeFromSuperview() }
        tiles.removeAll()

        guard !windows.isEmpty else {
            return NSSize(width: 200, height: 80)
        }

        let tileSize = SwitcherTileView.tileSize(for: style)
        let inset = Self.containerInset
        let sp = Self.tileSpacing

        // ① 每行列数 = 在可用宽度内能放下几个 tile(至少 1,至多窗口数)。
        //    宽屏多排、窄屏少排,一行绝不顶出屏幕;不再写死 6/12。
        let availW = max(tileSize.width, maxSize.width - inset * 2)
        let fitPerRow = max(1, Int((availW + sp) / (tileSize.width + sp)))
        let perRow = min(fitPerRow, windows.count)
        let rows = Int(ceil(Double(windows.count) / Double(perRow)))

        // ② 满尺寸下的内容尺寸;若超出可用宽/高,算一个统一缩放比 ≤1。
        let fullW = CGFloat(perRow) * tileSize.width + CGFloat(perRow - 1) * sp + inset * 2
        let fullH = CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * sp + inset * 2
        let scale = min(1, min(maxSize.width / fullW, maxSize.height / fullH))

        let tW = tileSize.width * scale
        let tH = tileSize.height * scale
        let ssp = sp * scale
        let sInset = inset * scale
        let contentW = fullW * scale
        let contentH = fullH * scale

        for (idx, w) in windows.enumerated() {
            let row = idx / perRow
            let col = idx % perRow
            let x = sInset + CGFloat(col) * (tW + ssp)
            let yFromTop = sInset + CGFloat(row) * (tH + ssp)
            let y = contentH - yFromTop - tH

            let tile = SwitcherTileView(window: w, style: style, hideWindowTitle: hideWindowTitle)
            tile.frame = NSRect(x: x, y: y, width: tW, height: tH)
            // 缩放:让 tile 的坐标系(bounds)保持满尺寸,frame 是缩放后的 ——
            // AppKit 会把内容(缩略图 / 图标 / 文字)整体等比缩小填进去。scale==1 不动。
            if scale < 1 {
                tile.bounds = NSRect(origin: .zero, size: tileSize)
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

        return NSSize(width: contentW, height: contentH)
    }

    func setSelectedIndex(_ index: Int) {
        for (i, t) in tiles.enumerated() {
            t.isSelected = (i == index)
        }
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
