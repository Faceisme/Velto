import AppKit
import Foundation

final class ShortcutRecorderView: NSView {
    var shortcut: Shortcut? {
        didSet {
            needsDisplay = true
        }
    }

    var onShortcutChanged: ((Shortcut) -> Void)?

    private var isRecording = false {
        didSet {
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let shortcut = ShortcutFormatter.shortcut(from: event) else {
            return
        }

        self.shortcut = shortcut
        onShortcutChanged?(shortcut)
        isRecording = false
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let text: String
        let color: NSColor

        if isRecording {
            text = "请按下快捷键"
            color = .systemBlue
        } else {
            text = shortcut?.displayName ?? "点击录制快捷键"
            color = shortcut == nil ? .secondaryLabelColor : .labelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]

        text.draw(
            in: bounds.insetBy(dx: 12, dy: bounds.height / 2 - 9),
            withAttributes: attributes
        )
    }
}
