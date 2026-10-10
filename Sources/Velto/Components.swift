import AppKit
import SwiftUI

// MARK: - Kbd 键帽

enum KbdSize {
  case sm, md

  var height: CGFloat { self == .sm ? 20 : 24 }
  var fontSize: CGFloat { self == .sm ? 11 : 13 }
  var hPad: CGFloat { self == .sm ? 6 : 7 }
  var gap: CGFloat { self == .sm ? 3 : 4 }
}

struct Kbd: View {
  let keys: [String]
  var size: KbdSize = .md
  /// 深底(选中行)上用浅色键帽
  var inverted: Bool = false

  var body: some View {
    HStack(spacing: size.gap) {
      ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
        let shape = RoundedRectangle(cornerRadius: MGRadius.kbd, style: .continuous)
        Text(key)
          .font(.system(size: size.fontSize, weight: .semibold))
          .foregroundStyle(inverted ? Color.white : Color.mgText2)
          .monospacedDigit()
          .frame(minWidth: size.height, minHeight: size.height)
          .padding(.horizontal, size.hPad - 1) // minWidth 已经留了一点边
          .background(inverted ? Color.white.opacity(0.24) : Color.mgKey, in: shape)
          .overlay {
            if !inverted { shape.strokeBorder(Color.mgHair, lineWidth: 0.5) }
          }
      }
    }
  }
}

// MARK: - Shortcut → Kbd keys conversion

extension Shortcut {
  /// 修饰键直接从结构化的 `modifierFlags` 渲染,键名后缀仍取自 `displayName`
  /// (键名依赖键盘布局/本地化,`ShortcutFormatter` 已在录入时把它写好)。
  var kbdKeys: [String] {
    let flags = CGEventFlags(rawValue: CGEventFlags.RawValue(modifierFlags))
    var result: [String] = []
    if flags.contains(.maskControl) { result.append("⌃") }
    if flags.contains(.maskAlternate) { result.append("⌥") }
    if flags.contains(.maskShift) { result.append("⇧") }
    if flags.contains(.maskCommand) { result.append("⌘") }
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

// MARK: - KeyCapSlot 录制框的内嵌槽

/// 录制框把「正在录制」往上报,外层 KeyCapSlot 据此描强调色边框。
struct RecordingKey: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct KeyCapSlot<Content: View>: View {
  var minWidth: CGFloat = 80
  @ViewBuilder var content: () -> Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
    content()
      .padding(.horizontal, 8)
      .frame(minWidth: minWidth, minHeight: 28)
      .background(Color.mgInset, in: shape)
      .overlayPreferenceValue(RecordingKey.self) { recording in
        if recording { shape.strokeBorder(Color.mgAccent, lineWidth: 1.5) }
      }
  }
}

// MARK: - ActionIcon(行内装饰图标,各页迁移时删)

struct ActionIcon: View {
  let systemName: String
  var size: CGFloat = 40

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: size * 0.48, weight: .semibold))
      .foregroundStyle(Color.mgAccent)
      .frame(width: size, height: size)
      .mgInset(radius: size * 0.28)
  }
}

// MARK: - 模块图标

/// 系统设置式的彩色圆角方块 + 白色符号。侧栏 20pt,页头 32pt。
struct ModuleIcon: View {
  let page: MGPage
  var size: CGFloat = 20

  var body: some View {
    Image(systemName: page.icon)
      .font(.system(size: size * 0.55, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(page.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
  }
}

// MARK: - 页面骨架

/// 页头:模块图标 + 标题 / 一句说明 + 可选的模块总开关。
struct PageHeader: View {
  let page: MGPage
  var subtitle: String? = nil
  var isOn: Binding<Bool>? = nil

  var body: some View {
    HStack(spacing: 12) {
      ModuleIcon(page: page, size: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(page.label)
          .font(.mgPageTitle)
          .foregroundStyle(Color.mgText1)
        if let subtitle {
          Text(subtitle)
            .font(.mgBody)
            .foregroundStyle(Color.mgText2)
        }
      }
      Spacer(minLength: 12)
      if let isOn {
        Toggle("", isOn: isOn)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
      }
    }
  }
}

/// 可滚动,内容最宽 720 居中。
struct SettingsPage<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        content()
      }
      .frame(maxWidth: 720)
      .padding(.horizontal, 32)
      .padding(.vertical, 28)
      .frame(maxWidth: .infinity)
    }
  }
}

