import AppKit
import SwiftUI
import PetCore

struct SettingsView: View {
    @ObservedObject var preferences: PetPreferences
    @ObservedObject var status: PetStatusModel
    @ObservedObject var hostConnections: HostConnectionModel

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onAppear { if let id = status.focusedSessionID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: status.focusedSessionID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
        }
        .frame(width: 430, height: 640)
    }

    private var form: some View {
        Form {
            Section("桌宠") {
                Toggle("显示桌宠", isOn: $preferences.visible)
                Toggle("点击穿透", isOn: $preferences.clickThrough)
                Toggle("播放动画", isOn: $preferences.animations)
                Picker("角色", selection: $preferences.skin) {
                    ForEach(PetSkin.allCases) { skin in Text(skin.title).tag(skin) }
                }.pickerStyle(.segmented)
                Picker("大小", selection: $preferences.size) {
                    ForEach(PetPreferences.Size.allCases) { size in Text(size.title).tag(size) }
                }.pickerStyle(.segmented)
                Text("穿透后可从菜单栏恢复交互。\n60 秒无活动和自身交互后休息。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("通知") {
                Toggle("系统通知", isOn: $preferences.systemNotifications)
                Toggle("在通知中显示会话标题", isOn: $preferences.notificationSessionTitle)
                Text("标题可能由提示词生成，默认关闭。").font(.caption).foregroundStyle(.secondary)
                Text(status.notificationAuthorization.title).font(.caption).foregroundStyle(.secondary)
                if status.notificationAuthorization == .denied {
                    Button("打开系统通知设置…") { PetNotificationAuthorization.openSettings() }
                }
                if let error = status.notificationError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("宿主连接") {
                Text(status.summary)
                if let error = status.connectionError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if let warning = status.protocolWarning {
                    Text(warning).foregroundStyle(.orange).textSelection(.enabled)
                }
                HostConnectionView(model: hostConnections)
                Text(status.socketPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("会话状态") {
                if status.sessionRows.isEmpty {
                    Text("暂无会话状态").foregroundStyle(.secondary)
                } else {
                    ForEach(status.sessionRows) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).font(.system(.caption, design: .monospaced))
                            Text(session.detail).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(status.focusedSessionID == session.id ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .id(session.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
