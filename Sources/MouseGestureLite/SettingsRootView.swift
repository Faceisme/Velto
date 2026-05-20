import SwiftUI

struct SettingsRootView: View {
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tab 控件放进内容区，避免 TabView 在 titlebar 留白
            Picker("", selection: $selectedTab) {
                Text("鼠标手势功能").tag(0)
                Text("窗口管理相关功能").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
            .padding(.vertical, 10)

            Divider()

            if selectedTab == 0 {
                GestureSettingsView()
            } else {
                WindowSettingsView()
            }
        }
        .frame(minWidth: 920, idealWidth: 960, minHeight: 580, idealHeight: 660)
    }
}
