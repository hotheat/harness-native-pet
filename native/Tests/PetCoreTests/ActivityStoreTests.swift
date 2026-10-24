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
        store.apply(event(.turnEnded, id: "different-stop", time: 1001), at: now.addingTimeInterval(1))
        let notices = store.drainNotices(at: now)
        #expect(notices.count == 1)
        #expect(notices.first?.kind == .ended)
        #expect(notices.first?.sourceLabel == "Codex")
        #expect(notices.first?.body == "本轮回应已结束")
        #expect(store.drainNotices(at: now).isEmpty)
    }

    @Test func firstStopHasUnknownTurnDuration() throws {
        let store = PetStore()
        store.apply(event(.turnEnded, id: "stop"), at: now)
        let notices = store.drainNotices(at: now)
        #expect(notices.count == 1)
        #expect(try #require(notices.first).turnDuration == nil)
    }

    @Test func startedTurnRecordsMeasuredDuration() throws {
        let store = PetStore()
        store.apply(event(.turnStarted), at: now)
        store.apply(event(.turnEnded, time: 1012), at: now.addingTimeInterval(12))
        let notices = store.drainNotices(at: now.addingTimeInterval(12))
        #expect(notices.count == 1)
        #expect(try #require(notices.first).turnDuration == 12)
    }

    @Test func stopThenFailureNotifiesErrorOnceAndUpdatesFeedback() {
        let store = PetStore()
        store.apply(event(.turnEnded, id: "stop"), at: now)
        #expect(store.drainNotices(at: now).map(\.kind) == [.ended])
        store.apply(event(.failed, id: "failure", time: 1001), at: now.addingTimeInterval(1))
        #expect(store.drainNotices(at: now.addingTimeInterval(1)).map(\.kind) == [.error])
        let presentation = store.presentation(at: now.addingTimeInterval(1))
        #expect(presentation.pose == .error)
        #expect(presentation.feedback?.pose == .error)
        #expect(presentation.feedback?.text == "本轮回应出错，请查看 Codex")
        store.apply(event(.failed, id: "failure-again", time: 1002), at: now.addingTimeInterval(2))
        #expect(store.drainNotices(at: now.addingTimeInterval(2)).isEmpty)
    }

    @Test func stopThenInterruptNotifiesInterruptedOnceAndUpdatesFeedback() {
        let store = PetStore()
        store.apply(event(.turnEnded, id: "stop"), at: now)
        #expect(store.drainNotices(at: now).map(\.kind) == [.ended])
        store.apply(event(.interrupted, id: "interrupt", time: 1001), at: now.addingTimeInterval(1))
        #expect(store.drainNotices(at: now.addingTimeInterval(1)).map(\.kind) == [.interrupted])
        let presentation = store.presentation(at: now.addingTimeInterval(1))
        #expect(presentation.pose == .idle)
        #expect(presentation.sessions.first?.phase == .stopped)
        #expect(presentation.feedback?.text == "本轮回应已中断")
        store.apply(event(.interrupted, id: "interrupt-again", time: 1002), at: now.addingTimeInterval(2))
        #expect(store.drainNotices(at: now.addingTimeInterval(2)).isEmpty)
    }

    @Test func repeatedFailuresWithDifferentEventIDsNotifyOnce() {
        let store = PetStore()
        store.apply(event(.failed, id: "failure"), at: now)
        store.apply(event(.failed, id: "failure-again", time: 1001), at: now.addingTimeInterval(1))
        #expect(store.drainNotices(at: now.addingTimeInterval(1)).map(\.kind) == [.error])
        #expect(store.presentation(at: now.addingTimeInterval(1)).pose == .error)
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

    @Test func idleAndTerminalSessionsExpireWithoutBecomingStale() {
        for kind in [PetActivityKind.turnEnded, .failed, .interrupted, .sessionStarted] {
            let store = PetStore()
            store.apply(event(kind, turn: kind == .sessionStarted ? nil : "t1"), at: now)
            let value = store.presentation(at: now.addingTimeInterval(899))
            #expect(value.sessions.count == 1)
            #expect(value.sessions.first?.isStale == false)
            #expect(value.text == "准备就绪")
            let expired = store.presentation(at: now.addingTimeInterval(900))
            #expect(expired.sessions.isEmpty)
            #expect(expired.text == "准备就绪")
        }
    }

    @Test func hookReceiptKeepsEmptyStateReadyAfterCloseAndPruning() {
        let store = PetStore()
        #expect(store.presentation(at: now).text == "未连接宿主")
        store.apply(event(.sessionStarted, turn: nil), at: now)
        store.apply(event(.sessionEnded, turn: nil), at: now.addingTimeInterval(1))
        #expect(store.presentation(at: now.addingTimeInterval(1)).text == "准备就绪")
        #expect(store.presentation(at: now.addingTimeInterval(86_401)).text == "准备就绪")
    }

    @Test func hookDurationUsesEventTimeFromTurnStartAndWaitingHasNoDuration() {
        let store = PetStore()
        store.apply(event(.sessionStarted, turn: nil, time: 900), at: now)
        store.apply(event(.turnStarted), at: now.addingTimeInterval(50))
        store.apply(event(.waiting, time: 1001), at: now.addingTimeInterval(60))
        let waiting = store.drainNotices(at: now.addingTimeInterval(60.31))
        #expect(waiting.map(\.kind) == [.waiting])
        #expect(waiting.first?.turnDuration == nil)
        store.apply(event(.turnEnded, time: 1012), at: now.addingTimeInterval(100))
        #expect(store.drainNotices(at: now.addingTimeInterval(100)).first?.turnDuration == 12)
        store.apply(event(.turnStarted, turn: "t2", time: 1020), at: now.addingTimeInterval(110))
        store.apply(event(.interrupted, turn: "t2", time: 1024), at: now.addingTimeInterval(120))
        #expect(store.drainNotices(at: now.addingTimeInterval(120)).first?.turnDuration == 4)
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

    @Test func stopResumesButOldTurnCannotEndNewTurn() {
        let store = PetStore()
        store.apply(event(.turnStarted), at: now)
        store.apply(event(.turnEnded), at: now)
        store.apply(event(.toolStarted, tool: "late", time: 1001), at: now)
        #expect(store.presentation(at: now).pose == .working)
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
    @Test func stopActivityStopNotifiesAgainAndClearsFeedback() {
        for kind in [PetActivityKind.running, .toolStarted, .toolFinished, .waiting] {
            let store = PetStore()
            store.apply(event(.turnEnded), at: now)
            #expect(store.drainNotices(at: now).count == 1)
            store.apply(event(kind, tool: kind == .toolStarted || kind == .toolFinished ? "work" : nil, time: 1001), at: now.addingTimeInterval(1))
            let resumed = store.presentation(at: now.addingTimeInterval(1.31))
            #expect(resumed.sessions.first?.result == nil)
            #expect(!resumed.text.contains("结束"))
            #expect(resumed.pose == (kind == .waiting ? .waiting : kind == .running || kind == .toolStarted ? .working : .thinking))
            store.apply(event(.turnEnded, time: 1002), at: now.addingTimeInterval(2))
            #expect(store.drainNotices(at: now.addingTimeInterval(2)).map(\.kind) == [.ended])
        }
    }

    @Test func oldActivityAndFailedOrInterruptedTurnsCannotResume() {
        for terminal in [PetActivityKind.turnEnded, .failed, .interrupted] {
            let store = PetStore()
            store.apply(event(.turnStarted), at: now)
            store.apply(event(terminal, time: 1002), at: now)
            _ = store.drainNotices(at: now)
            for kind in [PetActivityKind.running, .toolStarted, .toolFinished, .waiting] {
                store.apply(event(kind, tool: "old", time: terminal == .turnEnded ? 1001 : 1003), at: now)
            }
            #expect(store.presentation(at: now).sessions.first?.phase == (terminal == .failed ? .error : terminal == .interrupted ? .stopped : .completed))
            #expect(store.drainNotices(at: now.addingTimeInterval(1)).isEmpty)
        }
    }

    @Test func unknownTurnsDoNotChangeStateOrRefreshReceiptTime() {
        let store = PetStore()
        store.apply(event(.turnStarted, turn: "t2"), at: now)
        for turn in ["t0", "t3"] {
            for kind in [PetActivityKind.toolStarted, .toolFinished, .waiting, .turnEnded, .failed, .interrupted] {
                store.apply(event(kind, turn: turn, tool: kind == .toolStarted || kind == .toolFinished ? "alien" : nil, time: 1001), at: now.addingTimeInterval(899))
            }
        }
        #expect(store.presentation(at: now).pose == .thinking)
        #expect(store.presentation(at: now.addingTimeInterval(901)).sessions.first?.isStale == true)
        #expect(store.drainNotices(at: now.addingTimeInterval(901)).isEmpty)
    }

    @Test func sessionStartCanEstablishTurnFromAnyFirstFact() {
        for kind in [PetActivityKind.toolStarted, .waiting, .turnEnded] {
            for time in [999.0, 1001.0] {
                let store = PetStore()
                store.apply(event(.sessionStarted, turn: nil), at: now)
                store.apply(event(kind, turn: "first", tool: kind == .toolStarted ? "tool" : nil, time: time), at: now)
                #expect(store.presentation(at: now.addingTimeInterval(1)).sessions.first?.phase == (kind == .toolStarted ? .working : kind == .waiting ? .waiting : .completed))
            }
        }
    }

    @Test func terminalFactsAcceptEarlierPhaseTimestamp() {
        for kind in [PetActivityKind.turnEnded, .failed, .interrupted] {
            let store = PetStore()
            store.apply(event(.turnStarted), at: now)
            store.apply(event(.waiting, time: 1003), at: now)
            store.apply(event(kind, time: 1002), at: now)
            #expect(store.presentation(at: now).sessions.first?.phase == (kind == .failed ? .error : kind == .interrupted ? .stopped : .completed))
            #expect(store.drainNotices(at: now).count == 1)
            if kind == .turnEnded {
                store.apply(event(.running, time: 1002.5), at: now)
                #expect(store.presentation(at: now).pose == .completed)
                store.apply(event(.running, time: 1003), at: now)
                #expect(store.presentation(at: now).pose == .working)
            }
        }
    }

    @Test func terminalHistoryExpiresWithoutBecomingStale() {
        for kind in [PetActivityKind.turnEnded, .failed, .interrupted] {
            let store = PetStore()
            store.apply(event(kind), at: now)
            let visible = store.presentation(at: now.addingTimeInterval(899))
            #expect(visible.sessions.count == 1)
            #expect(visible.sessions.first?.isStale == false)
            #expect(visible.connectedSources == 1)
            let expired = store.presentation(at: now.addingTimeInterval(901))
            #expect(expired.sessions.isEmpty)
            #expect(expired.connectedSources == 0)
            #expect(expired.text == "准备就绪")
            store.apply(event(kind), at: now.addingTimeInterval(902))
            #expect(store.drainNotices(at: now.addingTimeInterval(902)).count == 1)
        }
    }

}
