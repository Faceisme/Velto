import Cocoa

/// 单个窗口在切换器面板里的格子。支持三种外观样式:
///   - `.thumbnails`(Win11 风格):大缩略图 + app icon badge + 标题
///   - `.appIcons`(macOS 原生 Cmd+Tab 风格):正方形大图标,标题在下
///   - `.titles`(列表风格):横向条,小图标 + 长标题
///
/// 选中态都用 alt-tab `TileUnderLayer` 同款:accent 色 20% 填充 + 100% 边框。
final class SwitcherTileView: NSView {
    /// 根据样式给出 tile 的尺寸 —— TilesView 用这个排布局。
    static func tileSize(for style: SwitcherAppearanceStyle) -> NSSize {
        switch style {
        case .thumbnails: return NSSize(width: 232, height: 168)
        case .appIcons:   return NSSize(width: 130, height: 130)
        case .titles:     return NSSize(width: 440, height: 44)
        }
    }

    private static let cornerRadius: CGFloat = 18
    private static let thumbnailCornerRadius: CGFloat = 10
    private static let highlightBorderWidth: CGFloat = 3

    let window_: SwitcherWindow
    let style: SwitcherAppearanceStyle
    /// perApp 模式下我们只想显示 app 名(单行),不显示窗口标题副标题。
    let hideWindowTitle: Bool

    /// 缩略图层 —— 仅在 thumbnails 模式可见
    private let thumbnailView: SwitcherImageView
    /// 中央大图标 —— thumbnails 模式当没缩略图时的 fallback;appIcons / titles 模式始终显示
    private let mainIconView: NSImageView
    /// 缩略图右下角的小 app 图标(badge),仅 thumbnails 模式
    private let badgeIconView: NSImageView
    /// 主标题:app 名(总是显示且总是有意义)
    private let appNameLabel: NSTextField
    /// 副标题:窗口标题(可能是网页名/文档名/标签页名,跟 app 名不同时才显示)
    private let titleLabel: NSTextField

    var onHover: ((SwitcherTileView) -> Void)?
    var onClick: ((SwitcherTileView) -> Void)?

    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var isHovered: Bool = false { didSet { needsDisplay = true } }

    private var trackingArea: NSTrackingArea?