/// 一个分组:小标题 + 卡片,卡片里各行之间自动加分隔线。
struct SettingsSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: () -> Content

  init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      MGSectionLabel(text: title)
      GroupCard {
        VStack(spacing: 0) {
          Group(subviews: content()) { rows in
            ForEach(rows) { row in
              if row.id != rows.first?.id {
                Rectangle()
                  .fill(Color.mgHair)
                  .frame(height: 0.5)
                  .padding(.leading, 16)
              }
              row
            }
          }
        }
      }
    }
  }
}

/// 一行设置:标题 / 说明在左,控件在右。
struct SettingsRow<Trailing: View>: View {
  let title: String
  var subtitle: String? = nil
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.mgBody)
          .foregroundStyle(Color.mgText1)
        if let subtitle {
          Text(subtitle)
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

/// 旧页面还在用的行,各页迁移到 SettingsSection 后删。
struct GroupRow<Trailing: View>: View {
  let label: String
  var sub: String? = nil
  var showDivider: Bool = false
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    VStack(spacing: 0) {
      if showDivider {
        Rectangle()
          .fill(Color.mgHair)
          .frame(height: 0.5)
          .padding(.leading, 16)
      }
      SettingsRow(title: label, subtitle: sub, trailing: trailing)
    }
  }
}

// MARK: - ShortcutField 录制框 + 框内清除

struct ShortcutField<Recorder: View>: View {
  let hasValue: Bool
  let clear: () -> Void
  @ViewBuilder var recorder: () -> Recorder

  var body: some View {
    KeyCapSlot(minWidth: 96) {
      HStack(spacing: 6) {
        recorder()
        if hasValue {
          Button(action: clear) {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(Color.mgText3)
          .help("清除")
        }
      }
    }
  }
}

extension ShortcutField where Recorder == ModifierRecorderField {
  init(modifiers: Binding<UInt64>) {
    self.init(hasValue: modifiers.wrappedValue != 0, clear: { modifiers.wrappedValue = 0 }) {
      ModifierRecorderField(modifierFlagsRawValue: modifiers, placeholder: "点击录制")
    }
  }
}

extension ShortcutField where Recorder == ShortcutRecorderField {
  init(shortcut: Binding<Shortcut?>) {
    self.init(hasValue: shortcut.wrappedValue != nil, clear: { shortcut.wrappedValue = nil }) {
      ShortcutRecorderField(shortcut: shortcut, placeholder: "点击录制")
    }
  }
}

// MARK: - DebugSection 页尾调试分组

struct DebugSection: View {
  let isOn: Binding<Bool>
  let logURL: URL
  /// 悬停说明:日志记什么、什么时候开
  let help: String

  var body: some View {
    SettingsSection("调试") {
      SettingsRow(title: "调试日志") {
        Button("在访达中显示", action: reveal)
          .buttonStyle(.bordered)
        Toggle("", isOn: isOn)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
      }
      .help(help)
    }
  }

  /// 日志文件还没生成时退而打开所在目录。
  private func reveal() {
    let dir = logURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: logURL.path) {
      NSWorkspace.shared.activateFileViewerSelecting([logURL])
    } else {
      NSWorkspace.shared.open(dir)
    }
  }
}

// MARK: - Segmented picker(原生 .segmented)

struct MGSegmentedOption<Value: Hashable> {
  let value: Value
  let title: String

  init(_ value: Value, _ title: String) {
    self.value = value
    self.title = title
  }
}

struct MGSegmentedPicker<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [MGSegmentedOption<Value>]

  var body: some View {
    Picker("", selection: $selection) {
      ForEach(options.indices, id: \.self) { i in
        Text(options[i].title).tag(options[i].value)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
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

// MARK: - GroupCard 实色分组卡片

struct GroupCard<Content: View>: View {
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
    .mgCard()
  }
}

// MARK: - Stepper field(带上下箭头的数字框)

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
    .background(Color.mgInset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}
