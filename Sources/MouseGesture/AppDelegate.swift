import AppKit
import Foundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = GestureStore.shared
    private let inputSubsystemEnabled = true
    private var eventTapManager: EventTapManager?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var lastStatus = "正在启动"
    private var lastGesture = "暂无手势"
    private var isListenerRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if inputSubsystemEnabled {
            configureInputSubsystem()
        } else {
            lastStatus = "输入监听已禁用"
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange),
            name: .gestureStoreDidChange,
            object: store
        )

        configureStatusItem()
    }

    private func configureInputSubsystem() {
        let manager = EventTapManager()
        eventTapManager = manager

        manager.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.lastStatus = status
                self?.rebuildStatusMenu()
            }
        }

        manager.onGestureMatch = { [weak self] match in
            DispatchQueue.main.async {
                if let match {
                    self?.lastGesture = "\(match.command.name) -> \(match.command.shortcut?.displayName ?? "未设置")"
                } else {
                    self?.lastGesture = "未识别到手势"
                }
                self?.rebuildStatusMenu()
            }
        }

        if store.preferences.gesturesEnabled {
            startListener()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopListener()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func configureStatusItem() {
        if store.preferences.showMenuBarIcon {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "VibeGestures") {
                    image.isTemplate = true
                    statusItem?.button?.image = image
                } else {
                    statusItem?.button?.title = "VibeGestures"
                }
            }
            rebuildStatusMenu()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func rebuildStatusMenu() {
        guard let statusItem else {
            return
        }

        let menu = NSMenu()

        let status = NSMenuItem(title: "状态：\(lastStatus)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let gesture = NSMenuItem(title: "最近：\(lastGesture)", action: nil, keyEquivalent: "")
        gesture.isEnabled = false
        menu.addItem(gesture)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "打开手势管理", action: #selector(openSettings), keyEquivalent: ","))

        let enabledItem = NSMenuItem(title: inputSubsystemEnabled ? "启用手势监听" : "启用手势监听（暂不可用）", action: #selector(toggleGesturesEnabled), keyEquivalent: "")
        enabledItem.state = store.preferences.gesturesEnabled ? .on : .off
        enabledItem.isEnabled = inputSubsystemEnabled
        menu.addItem(enabledItem)

        let targetItem = NSMenuItem(title: "手势作用目标：\(store.preferences.gestureTargetPolicy.displayName)", action: nil, keyEquivalent: "")
        targetItem.isEnabled = false
        menu.addItem(targetItem)

        let trailItem = NSMenuItem(title: "显示手势轨迹", action: #selector(toggleTrail), keyEquivalent: "")
        trailItem.state = store.preferences.showTrail ? .on : .off
        menu.addItem(trailItem)

        let permissionItem = NSMenuItem(title: "打开权限设置", action: #selector(openPermissions), keyEquivalent: "")
        menu.addItem(permissionItem)

        menu.addItem(NSMenuItem(title: "重启监听", action: #selector(restartListener), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func storeDidChange() {
        guard inputSubsystemEnabled else {
            configureStatusItem()
            return
        }

        if store.preferences.gesturesEnabled && !isListenerRunning {
            startListener()
        } else if !store.preferences.gesturesEnabled && isListenerRunning {
            stopListener()
            lastStatus = "手势监听已关闭"
        }
        configureStatusItem()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsRootView())
            let window = NSWindow(contentViewController: controller)
            window.title = ""
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.minSize = NSSize(width: 1100, height: 720)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleTrail() {
        store.updatePreferences { preferences in
            preferences.showTrail.toggle()
        }
    }

    @objc private func toggleGesturesEnabled() {
        guard inputSubsystemEnabled else {
            lastStatus = "输入监听已禁用"
            rebuildStatusMenu()
            return
        }

        store.updatePreferences { preferences in
            preferences.gesturesEnabled.toggle()
        }
    }

    @objc private func openPermissions() {
        PermissionManager.openPrivacySettings()
    }

    @objc private func restartListener() {
        if inputSubsystemEnabled && store.preferences.gesturesEnabled {
            stopListener()
            lastStatus = "正在重启监听"
            startListener()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func startListener() {
        guard inputSubsystemEnabled else {
            lastStatus = "输入监听已禁用"
            rebuildStatusMenu()
            return
        }
        guard !isListenerRunning else {
            return
        }
        isListenerRunning = eventTapManager?.start() == true
    }

    private func stopListener() {
        eventTapManager?.stop()
        isListenerRunning = false
    }
}
