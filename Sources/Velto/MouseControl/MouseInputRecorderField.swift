import AppKit
import SwiftUI

struct MouseInputRecorderField: View {
    @Binding var trigger: MouseInputTrigger?
    var placeholder: String = "点击录制"
    /// 是否允许录制纯修饰键(无主键)。滚动功能键需要(按住 ⌥ 加速);按钮绑定
    /// 不允许 —— 把裸修饰键绑成按钮会让该修饰键被全局吞掉,破坏整个系统的修饰键。
    var allowsModifierOnly: Bool = true

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var resignObservers: [NSObjectProtocol] = []

    /// 录制中已按下的修饰键并集与最后一颗修饰键的 keyCode。纯修饰键组合(⌃⌥)必须
    /// 等键全松开才能定稿 —— 一按下就收工的话,先按的那颗会把组合直接截断成单键。
    @State private var pendingModifierRaw: UInt64 = 0
    @State private var pendingModifierCode: UInt16 = 0

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
        pendingModifierRaw = 0
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == VirtualKeyCode.escape {
            trigger = nil
            endRecording()
            return
        }

        switch event.type {
        case .flagsChanged:
            guard allowsModifierOnly else { return }
            let raw = ModifierFormatter.normalizedRawValue(from: event.modifierFlags)
            if raw != 0 {
                // 还在往上加键,先攒着。
                pendingModifierRaw |= raw
                pendingModifierCode = event.keyCode
                return
            }
            guard pendingModifierRaw != 0 else { return }
            trigger = MouseInputTrigger(
                kind: .keyboard,
                code: pendingModifierCode,
                // code 那颗键的 flag 本就含在并集里,存全集,判定时取并即可。
                modifierFlags: pendingModifierRaw,
                displayName: ModifierFormatter.displayName(rawValue: pendingModifierRaw)
            )
            pendingModifierRaw = 0
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
