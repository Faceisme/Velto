import CoreGraphics
import SwiftUI

// MARK: - Kbd (keyboard cap chip)

enum KbdSize {
    case sm, md, lg

    var height: CGFloat   { switch self { case .sm: 20; case .md: 24; case .lg: 32 } }
    var fontSize: CGFloat { switch self { case .sm: 11; case .md: 13; case .lg: 15 } }
    var hPad: CGFloat     { switch self { case .sm: 6;  case .md: 7;  case .lg: 10 } }
    var gap: CGFloat      { switch self { case .sm: 3;  case .md: 4;  case .lg: 5 } }
    var radius: CGFloat   { switch self { case .sm: MGRadius.kbd; case .md: MGRadius.kbdMd; case .lg: MGRadius.kbdLg } }
}

struct Kbd: View {
    let keys: [String]
    var size: KbdSize = .md
    /// "inverted" 用于深底(选中行)上的浅色键帽
    var inverted: Bool = false
    /// "muted" 用于淡背景上,降低阴影避免重复(例如键帽槽 KeyCapSlot 内部)
    var muted: Bool = false

    var body: some View {
        HStack(spacing: size.gap) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                singleCap(k)
            }
        }
    }

    @ViewBuilder
    private func singleCap(_ key: String) -> some View {
        let bg: Color = inverted
            ? Color.white.opacity(0.24)
            : Color.mgGlassControl.opacity(0.45)
        let fg: Color = inverted ? .white : .mgText2
        let dropOpacity: Double = (inverted || muted) ? 0 : 0.055

        Text(key)
            .font(.system(size: size.fontSize, weight: .semibold))
            .foregroundStyle(fg)
            .monospacedDigit()
            .frame(minWidth: size.height, minHeight: size.height)
            .padding(.horizontal, size.hPad - 1) // -1 because minWidth already gives some padding
            .background(
                RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    .fill(bg)
            )
            .veltoNativeGlass(in: RoundedRectangle(cornerRadius: size.radius, style: .continuous))
            .shadow(color: Color.mgShadow.opacity(dropOpacity), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Shortcut → Kbd keys conversion

extension Shortcut {
    /// 修饰键直接从结构化的 `modifierFlags` 渲染,键名后缀仍取自 `displayName`
    /// (键名依赖键盘布局/本地化,`ShortcutFormatter` 已在录入时把它写好)。
    var kbdKeys: [String] {
        let flags = CGEventFlags(rawValue: CGEventFlags.RawValue(modifierFlags))
        var result: [String] = []
        if flags.contains(.maskControl)     { result.append("⌃") }
        if flags.contains(.maskAlternate)   { result.append("⌥") }
        if flags.contains(.maskShift)       { result.append("⇧") }
        if flags.contains(.maskCommand)     { result.append("⌘") }
        if flags.contains(.maskSecondaryFn) { result.append("Fn") }

        let keyName = displayNameKeyPortion
        if !keyName.isEmpty {
            result.append(keyName)
        }
        return result
    }

    /// 去掉 displayName 前缀里的修饰键符号,只保留键名部分。
    private var displayNameKeyPortion: String {
        var remaining = Substring(displayName)
        let modifierChars: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        while let first = remaining.first {
            if modifierChars.contains(first) {
                remaining = remaining.dropFirst()
            } else if remaining.hasPrefix("Fn") {
                remaining = remaining.dropFirst(2)
            } else {
                break
            }
        }
        return String(remaining)
    }
}

// MARK: - KeyCapSlot
// 窗口管理页里键帽外面的"卡槽":淡灰底 + 内陷 0.5px 边

struct KeyCapSlot<Content: View>: View {
    var minWidth: CGFloat = 80
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: minWidth)
            .background(
                RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                    .fill(Color.mgGlassControl.opacity(0.35))
            )
            .veltoNativeGlass(in: RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous))
    }
}

// MARK: - ActionIcon

struct ActionIcon: View {
    let systemName: String
    var hue: Double = 245
    var size: CGFloat = 40

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: systemName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(Color.mgAccent)
            .frame(width: size, height: size)
            .background(
                shape.fill(Color.mgAccentSoft.opacity(0.35))
            )
            .veltoNativeGlass(in: shape)
    }
}

