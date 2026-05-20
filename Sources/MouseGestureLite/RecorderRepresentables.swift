import AppKit
import SwiftUI

struct ShortcutRecorderRepresentable: NSViewRepresentable {
    @Binding var shortcut: Shortcut?

    func makeNSView(context: Context) -> ShortcutRecorderView {
        ShortcutRecorderView()
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.shortcut = shortcut
        view.onShortcutChanged = { self.shortcut = $0 }
    }
}

struct ModifierRecorderRepresentable: NSViewRepresentable {
    @Binding var modifierFlagsRawValue: UInt64

    func makeNSView(context: Context) -> ModifierRecorderView {
        ModifierRecorderView()
    }

    func updateNSView(_ view: ModifierRecorderView, context: Context) {
        view.modifierFlagsRawValue = modifierFlagsRawValue
        view.onModifierFlagsChanged = { self.modifierFlagsRawValue = $0 }
    }
}

struct GestureCaptureRepresentable: NSViewRepresentable {
    var templates: [[StrokePoint]]
    var onStrokeFinished: ([CGPoint]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GestureCaptureView {
        GestureCaptureView()
    }

    func updateNSView(_ view: GestureCaptureView, context: Context) {
        let c = context.coordinator
        if c.lastTemplates != templates {
            c.lastTemplates = templates
            view.showTemplates(templates)
        }
        view.onStrokeFinished = onStrokeFinished
    }

    class Coordinator {
        var lastTemplates: [[StrokePoint]] = []
    }
}
