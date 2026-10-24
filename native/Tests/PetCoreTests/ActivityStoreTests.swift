import Foundation
import Testing
@testable import PetCore

@MainActor
struct ActivityStoreTests {
    let now = Date(timeIntervalSince1970: 1000)

    private func event(_ kind: PetActivityKind, id: String = UUID().uuidString, provider: PetProvider = .codex,
                       session: String = "same", turn: String? = "t1", tool: String? = nil, time: Double = 1000) -> PetActivityEvent {
        PetActivityEvent(provider: provider, sessionId: session, turnId: turn, eventId: id,
                         kind: kind, occurredAt: time, toolId: tool)
    }

    @Test func firstStopNotifiesOnceAndDoesNotClaimSuccess() {
        let store = PetStore()
        let stop = event(.turnEnded, id: "stop")
        store.apply(stop, at: now)
        store.apply(stop, at: now)
        store.apply(event(.turnEnded, id: "different-stop"), at: now)
        let notices = store.drainNotices(at: now)
        #expect(notices.count == 1)
        #expect(notices.first?.kind == .ended)
        #expect(notices.first?.sourceLabel == "Codex")
        #expect(notices.first?.body == "本轮回应已结束")
        #expect(store.drainNotices(at: now).isEmpty)
    }

    @Test func sessionStartIsIdleAndSameSessionAcrossProvidersIsDistinct() {
        let store = PetStore()
        store.apply(event(.sessionStarted, provider: .claudeCode, turn: nil), at: now)
        #expect(store.presentation(at: now).pose == .idle)
        store.apply(event(.turnStarted), at: now)
        let sessions = store.presentation(at: now).sessions
        #expect(sessions.count == 2)
        #expect(Set(sessions.map(\.sourceId)) == ["hook:codex", "hook:claudeCode"])
        #expect(store.presentation(at: now).activeCount == 1)
    }

    @Test func parallelToolsAndFinishBeforeStartAreCountedByIdentity() {
        let store = PetStore()
        store.apply(event(.turnStarted), at: now)
        store.apply(event(.toolStarted, tool: "a"), at: now)
        store.apply(event(.toolStarted, tool: "a"), at: now)
        store.apply(event(.toolStarted, tool: "b"), at: now)
        #expect(store.presentation(at: now).sessions.first?.activeTools == 2)
        store.apply(event(.toolFinished, tool: "a"), at: now)
        store.apply(event(.toolFinished, tool: "late"), at: now)
        store.apply(event(.toolStarted, tool: "late"), at: now)
        #expect(store.presentation(at: now).sessions.first?.activeTools == 1)
        store.apply(event(.toolFinished, tool: "b"), at: now)
        #expect(store.presentation(at: now).pose == .thinking)
        #expect(store.presentation(at: now).sessions.first?.activeTools == 0)
    }

    @Test func endedTurnCannotBeReactivatedAndOldTurnCannotEndNewTurn() {
        let store = PetStore()
        store.apply(event(.turnStarted), at: now)
        store.apply(event(.turnEnded), at: now)
        store.apply(event(.toolStarted, tool: "late", time: 1001), at: now)
        #expect(store.presentation(at: now).pose == .completed)
        store.apply(event(.turnStarted, turn: "t2", time: 1002), at: now)
        store.apply(event(.turnEnded, turn: "t1", time: 1003), at: now)
        store.apply(event(.toolStarted, turn: "t1", tool: "late", time: 1004), at: now)
        #expect(store.presentation(at: now).pose == .thinking)
        #expect(store.drainNotices(at: now).count == 1)
    }

    @Test func waitingDebouncesCancelsAndNotifiesOnce() {
        let store = PetStore()
        store.apply(event(.waiting), at: now)
        #expect(store.presentation(at: now).waitingCount == 0)
        #expect(store.drainNotices(at: now.addingTimeInterval(0.2)).isEmpty)
        store.apply(event(.running), at: now.addingTimeInterval(0.25))
        #expect(store.drainNotices(at: now.addingTimeInterval(1)).isEmpty)
        store.apply(event(.waiting), at: now.addingTimeInterval(2))
        #expect(store.drainNotices(at: now.addingTimeInterval(2.31)).map(\.kind) == [.waiting])
        #expect(store.presentation(at: now.addingTimeInterval(2.31)).pose == .waiting)
        #expect(store.drainNotices(at: now.addingTimeInterval(3)).isEmpty)
        store.apply(event(.turnEnded), at: now.addingTimeInterval(4))
        #expect(store.drainNotices(at: now.addingTimeInterval(4)).map(\.kind) == [.ended])
    }

    @Test func fastWaitingThenStopOnlyNotifiesStop() {
        let store = PetStore()
        store.apply(event(.waiting), at: now)
        store.apply(event(.turnEnded), at: now.addingTimeInterval(0.1))
        #expect(store.drainNotices(at: now.addingTimeInterval(1)).map(\.kind) == [.ended])
    }

