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
    @discardableResult
    func rebuild(with windows: [SwitcherWindow], style: SwitcherAppearanceStyle = .thumbnails) -> NSSize {
        for t in tiles { t.removeFromSuperview() }
        tiles.removeAll()

        guard !windows.isEmpty else {
            return NSSize(width: 200, height: 80)
        }

        let tileSize = SwitcherTileView.tileSize(for: style)
        let perRow: Int
        switch style {
        case .thumbnails: perRow = min(6, windows.count)
        case .appIcons:   perRow = min(12, windows.count)   // 多了就两行
        case .titles:     perRow = 1                       // 单列
        }
        let rows = Int(ceil(Double(windows.count) / Double(perRow)))

        let inset = Self.containerInset
        let sp = Self.tileSpacing
        let contentW = CGFloat(perRow) * tileSize.width + CGFloat(perRow - 1) * sp + inset * 2
        let contentH = CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * sp + inset * 2

        for (idx, w) in windows.enumerated() {
            let row = idx / perRow
            let col = idx % perRow
            let x = inset + CGFloat(col) * (tileSize.width + sp)
            let yFromTop = inset + CGFloat(row) * (tileSize.height + sp)
            let y = contentH - yFromTop - tileSize.height

            let tile = SwitcherTileView(window: w, style: style)
            tile.frame = NSRect(x: x, y: y, width: tileSize.width, height: tileSize.height)
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
