import SwiftUI

// MARK: - Kbd (keyboard chip)

enum KbdSize {
    case sm, md, lg

    var height: CGFloat { switch self { case .sm: 18; case .md: 22; case .lg: 26 } }
    var font: Font {
        switch self {
        case .sm: .system(size: 11, weight: .medium)
        case .md: .system(size: 12, weight: .medium)
        case .lg: .system(size: 14, weight: .medium)
        }
    }
    var radius: CGFloat { switch self { case .sm: 4; case .md: 5; case .lg: 6 } }
    var hPad: CGFloat { switch self { case .sm: 5; case .md: 6; case .lg: 8 } }
    var gap: CGFloat { switch self { case .sm: 2; case .md: 3; case .lg: 4 } }
}

struct Kbd: View {
    let keys: [String]
    var size: KbdSize = .md
    var muted: Bool = false
    var inverted: Bool = false

    var body: some View {
        let foreground = inverted ? Color.white : Color.mgText1
        let keyBackground = inverted
            ? Color.white.opacity(0.20)
            : (muted ? Color.black.opacity(0.04) : Color.white)
        let keyBorder = inverted
            ? Color.white.opacity(0.24)
            : Color.black.opacity(muted ? 0.06 : 0.08)
        let shadow = Color.black.opacity(muted || inverted ? 0 : 0.04)

        HStack(spacing: size.gap) {
            ForEach(keys, id: \.self) { k in
                Text(k)
                    .font(size.font)
                    .foregroundStyle(foreground)
                    .frame(minWidth: size.height, minHeight: size.height)
                    .padding(.horizontal, size.hPad)
                    .background(
                        keyBackground,
                        in: RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                            .strokeBorder(keyBorder, lineWidth: 0.5)
                    )
                    .shadow(color: shadow, radius: 0, x: 0, y: 1)
            }
        }
    }
}

// MARK: - Shortcut → Kbd keys conversion

extension Shortcut {
    /// Convert the shortcut to a list of Kbd-friendly key strings.
    /// displayName format is: modifiers (⌃⌥⇧⌘Fn) directly concatenated with the key name.
    /// The key name can be multi-character ("PageDown", "Home", "回车", "空格", "F1", etc.)
    /// so we strip modifiers off the front and treat the rest as one key.
    var kbdKeys: [String] {
        var result: [String] = []
        var remaining = Substring(displayName)

        let modifierChars: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

        while let first = remaining.first {
            if modifierChars.contains(first) {
                result.append(String(first))
                remaining = remaining.dropFirst()
            } else if remaining.hasPrefix("Fn") {
                result.append("Fn")
                remaining = remaining.dropFirst(2)
            } else {
                break
            }
        }

        if !remaining.isEmpty {
            result.append(String(remaining))
        }

        return result
    }
}

// MARK: - Toolbar status indicator
// Self-contained capsule with explicit padding + fixedSize so the toolbar
// can't squish it. .fixedSize() forces the view to size to its content.

struct ToolbarStatusIndicator: View {
    var listening: Bool

    var body: some View {
        let dotColor = listening ? Color.green : Color.orange
        let textColor = listening
            ? Color(red: 31/255, green: 138/255, blue: 76/255)
            : Color(red: 180/255, green: 100/255, blue: 0/255)

        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(listening ? "监听中" : "已暂停")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .frame(height: 28, alignment: .center)
        .glassEffect(.regular, in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
    }
}

// MARK: - Status pill (for in-content use, has its own background)

struct StatusPill: View {
    enum State {
        case listening, paused
        var color: Color { self == .listening ? .green : .orange }
        var text: String { self == .listening ? "监听中" : "已暂停" }
        var textColor: Color {
            self == .listening
                ? Color(red: 31/255, green: 138/255, blue: 76/255)
                : Color(red: 180/255, green: 100/255, blue: 0/255)
        }
    }

    var state: State = .listening

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.color)
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(state.color.opacity(0.25), lineWidth: 3).scaleEffect(2))
                .compositingGroup()
            Text(state.text)
                .font(.mgCaption.weight(.semibold))
                .foregroundStyle(state.textColor)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(state.color.opacity(0.16), in: Capsule())
        .glassEdge(radius: 999, strength: 0.7)
    }
}