    @Test func olderControlAndToolFactsCannotOverrideNewerWaitingState() {
        let store = PetStore()
        store.apply(event(.turnStarted, time: 1000), at: now)
        store.apply(event(.toolStarted, tool: "a", time: 1001), at: now)
        store.apply(event(.waiting, time: 1003), at: now)
        store.apply(event(.toolFinished, tool: "a", time: 1002), at: now)
        store.apply(event(.running, time: 1001), at: now)
        store.apply(event(.turnStarted, time: 1000), at: now)
        #expect(store.presentation(at: now.addingTimeInterval(1)).pose == .waiting)
        #expect(store.presentation(at: now.addingTimeInterval(1)).sessions.first?.activeTools == 0)
        #expect(store.drainNotices(at: now.addingTimeInterval(1)).map(\.kind) == [.waiting])
        store.apply(event(.running, time: 1004), at: now.addingTimeInterval(2))
        store.apply(event(.waiting, time: 1003), at: now.addingTimeInterval(3))
        #expect(store.presentation(at: now.addingTimeInterval(4)).pose == .working)
        #expect(store.drainNotices(at: now.addingTimeInterval(4)).isEmpty)
    }

    @Test func sessionExitKeepsCompletionNoticeAndRejectsLateTools() {
        let store = PetStore()
        store.apply(event(.turnEnded), at: now)
        store.apply(event(.sessionEnded, turn: nil, time: 1001), at: now)
        store.apply(event(.toolStarted, tool: "late", time: 1002), at: now)
        #expect(store.presentation(at: now).sessions.isEmpty)
        #expect(store.presentation(at: now).activeCount == 0)
        #expect(store.drainNotices(at: now).map(\.kind) == [.ended])
    }

    @Test func completionNoticeSurvivesOtherActiveSessionAndSessionExit() {
        let store = PetStore()
        store.apply(event(.toolStarted, provider: .claudeCode, tool: "work"), at: now)
        store.apply(event(.turnEnded), at: now)
        store.apply(event(.sessionEnded), at: now)
        #expect(store.presentation(at: now).pose == .working)
        let notices = store.drainNotices(at: now)
        #expect(notices.count == 1)
        #expect(notices.first?.sourceLabel == "Codex")
    }

    @Test func toolFailureDoesNotFailWholeTurn() {
        let store = PetStore()
        store.apply(event(.toolStarted, tool: "tool"), at: now)
        store.apply(event(.failed, tool: "tool"), at: now)
        #expect(store.drainNotices(at: now).isEmpty)
        #expect(store.presentation(at: now).pose == .thinking)
        store.apply(event(.failed, provider: .claudeCode), at: now)
        #expect(store.drainNotices(at: now).first?.body.contains("Claude Code") == true)
    }

    @Test func staleHookBecomesNeutralWithoutInventingCompletionAndEventuallyPrunes() {
        let store = PetStore()
        store.apply(event(.toolStarted, tool: "tool"), at: now)
        let stale = store.presentation(at: now.addingTimeInterval(901))
        #expect(stale.pose == .idle)
        #expect(stale.text == "状态待确认")
        #expect(stale.sessions.first?.isStale == true)
        #expect(stale.activeCount == 0)
        #expect(store.drainNotices(at: now.addingTimeInterval(901)).isEmpty)
        #expect(store.presentation(at: now.addingTimeInterval(86_401)).sessions.isEmpty)
    }

    @Test func dshBaselineSilentAndResultNoticeIndependentFromPose() {
        let store = PetStore()
        func snapshot(_ seq: Int, _ phase: SessionPhase, _ result: SessionResult? = nil) -> SourceSnapshot {
            SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: seq,
                           sessions: [SessionSnapshot(sessionId: "same", turn: 1, phase: phase, activeTools: 0, pendingApprovals: 0, result: result)])
        }
        store.apply(snapshot(1, .thinking), at: now)
        store.apply(event(.toolStarted, tool: "busy"), at: now)
        store.apply(snapshot(2, .completed, SessionResult(id: "done", outcome: "completed")), at: now)
        #expect(store.presentation(at: now).pose == .working)
        #expect(store.drainNotices(at: now).map(\.sourceLabel) == ["DSH"])
        store.disconnect(sourceID: "dsh", at: now)
        store.apply(snapshot(1, .completed, SessionResult(id: "done", outcome: "completed")), at: now)
        #expect(store.drainNotices(at: now).isEmpty)
    }

    @Test func idleHistoryIsBoundedWhileActiveSessionIsRetained() {
        let store = PetStore()
        store.apply(event(.turnStarted, session: "active"), at: now)
        for index in 0..<300 {
            store.apply(event(.sessionStarted, session: "idle-\(index)", turn: nil), at: now.addingTimeInterval(Double(index + 1)))
        }
        let value = store.presentation(at: now.addingTimeInterval(301))
        #expect(value.sessions.count <= 256)
        #expect(value.sessions.contains { $0.sessionId == "active" && $0.phase == .thinking })
    }
}
