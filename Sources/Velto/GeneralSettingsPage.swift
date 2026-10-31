import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 通用设置页。改动即时保存。
struct GeneralSettingsPage: View {
  private let store = ConfigStore.shared

  // 登录项 / 权限都是系统状态,回到前台时重读(从系统设置授权回来即刷新)。
  @State private var loginItem = LoginItemManager.isEnabled
  @State private var axTrusted = PermissionManager.isAccessibilityTrusted
  @State private var screenTrusted = PermissionManager.isScreenRecordingTrusted
  @State private var showingImportConfirm = false
  @State private var showingError = false
  @State private var errorMessage = ""
  @State private var statusMessage = ""
  @State private var pendingImportURL: URL?

  var body: some View {
    SettingsPage {
      PageHeader(page: .general, subtitle: "调整应用行为与数据备份。")

      SettingsSection("行为") {
        SettingsRow("开机自动启动", subtitle: "登录 Mac 后自动在后台运行。", isOn: Binding(
          get: { loginItem },
          set: { v in
            do {
              try LoginItemManager.setEnabled(v)
            } catch {
              errorMessage = "无法更新开机启动:\(error.localizedDescription)"
              showingError = true
            }
            refresh()
          }
        ))
        SettingsRow(
          "显示菜单栏图标",
          subtitle: "隐藏后再次打开 Velto(启动台或聚焦搜索)即可回到设置。",
          isOn: Binding(
            get: { store.preferences.showMenuBarIcon },
            set: { v in store.updatePreferences { $0.showMenuBarIcon = v } }
          )
        )
      }

      SettingsSection("权限") {
        permissionRow(
          "辅助功能",
          subtitle: "监听手势与快捷键、移动窗口等核心功能都需要。",
          granted: axTrusted,
          pane: "Privacy_Accessibility"
        )
        permissionRow(
          "屏幕录制",
          subtitle: "窗口切换缩略图和截图需要;授权后重启 Velto 生效。",
          granted: screenTrusted,
          pane: "Privacy_ScreenCapture"
        )
      }

      SettingsSection("配置") {
        SettingsRow(
          title: "备份配置",
          subtitle: statusMessage.isEmpty ? "包含全部模块设置,开机自动启动除外。" : statusMessage
        ) {
          HStack(spacing: 8) {
            Button("导入…", action: importConfiguration)
              .buttonStyle(.bordered)
            Button("导出…", action: exportConfiguration)
              .buttonStyle(.bordered)
          }
        }
        .help("配置文件几乎包含全部模块设置:鼠标手势、鼠标控制、窗口管理、切换器、输入法切换、按键映射、截图、网络监控与增强Finder,以及识别参数和菜单栏等通用偏好;开机自动启动属于系统登录项,不随配置导入导出。")
      }

      SettingsSection("日志") {
        SettingsRow(title: "日志文件夹", subtitle: "各模块的调试日志都写在这里,调试开关在各自页面。") {
          Button("在访达中显示", action: revealDebugLog)
            .buttonStyle(.bordered)
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refresh()
    }
    .confirmationDialog(
      "导入配置会覆盖当前全部配置",
      isPresented: $showingImportConfirm,
      titleVisibility: .visible
    ) {
      Button("导入", role: .destructive) { performImport() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("会覆盖鼠标手势、鼠标控制、窗口管理、切换器、输入法切换、按键映射、截图、网络监控、增强Finder 及通用偏好等全部模块配置。建议先导出当前配置作为备份。")
    }
    .alert("操作失败", isPresented: $showingError) {
      Button("好") {}
    } message: {
      Text(errorMessage)
    }
  }

  /// 权限行:授权状态 + 跳到系统设置对应面板。
  private func permissionRow(_ title: String, subtitle: String, granted: Bool, pane: String) -> some View {
    SettingsRow(title: title, subtitle: subtitle) {
      HStack(spacing: 4) {
        Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
          .foregroundStyle(granted ? Color.green : Color.orange)
        Text(granted ? "已授权" : "未授权")
          .foregroundStyle(Color.mgText2)
      }
      .font(.mgMeta)
      Button("前往设置") { PermissionManager.openPrivacySettings(pane) }
        .buttonStyle(.bordered)
    }
  }

  private func refresh() {
    loginItem = LoginItemManager.isEnabled
    axTrusted = PermissionManager.isAccessibilityTrusted
    screenTrusted = PermissionManager.isScreenRecordingTrusted
  }

  /// 在访达里定位诊断日志;文件还没生成时,退而打开其所在目录。
  private func revealDebugLog() {
    let url = DebugLog.fileURL
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      NSWorkspace.shared.open(dir)
    }
  }

  // MARK: - 导入 / 导出

  private func importConfiguration() {
    let panel = NSOpenPanel()
    panel.title = "导入 Velto 配置"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    pendingImportURL = url
    showingImportConfirm = true
  }

  private func performImport() {
    guard let url = pendingImportURL else { return }
    pendingImportURL = nil
    do {
      let data = try Data(contentsOf: url)
      try store.importBackupData(data)
      statusMessage = "配置已导入:\(url.lastPathComponent)"
    } catch {
      errorMessage = error.localizedDescription
      showingError = true
    }
  }

  private func exportConfiguration() {
    let panel = NSSavePanel()
    panel.title = "导出 Velto 配置"
    panel.nameFieldStringValue = "Velto-Backup.json"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try store.exportBackupData()
      try data.write(to: url, options: .atomic)
      statusMessage = "配置已导出:\(url.lastPathComponent)"
    } catch {
      errorMessage = error.localizedDescription
      showingError = true
    }
  }
}
