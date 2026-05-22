import AppKit
import CoreGraphics
import Foundation

enum ModifierFormatter {
    private static let relevantFlags: CGEventFlags = [
        .maskControl,
        .maskAlternate,
        .maskShift,
        .maskCommand,
        .maskSecondaryFn
    ]

    static func normalizedRawValue(from flags: CGEventFlags) -> UInt64 {
        UInt64(flags.intersection(relevantFlags).rawValue)
    }

    static func normalizedRawValue(from flags: NSEvent.ModifierFlags) -> UInt64 {
        normalizedRawValue(from: ShortcutFormatter.cgFlags(from: flags))
    }

    static func displayName(rawValue: UInt64) -> String {
        guard rawValue != 0 else {
            return "未设置"
        }

        let flags = CGEventFlags(rawValue: CGEventFlags.RawValue(rawValue))
        var parts: [String] = []

        if flags.contains(.maskControl) {
            parts.append("⌃")
        }
        if flags.contains(.maskAlternate) {
            parts.append("⌥")
        }
        if flags.contains(.maskShift) {
            parts.append("⇧")
        }
        if flags.contains(.maskCommand) {
            parts.append("⌘")
        }
        if flags.contains(.maskSecondaryFn) {
            parts.append("Fn")
        }

        return parts.joined()
    }
}

final class ModifierRecorderView: NSView {
    var modifierFlagsRawValue: UInt64 = 0 {
        didSet {
            needsDisplay = true
        }
    }

    var onModifierFlagsChanged: ((UInt64) -> Void)?

    private var isRecording = false {
        didSet {
            pendingModifierFlagsRawValue = 0
            needsDisplay = true
        }
    }
    private var pendingModifierFlagsRawValue: UInt64 = 0

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

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            return
        }

        let rawValue = ModifierFormatter.normalizedRawValue(from: event.modifierFlags)
        if rawValue == 0 {
            if pendingModifierFlagsRawValue != 0 {
                isRecording = false
            }
            return
        }

        if pendingModifierFlagsRawValue == 0 || rawValue & pendingModifierFlagsRawValue == pendingModifierFlagsRawValue {
            pendingModifierFlagsRawValue = rawValue
            modifierFlagsRawValue = rawValue
            onModifierFlagsChanged?(rawValue)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == VirtualKeyCode.escape {
            modifierFlagsRawValue = 0
            onModifierFlagsChanged?(0)
        }
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
            text = pendingModifierFlagsRawValue == 0
                ? "请按住修饰键"
                : ModifierFormatter.displayName(rawValue: pendingModifierFlagsRawValue)
            color = .systemBlue
        } else {
            text = modifierFlagsRawValue == 0
                ? "点击录制修饰键"
                : ModifierFormatter.displayName(rawValue: modifierFlagsRawValue)
            color = modifierFlagsRawValue == 0 ? .secondaryLabelColor : .labelColor
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
