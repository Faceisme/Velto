import AppKit
import SwiftUI

struct MouseInputRecorderField: View {
    @Binding var trigger: MouseInputTrigger?
    var placeholder: String = "点击录制"

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var resignObservers: [NSObjectProtocol] = []

    var body: some View {
        Button {
            if !isRecording { beginRecording() }
        } label: {
            HStack(spacing: 8) {
                if isRecording {
                    Text("按键或鼠标按钮…")
                        .font(.mgBody)
                        .foregroundStyle(Color.mgAccent)
                } else if let trigger {
                    Kbd(keys: trigger.displayComponents, size: .md)
                } else {
                    Text(placeholder)
                        .font(.mgBody)
                        .foregroundStyle(Color.mgText3)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            if isRecording {
                RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                    .strokeBorder(
                        Color.mgAccent.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .onDisappear { endRecording() }
    }

    private func beginRecording() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .keyDown,
                .flagsChanged,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown
            ]
        ) { event in
            handle(event)
            return nil
        }

        let nc = NotificationCenter.default
        let o1 = nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { endRecording() }
        }
        let o2 = nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { endRecording() }
        }
        resignObservers = [o1, o2]
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        for observer in resignObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        resignObservers = []
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == VirtualKeyCode.escape {
            trigger = nil
            endRecording()
            return
        }

        switch event.type {
        case .flagsChanged:
            let raw = ModifierFormatter.normalizedRawValue(from: event.modifierFlags)
            guard raw != 0 else { return }
            trigger = MouseInputTrigger(
                kind: .keyboard,
                code: event.keyCode,
                displayName: ModifierFormatter.displayName(rawValue: raw)
            )
            endRecording()
        case .keyDown:
            if let shortcut = ShortcutFormatter.shortcut(from: event) {
                trigger = MouseInputTrigger(
                    kind: .keyboard,
                    code: shortcut.keyCode,
                    modifierFlags: shortcut.modifierFlags,
                    displayName: shortcut.displayName
                )
                endRecording()
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let flags = ShortcutFormatter.cgFlags(from: event.modifierFlags).storedRawValue
            let code = UInt16(event.buttonNumber)
            let display = mouseDisplayName(code: code, modifierFlags: flags)
            trigger = MouseInputTrigger(
                kind: .mouse,
                code: code,
                modifierFlags: flags,
                displayName: display
            )
            endRecording()
        default:
            break
        }
    }

    private func mouseDisplayName(code: UInt16, modifierFlags: UInt64) -> String {
        let prefix = ModifierFormatter.displayName(rawValue: modifierFlags)
        let key: String
        switch code {
        case 0:
            key = "左键"
        case 1:
            key = "右键"
        case 2:
            key = "中键"
        case 3:
            key = "侧键1"
        case 4:
            key = "侧键2"
        default:
            key = "Mouse\(code)"
        }
        return prefix == "未设置" ? key : "\(prefix) \(key)"
    }
}
