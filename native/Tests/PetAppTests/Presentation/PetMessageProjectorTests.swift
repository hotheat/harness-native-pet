import AppKit
@testable import PetCore
import Testing
@testable import DSHNativePet

@Suite("文案投影", .serialized)
@MainActor
struct PetMessageProjectorTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private let width = PetPreferences.Size.medium.panelSize.width - 14

    private func bubble(_ state: PetPresentation, pose: PetPose? = nil, error: String? = nil) -> String {
        PetMessageProjector.bubble(state, pose: pose ?? state.pose, bubbleWidth: width, connectionError: error)
    }

    private func session(_ id: String = "s", phase: SessionPhase, title: String? = nil, outcome: String? = nil) -> SessionSnapshot {
        SessionSnapshot(sessionId: id, turn: 1, phase: phase, activeTools: phase == .working ? 1 : 0,
                        pendingApprovals: phase == .waiting ? 1 : 0,
                        result: outcome.map { SessionResult(id: "r-\(id)", outcome: $0) }, title: title)
    }

    private func snapshot(_ sessions: [SessionSnapshot], seq: Int = 1) -> SourceSnapshot {
        SourceSnapshot(sourceId: "dsh", sourceLabel: "Custom DSH", seq: seq, sessions: sessions)
    }

    @Test func waitingSummaryAndSessionRowsShareFacts() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .waiting), session("work", phase: .working)]), at: now)
        let state = store.presentation(at: now)
        #expect(bubble(state) == "1 个会话待处理，请查看 Custom DSH，1 个仍在执行")
        #expect(PetMessageProjector.summary(state) == "Custom DSH · 来源 1 · 活动 1 · 等待 1")
        let row = PetMessageProjector.sessionRow(state.sessions[0])
        #expect(row.title == "Custom DSH · s")
        #expect(row.detail == "等待决定，请在宿主查看 · 工具 0 · 待决定 1")
        #expect(row.id == PetMessageProjector.rowID(sourceId: "dsh", sessionId: "s"))
        store.apply(snapshot([session(phase: .waiting, title: "修复登录")], seq: 2), at: now)
        #expect(bubble(store.presentation(at: now)) == "「修复登录」等待确认")
    }

    @Test func idleSleepStaleAndConnectionError() {
        let store = PetStore()
        let empty = store.presentation(at: now)
        #expect(bubble(empty) == "未连接宿主")
        #expect(bubble(empty, pose: .sleeping) == "休息中 · 暂无宿主状态")
        #expect(PetMessageProjector.summary(empty) == "暂无宿主状态")
        store.apply(PetActivityEvent(provider: .codex, sessionId: "s", turnId: "t", eventId: "e",
                                     kind: .running, occurredAt: 1000, toolId: nil), at: now)
        #expect(bubble(store.presentation(at: now), pose: .sleeping) == "休息中")
        let stale = store.presentation(at: now.addingTimeInterval(901))
        #expect(bubble(stale) == "状态待确认")
        #expect(PetMessageProjector.sessionRow(stale.sessions[0]).detail == "状态待确认")
        #expect(bubble(stale, error: "socket error") == "连接异常，查看菜单栏")
        #expect(bubble(empty, pose: .sleeping, error: "socket error") == "连接异常，查看菜单栏")
        #expect(PetMessageProjector.connectionError("socket error") == "连接错误：socket error")
        store.apply(PetActivityEvent(provider: .codex, sessionId: "s", turnId: "t", eventId: "close",
                                     kind: .sessionEnded, occurredAt: 1001, toolId: nil), at: now)
        #expect(bubble(store.presentation(at: now)) == "准备就绪")
    }

    @Test func snapshotOutcomesKeepDistinctBubbleAndNoticeText() throws {
        let cases: [(String, SessionPhase, String)] = [
            ("completed", .completed, "本轮回应已结束"),
            ("error", .error, "本轮回应出错，请查看 Custom DSH"),
            ("aborted", .stopped, "本轮回应已中断"),
            ("blocked", .stopped, "任务受阻，请查看 Custom DSH"),
            ("max-tokens", .stopped, "达到输出上限"),
            ("other", .stopped, "本轮已结束"),
        ]
        for (outcome, phase, expected) in cases {
            let store = PetStore()
            store.apply(snapshot([session(phase: .thinking)]), at: now)
            store.apply(snapshot([session(phase: phase, outcome: outcome)], seq: 2), at: now)
            let state = store.presentation(at: now)
            let expectedBubble = ["error", "blocked"].contains(outcome) ? expected : "Custom DSH：\(expected)"
            let view = PetView(assets: try PetAssets(skin: .character))
            view.frame = NSRect(origin: .zero, size: PetPreferences.Size.medium.panelSize)
            try view.render(pose: state.pose, text: bubble(state))
            #expect(view.displayText == expectedBubble)
            let notice = try #require(store.drainNotices(at: now).first)
            let content = PetMessageProjector.notificationContent(notice, sound: false)
            #expect(content.title == "Custom DSH 会话提醒")
            #expect(content.body == expected)
            #expect(content.userInfo == ["sourceId": "dsh", "sessionId": "s"])
            #expect(content.threadIdentifier == "dsh:s")
        }
    }

    @Test func notificationTitleIsOptInFlattenedAndLimited() {
        let cases: [(String?, String)] = [
            (nil, "DSH 会话提醒"), (" \n\t ", "DSH 会话提醒"),
            (" 私密标题\n下一行\t项目 ", "DSH · 私密标题 下一行 项目"),
            (String(repeating: "中", count: 40), "DSH · " + String(repeating: "中", count: 40)),
            (String(repeating: "中", count: 41), "DSH · " + String(repeating: "中", count: 40) + "…"),
        ]
        for (title, expected) in cases {
            for kind in [PetNoticeKind.waiting, .ended, .error, .interrupted] {
                let notice = PetNotice(id: "n", sourceId: "dsh", sourceLabel: "DSH", sessionId: "s",
                                       kind: kind, feedback: .completed, turnDuration: nil, sessionTitle: title)
                let off = PetMessageProjector.notificationContent(notice, sound: false)
                let on = PetMessageProjector.notificationContent(notice, sound: false, showSessionTitle: true)
                #expect(off.title == "DSH 会话提醒")
                #expect(on.title == expected)
                #expect(on.body == off.body)
                #expect(!on.body.contains("私密标题") && !on.body.contains(String(repeating: "中", count: 40)))
                #expect(on.userInfo == off.userInfo)
                #expect(on.threadIdentifier == off.threadIdentifier)
                #expect(on.sound == off.sound)
            }
        }
    }

    @Test func endedNoticeWithoutFeedbackUsesOtherText() {
        let notice = PetNotice(id: "n", sourceId: "dsh", sourceLabel: "DSH", sessionId: "s",
                               kind: .ended, feedback: nil, turnDuration: nil)
        let content = PetMessageProjector.notificationContent(notice, sound: false)
        #expect(content.body == "本轮已结束")
        #expect(content.userInfo == ["sourceId": "dsh", "sessionId": "s"])
    }

    @Test func hookNoticeFourKindsAndPrivacy() throws {
        for (kind, body) in [(PetActivityKind.waiting, "有待处理请求，请查看 Claude Code"),
                             (.turnEnded, "本轮回应已结束"), (.failed, "本轮回应出错，请查看 Claude Code"),
                             (.interrupted, "本轮回应已中断")] {
            let store = PetStore()
            store.apply(PetActivityEvent(provider: .claudeCode, sessionId: "s", turnId: "t", eventId: "e",
                                         kind: kind, occurredAt: 1000, toolId: nil, label: "私密标题"), at: now)
            let notice = try #require(store.drainNotices(at: now.addingTimeInterval(0.4)).first)
            let content = PetMessageProjector.notificationContent(notice, sound: kind == .waiting || kind == .failed)
            #expect(content.title == "Claude Code 会话提醒")
            #expect(content.body == body)
            #expect(!content.title.contains("私密标题") && !content.body.contains("私密标题"))
            #expect(content.userInfo == ["sourceId": "hook:claudeCode", "sessionId": "s"])
            #expect(content.threadIdentifier == "hook:claudeCode:s")
        }
    }

    @Test func completedTitleAndParallelCompletion() {
        for title in [nil, "整理资料"] as [String?] {
            for phase in [SessionPhase.idle, .working, .thinking] {
                let store = PetStore()
                let other = session("other", phase: phase)
                store.apply(snapshot([session(phase: .thinking, title: title), other]), at: now)
                store.apply(snapshot([session(phase: .completed, title: title, outcome: "completed"), other], seq: 2), at: now)
                let expected: String
                if phase == .idle {
                    expected = title == nil ? "Custom DSH：本轮回应已结束" : "「整理资料」已完成"
                } else {
                    let remaining = phase == .working ? "执行中" : "思考中"
                    expected = title == nil ? "Custom DSH\n本轮结束 · 1 \(remaining)" : "「整理资料」\n本轮结束 · 1 \(remaining)"
                }
                #expect(bubble(store.presentation(at: now)) == expected)
            }
        }
    }
    @Test func temporaryPosesKeepAggregateTextAndNoTitleFeedbackWorks() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .waiting, title: "私密标题")]), at: now)
        for pose in [PetPose.poke, .drag] {
            #expect(bubble(store.presentation(at: now), pose: pose) == "1 个会话待处理，请查看 Custom DSH")
        }
        let noSource = PetPresentation(pose: .completed, activeCount: 0, waitingCount: 0, connectedSources: 0,
                                       sessions: [], feedback: PresentedFeedback(pose: .completed, kind: .completed, sourceLabel: nil))
        #expect(bubble(noSource) == "本轮回应已结束")
        let parallel = PetPresentation(pose: .working, activeCount: 1, waitingCount: 0, connectedSources: 1,
                                       sessions: [], feedback: noSource.feedback)
        #expect(bubble(parallel) == "本轮回应已结束，1 执行中")
        #expect(bubble(parallel, pose: .poke) == "本轮回应已结束，1 个会话仍在执行")
    }

    @Test func phaseLabelsAndSystemAdapterKeepProjectedContent() throws {
        let phases: [(SessionPhase, String)] = [(.idle, "空闲"), (.running, "执行中"), (.thinking, "思考中"),
            (.working, "处理工具"), (.waiting, "等待决定，请在宿主查看"), (.completed, "本轮回应已结束"),
            (.error, "执行失败"), (.stopped, "已停止")]
        for (phase, expected) in phases { #expect(PetMessageProjector.phaseTitle(phase) == expected) }
        let store = PetStore()
        store.apply(PetActivityEvent(provider: .codex, sessionId: "s", turnId: "t", eventId: "fail",
                                     kind: .failed, occurredAt: 1000, toolId: nil), at: now)
        let notice = try #require(store.drainNotices(at: now).first)
        let projected = PetMessageProjector.notificationContent(notice, sound: true)
        let delivered = SystemPetNotificationAdapter.content(for: projected)
        #expect(delivered.title == projected.title)
        #expect(delivered.body == projected.body)
        #expect(delivered.sound != nil)
        #expect(delivered.threadIdentifier == projected.threadIdentifier)
        #expect(delivered.userInfo as? [String: String] == projected.userInfo)
    }

}
