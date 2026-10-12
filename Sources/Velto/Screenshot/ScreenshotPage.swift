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

  var body: some View {
    SettingsPage {
      PageHeader(
        page: .screenshot,
        subtitle: "全局触发键唤起截图,支持区域/窗口选择、复制剪贴板、静默保存预设目录。",
        isOn: bind(\.enabled)
      )
      .help("关闭后全局触发键不再唤起截图会话。")

      if !screenRecordingTrusted {
        GroupCard {
          SettingsRow(title: "需要屏幕录制权限", subtitle: "在系统设置中授权后重启 Velto 生效。") {
            Button("请求权限") {
              PermissionManager.requestScreenRecordingPrompt()
              screenRecordingTrusted = PermissionManager.isScreenRecordingTrusted
            }
            .buttonStyle(.borderedProminent)
            Button("打开隐私设置") { PermissionManager.openPrivacySettings("Privacy_ScreenCapture") }
              .buttonStyle(.bordered)
          }
        }
      }

      SettingsSection("快捷键") {
        SettingsRow(title: "触发快捷键", subtitle: "唤起截图会话,须含 ⌘ / ⌥ / ⌃ 之一。") {
          ShortcutField(shortcut: Binding(
            get: { prefs.triggerShortcut },
            set: { newValue in
              // 不含真修饰键会拦截普通输入,直接忽略(保留旧值);清空允许。
              if let s = newValue, !s.hasRealModifier { return }
              updatePrefs { $0.screenshot.triggerShortcut = newValue }
            }
          ))
        }
      }

      // 复制 / 取消 / 滚动是裸 keyCode,只读展示;保存键可录制。
      SettingsSection("会话内按键") {
        SettingsRow(title: "复制到剪贴板") { Kbd(keys: [keyName(for: prefs.copyKeyCode)]) }
        SettingsRow(title: "保存到目录") {
          ShortcutField(hasValue: false, clear: {}) {
            ShortcutRecorderField(
              shortcut: Binding(
                get: { prefs.saveShortcut },
                set: { newValue in
                  if let s = newValue { updatePrefs { $0.screenshot.saveShortcut = s } }
                }
              ),
              placeholder: "点击录制"
            )
          }
        }
        SettingsRow(title: "取消截图") { Kbd(keys: [keyName(for: prefs.cancelKeyCode)]) }
        SettingsRow(title: "滚动长截图", subtitle: "框选后按键进入滚动捕获。") {
          Kbd(keys: [keyName(for: prefs.scrollKeyCode)])
        }
      }

      SettingsSection("保存") {
        SettingsRow(title: "保存目录") {
          HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: prefs.saveDirectoryPath))
              .resizable()
              .frame(width: 16, height: 16)
            Text(URL(fileURLWithPath: prefs.saveDirectoryPath).lastPathComponent)
              .font(.mgBody)
              .foregroundStyle(Color.mgText2)
            Button("选择…", action: chooseSaveDirectory)
              .buttonStyle(.bordered)
          }
        }
        .help((prefs.saveDirectoryPath as NSString).abbreviatingWithTildeInPath)
        SettingsRow("保存时同时复制到剪贴板", isOn: bind(\.saveAlsoCopiesToClipboard))
      }

      SettingsSection("标注默认样式") {
        SettingsRow(title: "默认颜色", subtitle: "新建标注的描边与文字颜色。") {
          ColorPicker("", selection: Binding(
            get: { Color(prefs.annotationColor.nsColor) },
            set: { newValue in
              if let resolved = AnnotationColor(resolving: NSColor(newValue)) {
                updatePrefs { $0.screenshot.annotationColor = resolved }
              }
            }
          ))
          .labelsHidden()
        }
        SettingsRow(title: "线宽") {
          segmented(bind(\.annotationLineWidth), [1, 3, 5]) { "\(Int($0))" }
        }
        SettingsRow(title: "字号") {
          segmented(bind(\.annotationFontSize), [14, 18, 24, 32]) { "\(Int($0))" }
        }
        SettingsRow(title: "高亮透明度") {
          opacitySlider(bind(\.annotationHighlightOpacity), in: 0.15...0.65)
        }
        SettingsRow(title: "马赛克粒度") {
          segmented(bind(\.annotationMosaicBlockSize), [8, 12, 16, 24])
        }
        SettingsRow(title: "填充透明度", subtitle: "形状内部填充,0 为空心。") {
          opacitySlider(bind(\.annotationFillOpacity), in: 0...1)
        }
      }

      SettingsSection("选区") {
        SettingsRow(
          "取色放大镜",
          subtitle: "截图会话中鼠标附近显示像素放大、HEX 色值与坐标。",
          isOn: bind(\.showMagnifier)
        )
      }

      DebugSection(
        isOn: Binding(
          get: { prefs.debugLoggingEnabled },
          set: { v in
            updatePrefs { $0.screenshot.debugLoggingEnabled = v }
            ScreenshotDebugLog.setEnabled(v)
          }
        ),
        logURL: ScreenshotDebugLog.fileURL,
        help: "把截图会话、窗口识别等细节写入日志文件,排查问题时开启;反馈问题时附上日志更精准。"
      )
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .gestureStoreDidChange)
    ) { _ in
      prefs = store.preferences.screenshot
      screenRecordingTrusted = PermissionManager.isScreenRecordingTrusted
    }
  }

  /// 数字档位分段(线宽 / 字号 / 马赛克粒度)。
  private func segmented<V: Hashable>(
    _ selection: Binding<V>,
    _ values: [V],
    title: @escaping (V) -> String = { "\($0)" }
  ) -> some View {
    Picker("", selection: selection) {
      ForEach(values, id: \.self) { Text(title($0)).tag($0) }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
  }

  /// 透明度滑杆 + 百分比读数,供高亮/填充复用。
  private func opacitySlider(_ value: Binding<CGFloat>, in range: ClosedRange<CGFloat>) -> some View {
    HStack(spacing: 10) {
      Slider(value: value, in: range)
        .frame(width: 160)
        .controlSize(.small)
      Text(String(format: "%.0f%%", value.wrappedValue * 100))
        .font(.mgMeta)
        .foregroundStyle(Color.mgText2)
        .frame(width: 40, alignment: .trailing)
    }
  }

  // MARK: - 辅助

  private func bind<V>(_ keyPath: WritableKeyPath<ScreenshotPreferences, V>) -> Binding<V> {
    Binding(
      get: { prefs[keyPath: keyPath] },
      set: { v in updatePrefs { $0.screenshot[keyPath: keyPath] = v } }
    )
  }

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
}
