import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = GestureStore.shared
    private var eventTapManager: EventTapManager?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var lastStatus = "正在启动"
    private var lastGesture = "暂无手势"
    private var isListenerRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        configureInputSubsystem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange),
            name: .gestureStoreDidChange,
            object: store
        )

        configureStatusItem()

        // 启动切换器:WindowList 后台维护 + KeyTap 接管 Cmd+Tab + Panel UI。
        // 失败一般是 CGEvent tap 权限缺失,需要用户开"输入监控"权限。
        if !SwitcherController.shared.start() {
            print("⚠️ 切换器启动失败 —— CGEvent tap 创建不成功,检查输入监控/辅助功能权限")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopListener()
        // ⚠️ 必须恢复系统 Cmd+Tab —— 它是 OS 持久状态,我们不复位的话用户下次
        // 开机系统切换器都是关的。
        SwitcherController.shared.stop()
    }

    /// `.accessory` 应用默认没有主菜单 → ⌘W / ⌘Q / 文本编辑快捷键全部失效。
    /// 这里挂上一份最小主菜单,只为让 key equivalent 路由生效;菜单本身在
    /// 菜单栏不可见(accessory 策略决定),用户感知到的就是"快捷键能用了"。
    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        // App 菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "关于 \(appName)",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            )
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(title: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(title: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 文件 — ⌘W 关闭窗口
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(
            NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        )
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // 编辑 — 让 TextField 里的剪切/拷贝/粘贴/全选/撤销正常工作
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureInputSubsystem() {
        let manager = EventTapManager()
        eventTapManager = manager

        manager.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.lastStatus = status
                self?.rebuildStatusMenu()
            }
        }

        manager.onGestureMatch = { [weak self] match in
            Task { @MainActor in
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func configureStatusItem() {
        if store.preferences.showMenuBarIcon {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "Velto") {
                    image.isTemplate = true
                    statusItem?.button?.image = image
                } else {
                    statusItem?.button?.title = "Velto"
                }
            }
            rebuildStatusMenu()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func rebuildStatusMenu() {
        guard let statusItem else { return }

        let menu = NSMenu()

        let status = NSMenuItem(title: "状态：\(lastStatus)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let gesture = NSMenuItem(title: "最近：\(lastGesture)", action: nil, keyEquivalent: "")
        gesture.isEnabled = false
        menu.addItem(gesture)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "偏好设置", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "重启监听", action: #selector(restartListener), keyEquivalent: "r"))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func storeDidChange() {
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
            // 不开启背景可拖动:否则触摸板三指拖动(辅助功能合成的拖拽)在滑块/开关
            // 等控件上会被窗口背景移动抢走,导致拖到的是窗口而不是控件。窗口是
            // .titled,仍可通过顶部标题栏区域拖动(与系统设置窗口一致)。
            window.isMovableByWindowBackground = false
            window.isOpaque = false
            window.backgroundColor = .clear
            // 关闭后不要被 AppKit 释放,这样 ⌘W / 红点关闭后还能再次打开同一窗口。
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.minSize = NSSize(width: 1100, height: 720)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func restartListener() {
        guard store.preferences.gesturesEnabled else { return }
        stopListener()
        lastStatus = "正在重启监听"
        startListener()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func startListener() {
        guard !isListenerRunning else { return }
        isListenerRunning = eventTapManager?.start() == true
    }

    private func stopListener() {
        eventTapManager?.stop()
        isListenerRunning = false
    }
}
