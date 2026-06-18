import AppKit
import SwiftUI
import VeltoAnnotationCore

/// 截图模块设置页。
/// 所有写入走 GestureStore.shared.updatePreferences { $0.screenshot.xxx = ... }
/// 触发 .gestureStoreDidChange → EventTapManager 重推触发键快照。
struct ScreenshotPage: View {
  private let store = GestureStore.shared

  // 本地快照:onReceive 更新,保证每次存储变更都刷新 UI
  @State private var prefs = GestureStore.shared.preferences.screenshot
  // 屏幕录制权限(非持久,查询实时值)
  @State private var screenRecordingTrusted = PermissionManager.isScreenRecordingTrusted
  // 触发键校验提示
  @State private var triggerShortcutWarning = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(
          tag: "Screenshot",
          title: "截图",
          subtitle: "全局触发键唤起截图,支持区域/窗口选择、复制剪贴板、静默保存预设目录。"
        )

        enableSection
        triggerSection
        sessionKeysSection
        saveSection
        annotationSection
        magnifierSection
      }
      .padding(.horizontal, 32)
      .padding(.top, 28)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onReceive(
      NotificationCenter.default.publisher(for: .gestureStoreDidChange)
    ) { _ in
      prefs = store.preferences.screenshot
      screenRecordingTrusted = PermissionManager.isScreenRecordingTrusted
    }
  }

  // MARK: - 总开关 + 屏幕录制权限

  private var enableSection: some View {
    GroupCard(radius: MGRadius.cardLg) {
      VStack(spacing: 0) {
        row(
          icon: "power",
          title: "启用截图",
          desc: "关闭后全局触发键不再唤起截图会话。",
          showDivider: !screenRecordingTrusted
        ) {
          AnyView(
            Toggle("", isOn: Binding(
              get: { prefs.enabled },
              set: { v in updatePrefs { $0.screenshot.enabled = v } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.mgAccent)
          )
        }

        if !screenRecordingTrusted {
          row(
            icon: "exclamationmark.shield",
            title: "屏幕录制权限",
            desc: "截图需要屏幕录制权限。请在系统设置中授权后重启 App。",
            showDivider: true
          ) {
            AnyView(
              HStack(spacing: 8) {
                Button("请求权限") {
                  _ = PermissionManager.requestScreenRecordingPrompt()
                  screenRecordingTrusted = PermissionManager.isScreenRecordingTrusted
                }
                .buttonStyle(MGSecondaryButtonStyle(foreground: .mgAccent))

                Button("打开隐私设置") {
                  PermissionManager.openPrivacySettings()
                }
                .buttonStyle(MGSecondaryButtonStyle())
              }
            )
          }
        }
      }
    }
  }

  // MARK: - 全局触发键

  private var triggerSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      MGSectionLabel(text: "全局触发键")
      GroupCard(radius: MGRadius.cardLg) {
        VStack(spacing: 0) {
          row(
            icon: "camera.viewfinder",
            title: "触发快捷键",
            desc: "按下此键唤起截图会话。必须包含 ⌘/⌥/⌃ 之一,否则会与普通输入冲突。",
            showDivider: triggerShortcutWarning
          ) {
            AnyView(
              HStack(spacing: 8) {
                KeyCapSlot(minWidth: 120) {
                  ShortcutRecorderField(
                    shortcut: Binding(
                      get: { prefs.triggerShortcut },
                      set: { newValue in
                        if let s = newValue, !s.hasRealModifier {
                          triggerShortcutWarning = true
                          return
                        }
                        triggerShortcutWarning = false
                        updatePrefs { $0.screenshot.triggerShortcut = newValue }
                      }
                    ),
                    placeholder: "点击录制"
                  )
                }
                if prefs.triggerShortcut != nil {
                  Button("清除") {
                    triggerShortcutWarning = false
                    updatePrefs { $0.screenshot.triggerShortcut = nil }
                  }
                  .buttonStyle(MGPlainButtonStyle(foreground: .mgText3))
                }
              }
            )
          }

          if triggerShortcutWarning {
            HStack(spacing: 6) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
                .font(.system(size: 12))
              Text("触发键必须包含真实修饰键(⌘/⌥/⌃),否则会拦截普通输入。")
                .font(.mgMeta)
                .foregroundStyle(Color.red)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }

  // MARK: - 会话内按键

  private var sessionKeysSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      MGSectionLabel(text: "会话内按键")
      GroupCard(radius: MGRadius.cardLg) {
        VStack(spacing: 0) {
          // 复制到剪贴板:裸 keyCode(默认空格 49),只读展示
          row(
            icon: "doc.on.clipboard",
            title: "复制到剪贴板",
            desc: nil,
            showDivider: false
          ) {
            AnyView(
              Text(keyName(for: prefs.copyKeyCode))
                .font(.mgBody)
                .foregroundStyle(Color.mgText2)
            )
          }

          // 保存到目录:完整 Shortcut,用录制控件
          row(
            icon: "square.and.arrow.down",
            title: "保存到目录",
            desc: nil,
            showDivider: true
          ) {
            AnyView(
              HStack(spacing: 8) {
                KeyCapSlot(minWidth: 100) {
                  ShortcutRecorderField(
                    shortcut: Binding(
                      get: { prefs.saveShortcut },
                      set: { newValue in
                        if let s = newValue {
                          updatePrefs { $0.screenshot.saveShortcut = s }
                        }
                      }
                    ),
                    placeholder: "点击录制"
                  )
                }
              }
            )
          }

          // 取消:裸 keyCode(默认 Esc 53),只读展示
          row(
            icon: "xmark.circle",
            title: "取消截图",
            desc: nil,
            showDivider: true
          ) {
            AnyView(
              Text(keyName(for: prefs.cancelKeyCode))
                .font(.mgBody)
                .foregroundStyle(Color.mgText2)
            )
          }

          // 滚动长截图:Phase 3 占位,灰显
          row(
            icon: "scroll",
            title: "滚动长截图",
            desc: "即将支持(Phase 3)",
            showDivider: true
          ) {
            AnyView(
              Text(keyName(for: prefs.scrollKeyCode))
                .font(.mgBody)
                .foregroundStyle(Color.mgText3)
            )
          }
          .disabled(true)
          .opacity(0.5)
        }
      }

      Text("复制/取消/滚动键为单键(无修饰),暂不支持自定义录制。保存键支持修改。")
        .font(.mgMeta)
        .foregroundStyle(Color.mgText3)
        .padding(.top, 8)
        .padding(.leading, 4)
    }
  }

  // MARK: - 保存目录

  private var saveSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      MGSectionLabel(text: "保存")
      GroupCard(radius: MGRadius.cardLg) {
        VStack(spacing: 0) {
          row(
            icon: "folder",
            title: "保存目录",
            desc: prefs.saveDirectoryPath,
            showDivider: false
          ) {
            AnyView(
              Button("选择…") {
                chooseSaveDirectory()
              }
              .buttonStyle(MGSecondaryButtonStyle())
            )
          }

          row(
            icon: "doc.on.clipboard.fill",
            title: "保存时同时复制到剪贴板",
            desc: nil,
            showDivider: true
          ) {
            AnyView(
              Toggle("", isOn: Binding(
                get: { prefs.saveAlsoCopiesToClipboard },
                set: { v in updatePrefs { $0.screenshot.saveAlsoCopiesToClipboard = v } }
              ))
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
              .tint(.mgAccent)
            )
          }
        }
      }
    }
  }

  // MARK: - 标注默认样式

  private var annotationSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      MGSectionLabel(text: "标注默认样式")
      GroupCard(radius: MGRadius.cardLg) {
        VStack(spacing: 0) {
          row(
            icon: "paintpalette",
            title: "默认颜色",
            desc: "新建标注的描边与文字颜色。",
            showDivider: false
          ) {
            AnyView(
              ColorPicker("", selection: Binding(
                get: { Color(prefs.annotationColor.nsColor) },
                set: { newValue in
                  if let resolved = AnnotationColor(resolving: NSColor(newValue)) {
                    updatePrefs { $0.screenshot.annotationColor = resolved }
                  }
                }
              ))
              .labelsHidden()
            )
          }

          row(icon: "pencil.tip", title: "线宽", desc: nil, showDivider: true) {
            AnyView(
              Picker("", selection: Binding(
                get: { prefs.annotationLineWidth },
                set: { v in updatePrefs { $0.screenshot.annotationLineWidth = v } }
              )) {
                ForEach([CGFloat(1), 3, 5], id: \.self) { Text("\(Int($0))").tag($0) }
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .fixedSize()
            )
          }

          row(icon: "textformat.size", title: "字号", desc: nil, showDivider: true) {
            AnyView(
              Picker("", selection: Binding(
                get: { prefs.annotationFontSize },
                set: { v in updatePrefs { $0.screenshot.annotationFontSize = v } }
              )) {
                ForEach([CGFloat(14), 18, 24, 32], id: \.self) { Text("\(Int($0))").tag($0) }
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .fixedSize()
            )
          }

          row(
            icon: "highlighter",
            title: "高亮透明度",
            desc: nil,
            showDivider: true
          ) {
            AnyView(opacitySlider(
              value: prefs.annotationHighlightOpacity, range: 0.15...0.65
            ) { v in updatePrefs { $0.screenshot.annotationHighlightOpacity = v } })
          }

          row(icon: "square.grid.3x3", title: "马赛克粒度", desc: nil, showDivider: true) {
            AnyView(
              Picker("", selection: Binding(
                get: { prefs.annotationMosaicBlockSize },
                set: { v in updatePrefs { $0.screenshot.annotationMosaicBlockSize = v } }
              )) {
                ForEach([8, 12, 16, 24], id: \.self) { Text("\($0)").tag($0) }
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .fixedSize()
            )
          }

          row(
            icon: "drop",
            title: "填充透明度",
            desc: "形状内部填充,0 为空心。",
            showDivider: true
          ) {
            AnyView(opacitySlider(
              value: prefs.annotationFillOpacity, range: 0...1
            ) { v in updatePrefs { $0.screenshot.annotationFillOpacity = v } })
          }
        }
      }
    }
  }

  /// 透明度滑杆 + 百分比读数,供高亮/填充复用。
  private func opacitySlider(
    value: CGFloat,
    range: ClosedRange<CGFloat>,
    onChange: @escaping (CGFloat) -> Void
  ) -> some View {
    HStack(spacing: 10) {
      Slider(value: Binding(get: { value }, set: onChange), in: range)
        .frame(width: 160)
        .controlSize(.small)
        .tint(.mgAccent)
      Text(String(format: "%.0f%%", value * 100))
        .font(.mgMeta)
        .foregroundStyle(Color.mgText2)
        .frame(width: 40, alignment: .trailing)
    }
  }

  // MARK: - 放大镜

  private var magnifierSection: some View {
    GroupCard(radius: MGRadius.cardLg) {
      VStack(spacing: 0) {
        row(
          icon: "magnifyingglass.circle",
          title: "取色放大镜",
          desc: "截图会话中鼠标附近显示像素放大、HEX 色值与坐标。",
          showDivider: false
        ) {
          AnyView(
            Toggle("", isOn: Binding(
              get: { prefs.showMagnifier },
              set: { v in updatePrefs { $0.screenshot.showMagnifier = v } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.mgAccent)
          )
        }
      }
    }
  }

  // MARK: - 辅助

  private func updatePrefs(_ block: (inout AppPreferences) -> Void) {
    store.updatePreferences(block)
    prefs = store.preferences.screenshot
  }

  private func chooseSaveDirectory() {
    let panel = NSOpenPanel()
    panel.title = "选择截图保存目录"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = URL(fileURLWithPath: prefs.saveDirectoryPath)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    updatePrefs { $0.screenshot.saveDirectoryPath = url.path }
  }

  /// 把裸 keyCode 转成人类可读名称(仅用于只读展示)
  private func keyName(for keyCode: UInt16) -> String {
    switch keyCode {
    case 49: return "空格"
    case 53: return "Esc"
    case 1:  return "S"
    default: return "keyCode \(keyCode)"
    }
  }

  // MARK: - 行布局辅助(与 SwitcherSettingsPage 保持一致)

  @ViewBuilder
  private func row(
    icon: String,
    title: String,
    desc: String?,
    showDivider: Bool = false,
    @ViewBuilder trailing: () -> AnyView
  ) -> some View {
    VStack(spacing: 0) {
      if showDivider {
        Rectangle()
          .fill(Color.mgHair)
          .frame(height: 0.5)
          .padding(.leading, 78)
      }
      HStack(spacing: 16) {
        ActionIcon(systemName: icon)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.mgText1)
          if let desc {
            Text(desc)
              .font(.mgMeta)
              .foregroundStyle(Color.mgText2)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 12)
        trailing()
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
    }
  }
}
