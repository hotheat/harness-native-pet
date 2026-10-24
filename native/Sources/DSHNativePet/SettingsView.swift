import AppKit
import SwiftUI
import PetCore

@MainActor
final class PetStatusModel: ObservableObject {
    @Published var summary = "暂无宿主状态"
    @Published var sessionRows: [SessionRow] = []
    @Published var connectionError: String?
    @Published var protocolWarning: String?
    @Published var notificationAuthorization: PetNotificationAuthorization = .notDetermined
    @Published var notificationError: String?
    @Published var sourceLabels: [String] = []
    var socketPath = ""

    struct SessionRow: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    func update(_ state: PetPresentation) {
        sourceLabels = Array(Set(state.sessions.map(\.sourceLabel))).sorted()
        let hosts = sourceLabels.isEmpty ? "宿主" : sourceLabels.joined(separator: "、")
        summary = state.connectedSources == 0 ? "暂无宿主状态" : "\(hosts) · 来源 \(state.connectedSources) · 活动 \(state.activeCount) · 等待 \(state.waitingCount)"
        sessionRows = state.sessions.map { session in
            SessionRow(id: "\(session.sourceId.utf8.count):\(session.sourceId)\(session.sessionId)",
                       title: "\(session.sourceLabel) · \(session.sessionId.prefix(30))",
                       detail: session.isStale ? "状态待确认" : "\(Self.phaseTitle(session.phase)) · 工具 \(session.activeTools) · 待决定 \(session.pendingApprovals)")
        }
    }

    static func phaseTitle(_ phase: SessionPhase) -> String {
        switch phase {
        case .idle: "空闲"
        case .running: "执行中"
        case .thinking: "思考中"
        case .working: "处理工具"
        case .waiting: "等待决定，请在宿主查看"
        case .completed: "本轮回应结束"
        case .error: "执行失败"
        case .stopped: "已停止"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: PetPreferences
    @ObservedObject var status: PetStatusModel

    var body: some View {
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
                Text(status.notificationAuthorization.title).font(.caption).foregroundStyle(.secondary)
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
                Text("Codex 和 Claude Code 通过附带的 pet-hook 接入，需安装并配置宿主 hooks。")
                    .font(.caption).foregroundStyle(.secondary)
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
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 430, height: 640)
    }
}