    init(window: SwitcherWindow, style: SwitcherAppearanceStyle, hideWindowTitle: Bool = false) {
        self.window_ = window
        self.style = style
        self.hideWindowTitle = hideWindowTitle
        self.thumbnailView = SwitcherImageView(frame: .zero)
        self.mainIconView = NSImageView(frame: .zero)
        self.badgeIconView = NSImageView(frame: .zero)
        self.appNameLabel = NSTextField(labelWithString: "")
        self.titleLabel = NSTextField(labelWithString: "")
        super.init(frame: NSRect(origin: .zero, size: Self.tileSize(for: style)))

        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        let appIcon = window.application.runningApplication.icon
        mainIconView.imageScaling = .scaleProportionallyUpOrDown
        mainIconView.image = appIcon
        badgeIconView.imageScaling = .scaleProportionallyUpOrDown
        badgeIconView.image = appIcon

        let appName = window.application.localizedName ?? ""
        // 主标题:app 名(总是有意义,如 "Surge Dashboard" 而不是 "本地")
        appNameLabel.font = .systemFont(ofSize: style == .titles ? 13 : 12, weight: .semibold)
        appNameLabel.alignment = style == .titles ? .left : .center
        appNameLabel.lineBreakMode = .byTruncatingTail
        appNameLabel.textColor = .labelColor
        appNameLabel.stringValue = appName

        // 副标题:窗口标题,跟 app 名相同 / 为空 / perApp 模式时隐藏
        let winTitle = window.title
        let showSubtitle = !hideWindowTitle && !winTitle.isEmpty && winTitle != appName
        titleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        titleLabel.alignment = style == .titles ? .left : .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.stringValue = winTitle
        titleLabel.isHidden = !showSubtitle

        switch style {
        case .thumbnails: layoutThumbnails(initialThumb: window.thumbnail, hasSubtitle: showSubtitle)
        case .appIcons:   layoutAppIcons(hasSubtitle: showSubtitle)
        case .titles:     layoutTitles(hasSubtitle: showSubtitle)
        }

        addSubview(thumbnailView)
        addSubview(mainIconView)
        addSubview(badgeIconView)
        addSubview(appNameLabel)
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - 三种样式各自的布局

    private func layoutThumbnails(initialThumb: CALayerContents?, hasSubtitle: Bool) {
        let size = Self.tileSize(for: .thumbnails)
        let contentInset: CGFloat = 12
        // 两行文字时整个标题区高一点(app 名 + 窗口标题),单行时矮一点
        let titleAreaH: CGFloat = hasSubtitle ? 40 : 26
        let thumbH: CGFloat = size.height - titleAreaH - contentInset
        let iconSize: CGFloat = 64
        let badgeSize: CGFloat = 28
        let badgePad: CGFloat = 6

        let thumbFrame = NSRect(
            x: contentInset, y: titleAreaH,
            width: size.width - contentInset * 2, height: thumbH
        )
        thumbnailView.frame = thumbFrame
        thumbnailView.layer?.cornerRadius = Self.thumbnailCornerRadius
        thumbnailView.layer?.masksToBounds = true
        if let t = initialThumb {
            thumbnailView.updateContents(t)
            thumbnailView.isHidden = false
        } else {
            thumbnailView.isHidden = true
        }

        mainIconView.frame = NSRect(
            x: thumbFrame.midX - iconSize / 2,
            y: thumbFrame.midY - iconSize / 2,
            width: iconSize, height: iconSize
        )
        mainIconView.isHidden = (initialThumb != nil)

        badgeIconView.frame = NSRect(
            x: thumbFrame.maxX - badgeSize - badgePad,
            y: thumbFrame.minY + badgePad,
            width: badgeSize, height: badgeSize
        )
        badgeIconView.isHidden = (initialThumb == nil)

        // 文字两行布局:app 名在上,窗口标题在下
        let labelWidth = size.width - contentInset * 2
        if hasSubtitle {
            appNameLabel.frame = NSRect(x: contentInset, y: 22, width: labelWidth, height: 16)
            titleLabel.frame = NSRect(x: contentInset, y: 5, width: labelWidth, height: 14)
        } else {
            appNameLabel.frame = NSRect(x: contentInset, y: 7, width: labelWidth, height: 16)
            // titleLabel 已经 isHidden = true
        }
    }

    private func layoutAppIcons(hasSubtitle: Bool) {
        let size = Self.tileSize(for: .appIcons)
        let iconSize: CGFloat = 76
        let titleAreaH: CGFloat = hasSubtitle ? 36 : 22

        mainIconView.frame = NSRect(
            x: (size.width - iconSize) / 2,
            y: titleAreaH + 6,
            width: iconSize, height: iconSize
        )
        mainIconView.isHidden = false

        let labelWidth = size.width - 12
        if hasSubtitle {
            appNameLabel.frame = NSRect(x: 6, y: 20, width: labelWidth, height: 14)
            titleLabel.frame = NSRect(x: 6, y: 4, width: labelWidth, height: 12)
        } else {
            appNameLabel.frame = NSRect(x: 6, y: 5, width: labelWidth, height: 14)
        }

        // appIcons 模式不显示缩略图和 badge
        thumbnailView.isHidden = true
        badgeIconView.isHidden = true
    }

    private func layoutTitles(hasSubtitle: Bool) {
        let size = Self.tileSize(for: .titles)
        let iconSize: CGFloat = 28
        let pad: CGFloat = 12

        mainIconView.frame = NSRect(
            x: pad,
            y: (size.height - iconSize) / 2,
            width: iconSize, height: iconSize
        )
        mainIconView.isHidden = false

        let labelX = pad + iconSize + 10
        let labelWidth = size.width - labelX - pad
        if hasSubtitle {
            appNameLabel.frame = NSRect(x: labelX, y: 22, width: labelWidth, height: 16)
            titleLabel.frame = NSRect(x: labelX, y: 6, width: labelWidth, height: 14)
        } else {
            appNameLabel.frame = NSRect(x: labelX, y: (size.height - 18) / 2, width: labelWidth, height: 18)
        }

        thumbnailView.isHidden = true
        badgeIconView.isHidden = true
    }

    // MARK: - Thumbnail 更新

    /// 抓到新缩略图后由 controller / panel 调,更新一张 tile 的图。
    /// 仅 thumbnails 模式有意义;其他模式静默忽略(节省一次 UI 更新)。
    func updateThumbnail(_ contents: CALayerContents) {
        guard style == .thumbnails else { return }
        thumbnailView.updateContents(contents)
        thumbnailView.isHidden = false
        mainIconView.isHidden = true
        badgeIconView.isHidden = false
    }

    // MARK: - 事件

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(self) }
    override func mouseMoved(with event: NSEvent) { onHover?(self) }
    override func mouseDown(with event: NSEvent) { onClick?(self) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = Self.highlightBorderWidth / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                xRadius: Self.cornerRadius,
                                yRadius: Self.cornerRadius)
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = Self.highlightBorderWidth
            path.stroke()
        } else if isHovered {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = Self.highlightBorderWidth
            path.stroke()
        }
    }
}