// MARK: - PageHeader

struct PageHeader: View {
    let tag: String
    let title: String
    let subtitle: String?

    init(tag: String, title: String, subtitle: String? = nil) {
        self.tag = tag
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tag.uppercased())
                .font(.mgTag)
                .tracking(1.5)
                .foregroundStyle(Color.mgText3)
                .padding(.bottom, 6)
            Text(title)
                .font(.mgPageTitle)
                .foregroundStyle(Color.mgText1)
            if let subtitle {
                Text(subtitle)
                    .font(.mgBody)
                    .foregroundStyle(Color.mgText2)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Segmented picker

struct MGSegmentedOption<Value: Equatable> {
    let value: Value
    let title: String

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

struct MGSegmentedPicker<Value: Equatable>: View {
    @Binding var selection: Value
    let options: [MGSegmentedOption<Value>]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.mgText2)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 16)
                        .frame(minWidth: 78)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.mgAccent)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                .fill(Color.mgGlassControl.opacity(0.38))
        )
    }
}

// MARK: - Menu picker

struct MGMenuOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

struct MGMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [MGMenuOption<Value>]
    var minWidth: CGFloat = 160

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(option.title).tag(option.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: minWidth, alignment: .trailing)
    }
}

// MARK: - GroupCard (rounded white card with hairline+drop)

struct GroupCard<Content: View>: View {
    var radius: CGFloat = MGRadius.card
    var padding: EdgeInsets? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if let padding {
                content().padding(padding)
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mgCard(radius: radius)
    }
}

// MARK: - GroupRow

struct GroupRow<Trailing: View>: View {
    let label: String
    var sub: String? = nil
    var showDivider: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            if showDivider {
                // 0.5px 分隔线, margin-left 16 对齐 label
                Rectangle()
                    .fill(Color.mgHair)
                    .frame(height: 0.5)
                    .padding(.leading, 16)
            }

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.mgBody)
                        .foregroundStyle(Color.mgText1)
                    if let sub {
                        Text(sub)
                            .font(.mgMeta)
                            .foregroundStyle(Color.mgText2)
                    }
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
        }
    }
}

// MARK: - Primary button style

struct MGPrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var hPad: CGFloat = 16
    var font: Font = .mgLabelStrong

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, hPad)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                    .fill(Color.mgAccent)
            )
            .shadow(color: Color.mgShadow.opacity(0.08), radius: 2, x: 0, y: 1)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

// MARK: - Secondary (white pill) button style

struct MGSecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var hPad: CGFloat = 12
    var foreground: Color = .mgText1
    var font: Font = .mgButtonSm

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, hPad)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: MGRadius.controlSm, style: .continuous)
                    .fill(Color.mgGlassControl.opacity(0.35))
            )
            .veltoNativeGlass(in: RoundedRectangle(cornerRadius: MGRadius.controlSm, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - Plain (text-only) button style

struct MGPlainButtonStyle: ButtonStyle {
    var foreground: Color = .mgText2
    var font: Font = .mgButtonSm

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1.0)
    }
}

// MARK: - Destructive ("删除") button — white bg + red ink + red hairline

struct MGDestructiveButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var hPad: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mgBodyMedium)
            .foregroundStyle(Color.mgDanger)
            .padding(.horizontal, hPad)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: MGRadius.controlSm, style: .continuous)
                    .fill(Color.mgDanger.opacity(0.08))
            )
            .veltoNativeGlass(in: RoundedRectangle(cornerRadius: MGRadius.controlSm, style: .continuous))
            .shadow(color: Color.mgShadow.opacity(0.04), radius: 2, x: 0, y: 1)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - Stepper field (number box with up/down)
// 数字框样式:白底 + 0.5px inset + tabular-nums 13/500

struct MGStepperField<Value: Strideable>: View where Value: BinaryFloatingPoint {
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride
    var format: String = "%.1f"

    var body: some View {
        HStack(spacing: 4) {
            Text(String(format: format, Double(value)))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.mgText1)
                .frame(minWidth: 30, alignment: .trailing)
                .padding(.leading, 8)

            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .controlSize(.mini)
                .padding(.trailing, 4)
        }
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.mgGlassControl.opacity(0.35))
        )
        .veltoNativeGlass(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
