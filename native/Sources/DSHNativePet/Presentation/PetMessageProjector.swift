import AppKit
import PetCore

/// Projects domain facts into user-facing text; contains no state transitions.
enum PetMessageProjector {
    static let emptySummary = "暂无宿主状态"

    struct SessionRow: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    static func bubble(_ state: PetPresentation, pose: PetPose, bubbleWidth: CGFloat,
                       connectionError: String? = nil) -> String {
        if connectionError != nil { return "连接异常，查看菜单栏" }
        if pose == .sleeping { return state.connectedSources == 0 ? "休息中 · 暂无宿主状态" : "休息中" }
        if pose == .waiting {
            let waiting = state.sessions.filter { $0.session.phase == .waiting }
            let remaining = state.activeCount > 0 ? "，\(state.activeCount) 个仍在执行" : ""
            if let title = waiting.lazy.compactMap({ sessionTitle($0.session.title, limit: .max) }).first {
                let status = waiting.count == 1 ? "等待确认\(remaining)" : "等 \(state.waitingCount) 个待处理"
                return PetBubbleFit.text(title: title, status: status, bubbleWidth: bubbleWidth)
            }
            return baseBubble(state)
        }
        if state.activeCount > 0, let feedback = state.feedback, feedback.kind == .completed,
           pose == .working || pose == .thinking {
            let remaining = "\(state.activeCount) " + (pose == .working ? "执行中" : "思考中")
            if let title = sessionTitle(feedback.title, limit: .max) {
                return PetBubbleFit.text(title: title, status: "本轮结束 · \(remaining)",
                                         bubbleWidth: bubbleWidth, statusOnNewLine: true)
            }
            if let source = feedback.sourceLabel { return "\(source)\n本轮结束 · \(remaining)" }
            return "\(feedbackText(feedback.kind, sourceLabel: feedback.sourceLabel))，\(remaining)"
        }
        if pose == .completed, let title = sessionTitle(state.feedback?.title, limit: .max) {
            return PetBubbleFit.text(title: title, status: "已完成", bubbleWidth: bubbleWidth)
        }
        return baseBubble(state)
    }

    // Temporary pose overrides retain the underlying aggregate text without title layout.
    private static func baseBubble(_ state: PetPresentation) -> String {
        switch state.pose {
        case .waiting:
            let labels = Set(state.sessions.filter { $0.session.phase == .waiting }.map(\.sourceLabel)).sorted().joined(separator: "、")
            return "\(state.waitingCount) 个会话待处理，请查看 \(labels)" + (state.activeCount > 0 ? "，\(state.activeCount) 个仍在执行" : "")
        case .working, .thinking:
            if let feedback = state.feedback, feedback.kind == .completed {
                return labeledFeedback(feedback) + "，\(state.activeCount) 个会话仍在" + (state.pose == .working ? "执行" : "思考")
            }
            return state.pose == .working ? "\(state.activeCount) 个会话正在执行" : "正在思考"
        default:
            if let feedback = state.feedback { return labeledFeedback(feedback) }
            if state.sessions.contains(where: \.isStale) { return "状态待确认" }
            return !state.hasReceivedHook && state.connectedSources == 0 && state.sessions.isEmpty ? "未连接宿主" : "准备就绪"
        }
    }

    private static func labeledFeedback(_ feedback: PresentedFeedback) -> String {
        let text = feedbackText(feedback.kind, sourceLabel: feedback.sourceLabel)
        if feedback.kind == .failed || feedback.kind == .blocked { return text }
        return feedback.sourceLabel.map { "\($0)：\(text)" } ?? text
    }

    private static func feedbackText(_ kind: PetFeedbackKind, sourceLabel: String?) -> String {
        switch kind {
        case .completed: "本轮回应已结束"
        case .failed: "本轮回应出错，请查看 \(sourceLabel ?? "宿主")"
        case .interrupted: "本轮回应已中断"
        case .blocked: "任务受阻，请查看 \(sourceLabel ?? "宿主")"
        case .maxTokens: "达到输出上限"
        case .other: "本轮已结束"
        }
    }

    static func notificationContent(_ notice: PetNotice, sound: Bool, showSessionTitle: Bool = false) -> PetNotificationContent {
        let body: String
        switch notice.kind {
        case .waiting: body = "有待处理请求，请查看 \(notice.sourceLabel)"
        case .error: body = feedbackText(.failed, sourceLabel: notice.sourceLabel)
        case .interrupted: body = feedbackText(.interrupted, sourceLabel: notice.sourceLabel)
        case .ended:
            body = feedbackText(notice.feedback ?? .other, sourceLabel: notice.sourceLabel)
        }
        let title: String
        if showSessionTitle, let sessionTitle = sessionTitle(notice.sessionTitle, limit: 40) {
            title = "\(notice.sourceLabel) · \(sessionTitle)"
        } else {
            title = "\(notice.sourceLabel) 会话提醒"
        }
        return PetNotificationContent(id: notice.id, kind: notice.kind, sourceLabel: notice.sourceLabel,
                                      title: title, body: body, sound: sound,
                                      threadIdentifier: "\(notice.sourceId):\(notice.sessionId)",
                                      userInfo: ["sourceId": notice.sourceId, "sessionId": notice.sessionId])
    }

    static func summary(_ state: PetPresentation) -> String {
        let labels = Array(Set(state.sessions.map(\.sourceLabel))).sorted()
        let hosts = labels.isEmpty ? "宿主" : labels.joined(separator: "、")
        return state.connectedSources == 0 ? emptySummary : "\(hosts) · 来源 \(state.connectedSources) · 活动 \(state.activeCount) · 等待 \(state.waitingCount)"
    }

    static func sessionRow(_ presented: PresentedSession) -> SessionRow {
        let session = presented.session
        return SessionRow(id: rowID(sourceId: presented.sourceId, sessionId: session.sessionId),
                          title: "\(presented.sourceLabel) · \(sessionTitle(session.title, limit: 40) ?? String(session.sessionId.prefix(30)))",
                          detail: presented.isStale ? "状态待确认" : "\(phaseTitle(session.phase)) · 工具 \(session.activeTools) · 待决定 \(session.pendingApprovals)")
    }

    static func rowID(sourceId: String, sessionId: String) -> String {
        "\(sourceId.utf8.count):\(sourceId)\(sessionId)"
    }

    static func phaseTitle(_ phase: SessionPhase) -> String {
        switch phase {
        case .idle: "空闲"
        case .running: "执行中"
        case .thinking: "思考中"
        case .working: "处理工具"
        case .waiting: "等待决定，请在宿主查看"
        case .completed: "本轮回应已结束"
        case .error: "执行失败"
        case .stopped: "已停止"
        }
    }

    static func sessionTitle(_ title: String?, limit: Int) -> String? {
        guard let title else { return nil }
        let text = title.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    static func sourceSummary(_ labels: [String]) -> String {
        "来源：" + (labels.isEmpty ? "无" : labels.joined(separator: "、"))
    }

    static func connectionError(_ error: String?) -> String {
        error.map { "连接错误：\($0)" } ?? ""
    }

    static func notificationStatus(_ authorization: PetNotificationAuthorization) -> String {
        "通知权限：\(authorization.title)"
    }
}
