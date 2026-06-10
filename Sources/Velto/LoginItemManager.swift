import Foundation
import ServiceManagement

enum LoginItemManager {
  struct NotAppBundleError: LocalizedError {
    var errorDescription: String? {
      "当前是命令行裸跑模式,注册开机自启会把 .build 裸二进制写进登录项,开机会弹出终端窗口。请使用打包后的 Velto.app 操作。"
    }
  }

  /// 裸跑时 Bundle.main 指向 .build 目录而非 .app bundle,
  /// 此时 SMAppService.mainApp.register() 会把裸二进制注册成登录项,
  /// 系统开机只能用 Terminal 打开它。
  static var isAppBundle: Bool {
    Bundle.main.bundleURL.pathExtension == "app"
  }

  static var isEnabled: Bool {
    isAppBundle && SMAppService.mainApp.status == .enabled
  }

  static func setEnabled(_ enabled: Bool) throws {
    guard isAppBundle else { throw NotAppBundleError() }
    if enabled {
      if SMAppService.mainApp.status != .enabled {
        try SMAppService.mainApp.register()
      }
    } else {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      }
    }
  }
}
