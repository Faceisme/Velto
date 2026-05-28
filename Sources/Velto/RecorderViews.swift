import AppKit
import SwiftUI

// MARK: - ShortcutRecorderField (SwiftUI)
//
// 点击进入录制态:边框变虚线 + 提示"请按下快捷键…"
// 用 NSEvent.addLocalMonitorForEvents 截取按键。
//
// 退出录制态的触发器(任一即可):
//   1. 录到合法 shortcut
//   2. Esc 键
//   3. 任意鼠标点击(包括点击自身 button —— 走 mouseDown → endRecording →
//      事件放行 → button.action 再 begin,用户看起来无变化;点击列表里其他
//      手势同理 → 切换前先退出录制态,修了"切手势后新手势仍显示录制中"那
//      个 bug)
//   4. 窗口失去 key window / app 失活
//
// 不要把 button.action 写成 begin/end toggle —— 那样跟 mouseDown monitor 会
// 互相打架。

struct ShortcutRecorderField: View {
    @Binding var shortcut: Shortcut?
    var placeholder: String = "点击设置快捷键"

    @State private var isRecording = false
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var resignObservers: [NSObjectProtocol] = []

    /// 当 true 时,字段会填满父容器宽度并左对齐(详情卡里那种场景);
    /// 当 false 时,字段紧贴内容(键帽槽里那种场景)。
    var fillWidth: Bool = false

    var body: some View {
        Button {
            // 只 begin,不 toggle。退出靠 monitor / Esc / 失焦。
            if !isRecording { beginRecording() }
        } label: {
            HStack(spacing: 8) {
                if isRecording {
                    Text("请按下快捷键…")
                        .font(.mgBody)
                        .foregroundStyle(Color.mgAccent)
                } else if let sc = shortcut, !sc.kbdKeys.isEmpty {
                    Kbd(keys: sc.kbdKeys, size: .md)
                    if fillWidth {
                        Text("点击修改")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mgText3)
                    }
                } else {
                    Text(placeholder)
                        .font(.mgBody)
                        .foregroundStyle(Color.mgText3)
                }
                if fillWidth { Spacer(minLength: 0) }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if isRecording {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.mgAccent.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .onDisappear { endRecording() }
    }

    private func beginRecording() {
        guard keyMonitor == nil else { return }
        isRecording = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }

        // 鼠标 monitor:任意点击 → 退出录制,事件放行让点击照常发生。
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            endRecording()
            return event
        }

        let nc = NotificationCenter.default
        let o1 = nc.addObserver(forName: NSWindow.didResignKeyNotification,
                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { endRecording() }
        }
        let o2 = nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { endRecording() }
        }
        resignObservers = [o1, o2]
    }

    private func endRecording() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        for o in resignObservers { NotificationCenter.default.removeObserver(o) }
        resignObservers = []
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == VirtualKeyCode.escape {
            endRecording()
            return
        }
        if let sc = ShortcutFormatter.shortcut(from: event) {
            shortcut = sc
            endRecording()
        }
    }
}

// MARK: - ModifierRecorderField (SwiftUI)
//
// 同上,但只录修饰键(⌘ ⌥ ⌃ ⇧ Fn)。
// 用户按下任意修饰键组合后,稍后松开即视为完成。
// 按 Esc 清空。

struct ModifierRecorderField: View {
    @Binding var modifierFlagsRawValue: UInt64
    var placeholder: String = "点击设置"

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var mouseMonitor: Any?
    @State private var resignObservers: [NSObjectProtocol] = []
    @State private var captured: UInt64 = 0

    var body: some View {
        Button {
            // 只 begin。退出靠松开修饰键 / Esc / mouseDown / 失焦。
            if !isRecording { beginRecording() }
        } label: {
            HStack(spacing: 4) {
                if isRecording {
                    if captured != 0 {
                        Kbd(keys: keysFromRaw(captured), size: .md)
                    } else {
                        Text("按住修饰键…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mgAccent)
                    }
                } else if modifierFlagsRawValue != 0 {
                    Kbd(keys: keysFromRaw(modifierFlagsRawValue), size: .md)
                } else {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mgText3)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            if isRecording {
                RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                    .strokeBorder(Color.mgAccent.opacity(0.55),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .allowsHitTesting(false)
            }
        }
        .onDisappear { endRecording(commit: false) }
    }

    private func keysFromRaw(_ raw: UInt64) -> [String] {
        let flags = CGEventFlags(rawValue: CGEventFlags.RawValue(raw))
        var parts: [String] = []
        if flags.contains(.maskControl)    { parts.append("⌃") }
        if flags.contains(.maskAlternate)  { parts.append("⌥") }
        if flags.contains(.maskShift)      { parts.append("⇧") }
        if flags.contains(.maskCommand)    { parts.append("⌘") }
        if flags.contains(.maskSecondaryFn){ parts.append("Fn") }
        return parts
    }

    private func beginRecording() {
        guard monitor == nil else { return }
        captured = 0
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown, event.keyCode == VirtualKeyCode.escape {
                captured = 0
                modifierFlagsRawValue = 0
                endRecording(commit: false)
                return nil
            }
            if event.type == .flagsChanged {
                let raw = ModifierFormatter.normalizedRawValue(from: event.modifierFlags)
                if raw == 0 {
                    // 松开所有键 → 提交
                    if captured != 0 {
                        modifierFlagsRawValue = captured
                        endRecording(commit: true)
                    }
                } else {
                    captured = raw
                }
                return nil
            }
            return event
        }

        // 鼠标点击 / 失焦 → 静默退出录制(不提交,因为用户没松完修饰键)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            endRecording(commit: false)
            return event
        }
        let nc = NotificationCenter.default
        let o1 = nc.addObserver(forName: NSWindow.didResignKeyNotification,
                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { endRecording(commit: false) }
        }
        let o2 = nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { endRecording(commit: false) }
        }
        resignObservers = [o1, o2]
    }

    private func endRecording(commit: Bool) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        for o in resignObservers { NotificationCenter.default.removeObserver(o) }
        resignObservers = []
        if commit, captured != 0 {
            modifierFlagsRawValue = captured
        }
        isRecording = false
    }
}
