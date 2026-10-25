import Foundation
import Testing
@testable import PetCore

@MainActor
struct PetStoreTests {
    private let now = Date(timeIntervalSince1970: 1000)

    private func session(_ id: String = "s", phase: SessionPhase = .idle, turn: Int? = 1,
                         tools: Int = 0, approvals: Int = 0, result: SessionResult? = nil, title: String? = nil) -> SessionSnapshot {
        SessionSnapshot(sessionId: id, turn: turn, phase: phase, activeTools: tools, pendingApprovals: approvals, result: result, title: title)
    }

    private func snapshot(_ sessions: [SessionSnapshot], seq: Int = 1, source: String = "a") -> SourceSnapshot {
        SourceSnapshot(sourceId: source, sourceLabel: "DSH", seq: seq, sessions: sessions)
    }

    @Test func snapshotTitleReachesSessionsAndCompletedFeedbackWithoutChangingNotices() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .thinking, title: "初始标题")]), at: now)
        #expect(store.presentation(at: now).sessions.first?.session.title == "初始标题")
        store.apply(snapshot([session(phase: .waiting, title: "最新标题")], seq: 2), at: now)
        #expect(store.presentation(at: now).sessions.first?.session.title == "最新标题")
        #expect(store.drainNotices(at: now).first?.kind == .waiting)
        store.apply(snapshot([session(phase: .completed, result: SessionResult(id: "r", outcome: "completed"), title: "最新标题")], seq: 3), at: now)
        #expect(store.presentation(at: now).feedback?.title == "最新标题")
        #expect(store.presentation(at: now).feedback?.kind == .completed)
        let notice = store.drainNotices(at: now).first
        #expect(notice?.sourceLabel == "DSH")
        #expect(notice?.feedback == .completed)
    }

    @Test func hookLabelReachesWaitingSessionAndLatestLabelReachesCompletion() {
        for provider in [PetProvider.codex, .claudeCode] {
            let store = PetStore()
            for (index, kind, label) in [(0, PetActivityKind.turnStarted, "first" as String?),
                                          (1, .waiting, "project"), (2, .turnEnded, nil)] {
                store.apply(PetActivityEvent(provider: provider, sessionId: "s", turnId: "t", eventId: "e\(index)",
                                             kind: kind, occurredAt: 1000 + Double(index), toolId: nil, label: label), at: now)
                if kind == .waiting {
                    let waiting = store.presentation(at: now.addingTimeInterval(0.4))
                    #expect(waiting.pose == .waiting)
                    #expect(waiting.sessions.first?.session.title == "project")
                    #expect(store.drainNotices(at: now.addingTimeInterval(0.4)).first?.kind == .waiting)
                }
            }
            let completed = store.presentation(at: now)
            #expect(completed.feedback?.title == "project")
            #expect(completed.sessions.first?.session.title == "project")
            let notice = store.drainNotices(at: now).first
            #expect(notice?.sourceLabel == provider.title)
            #expect(notice?.feedback == .completed)
        }
    }

    @Test func baselineAndReconnectAreSilent() {
        let store = PetStore()
        let finished = session(phase: .completed, result: SessionResult(id: "r", outcome: "completed"))
        store.apply(snapshot([finished]), at: now)
        #expect(store.presentation(at: now).pose == .idle)
        store.disconnect(sourceID: "a", at: now)
        #expect(store.presentation(at: now).connectedSources == 0)
        #expect(!store.presentation(at: now).hasReceivedHook)
        store.apply(snapshot([finished]), at: now)
        #expect(store.presentation(at: now).pose == .idle)
    }

    @Test func completionExpiresAndIsNotReplayed() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .thinking)]), at: now)
        let completed = session(phase: .completed, result: SessionResult(id: "r", outcome: "completed"))
        store.apply(snapshot([completed], seq: 2), at: now)
        #expect(store.presentation(at: now).pose == .completed)
        #expect(store.presentation(at: now.addingTimeInterval(3.1)).pose == .idle)
        store.apply(snapshot([completed], seq: 3), at: now.addingTimeInterval(4))
        #expect(store.presentation(at: now.addingTimeInterval(4)).pose == .idle)
    }

    @Test func busySessionSurvivesOtherCompletion() {
        let store = PetStore()
        store.apply(snapshot([session("same", phase: .working, tools: 1)], source: "a"), at: now)
        store.apply(snapshot([session("same", phase: .thinking)], source: "b"), at: now)
        store.apply(snapshot([session("same", phase: .completed, result: SessionResult(id: "r", outcome: "completed"))], seq: 2, source: "b"), at: now)
        let value = store.presentation(at: now)
        #expect(value.pose == .working)
        #expect(value.activeCount == 1)
        #expect(value.connectedSources == 2)
        #expect(value.sessions.count == 2)
        #expect(value.feedback?.kind == .completed)
    }

    @Test func waitingAndWorkingAreBothVisible() {
        let store = PetStore()
        store.apply(snapshot([session("a", phase: .waiting, tools: 1, approvals: 1), session("b", phase: .working, tools: 2)]), at: now)
        let value = store.presentation(at: now)
        #expect(value.pose == .waiting)
        #expect(value.waitingCount == 1)
        #expect(value.activeCount == 1)
        #expect(value.activeCount > 0)
    }

    @Test func staleSnapshotCannotReplaceStateAndReplacementRemovesMissingSessions() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .working, tools: 1)], seq: 2), at: now)
        store.apply(snapshot([session()], seq: 1), at: now)
        #expect(store.presentation(at: now).pose == .working)
        store.apply(snapshot([], seq: 3), at: now)
        #expect(store.presentation(at: now).sessions.isEmpty)
        #expect(store.presentation(at: now).pose == .idle)
    }

    @Test func stoppedDoesNotCelebrateAndErrorsAreTransient() {
        for outcome in ["aborted", "other"] {
            let store = PetStore()
            store.apply(snapshot([session(phase: .thinking)]), at: now)
            store.apply(snapshot([session(phase: .stopped, result: SessionResult(id: "r", outcome: outcome))], seq: 2), at: now)
            #expect(store.presentation(at: now).pose == .idle)
        }
        for outcome in ["error"] {
            let store = PetStore()
            store.apply(snapshot([session(phase: .thinking)]), at: now)
            store.apply(snapshot([session(phase: .error, result: SessionResult(id: "r", outcome: outcome))], seq: 2), at: now)
            #expect(store.presentation(at: now).pose == .error)
            #expect(store.presentation(at: now.addingTimeInterval(4)).pose == .idle)
            store.disconnect(sourceID: "a", at: now)
            #expect(store.presentation(at: now).pose == .idle)
        }
    }

    @Test func pendingApprovalDoesNotBypassBridgeDebounce() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .working, tools: 1, approvals: 1)]), at: now)
        #expect(store.presentation(at: now).pose == .working)
        #expect(store.presentation(at: now).waitingCount == 0)
    }

    @Test func neutralOutcomesHaveDistinctTransientFeedback() {
        let expected: [String: PetFeedbackKind] = ["aborted": .interrupted, "blocked": .blocked,
                                                   "max-tokens": .maxTokens, "other": .other]
        for (outcome, kind) in expected {
            let store = PetStore()
            store.apply(snapshot([session(phase: .thinking)]), at: now)
            store.apply(snapshot([session(phase: .stopped, result: SessionResult(id: "r", outcome: outcome))], seq: 2), at: now)
            #expect(store.presentation(at: now).pose == .idle)
            #expect(store.presentation(at: now).feedback?.kind == kind)
            #expect(store.presentation(at: now.addingTimeInterval(4)).feedback == nil)
        }
    }

    @Test func freshActivityInvalidatesOldCompletion() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .thinking)]), at: now)
        store.apply(snapshot([session(phase: .completed, result: SessionResult(id: "r", outcome: "completed"))], seq: 2), at: now)
        store.apply(snapshot([session(phase: .thinking, turn: 2)], seq: 3), at: now.addingTimeInterval(1))
        #expect(store.presentation(at: now.addingTimeInterval(1)).feedback == nil)
    }


    @Test func oldResultIDsAreNotReplayedAndErrorWinsSimultaneousResults() {
        let store = PetStore()
        store.apply(snapshot([session("a", phase: .thinking), session("b", phase: .thinking)]), at: now)
        let error = session("a", phase: .error, result: SessionResult(id: "error-1", outcome: "error"))
        let complete = session("b", phase: .completed, result: SessionResult(id: "complete-1", outcome: "completed"))
        store.apply(snapshot([error, complete], seq: 2), at: now)
        #expect(store.presentation(at: now).pose == .error)
        store.apply(snapshot([session("a", phase: .error, result: SessionResult(id: "error-2", outcome: "error")), complete], seq: 3), at: now)
        store.apply(snapshot([error, complete], seq: 4), at: now.addingTimeInterval(4))
        #expect(store.presentation(at: now.addingTimeInterval(4)).pose == .idle)
    }


    @Test func waitingToolIsNotCountedAsExecutingSession() {
        // Real Host state while a tool awaits an approval decision.
        let store = PetStore()
        store.apply(snapshot([session(phase: .waiting, tools: 1, approvals: 1)]), at: now)
        let value = store.presentation(at: now)
        #expect(value.pose == .waiting)
        #expect(value.waitingCount == 1)
        #expect(value.activeCount == 0)
        #expect(value.activeCount == 0)
    }

    @Test func snapshotWaitingNotifiesImmediatelyOncePerContinuousEpisode() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .waiting)]), at: now)
        #expect(store.drainNotices(at: now.addingTimeInterval(1)).isEmpty)
        #expect(store.nextDeadline(after: now) == nil)
        store.apply(snapshot([session(phase: .working)], seq: 2), at: now)
        store.apply(snapshot([session(phase: .waiting)], seq: 3), at: now)
        let notices = store.drainNotices(at: now)
        #expect(notices.map(\.kind) == [.waiting])
        #expect(notices.first?.turnDuration == nil)
        store.apply(snapshot([session(phase: .waiting)], seq: 4), at: now.addingTimeInterval(1))
        #expect(store.drainNotices(at: now.addingTimeInterval(2)).isEmpty)
        store.apply(snapshot([], seq: 5), at: now.addingTimeInterval(3))
        store.apply(snapshot([session(phase: .waiting)], seq: 6), at: now.addingTimeInterval(4))
        #expect(store.drainNotices(at: now.addingTimeInterval(4)).map(\.kind) == [.waiting])
        store.disconnect(sourceID: "a", at: now)
        store.apply(snapshot([session(phase: .waiting)]), at: now)
        #expect(store.drainNotices(at: now.addingTimeInterval(1)).isEmpty)
    }

    @Test func allThreeHundredNoticesRetainTheirOrder() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .thinking)]), at: now)
        for index in 1...300 {
            store.apply(snapshot([session(phase: .completed, result: SessionResult(id: "r-\(index)", outcome: "completed"))], seq: index + 1), at: now)
        }
        #expect(store.drainNotices(at: now).map(\.id) == (1...300).map { "a:s:r-\($0)" })
    }

    @Test func continuedTurnStopsNotifyTwiceAfterToolActivity() {
        let store = PetStore()
        let kinds: [PetActivityKind] = [.turnStarted, .turnEnded, .toolStarted, .toolFinished, .turnEnded]
        for (index, kind) in kinds.enumerated() {
            store.apply(PetActivityEvent(provider: .codex, sessionId: "continued", turnId: "turn",
                                         eventId: "event-\(index)", kind: kind,
                                         occurredAt: 1000 + Double(index),
                                         toolId: kind == .toolStarted || kind == .toolFinished ? "tool" : nil),
                        at: now.addingTimeInterval(Double(index)))
        }
        let notices = store.drainNotices(at: now.addingTimeInterval(4))
        #expect(notices.map(\.kind) == [.ended, .ended])
        #expect(notices.map(\.sourceLabel) == ["Codex", "Codex"])
        #expect(notices.map(\.turnDuration) == [1, 4])
        #expect(store.presentation(at: now.addingTimeInterval(4)).pose == .completed)
    }

    @Test func nextDeadlineTracksWaitingAndFeedback() {
        let store = PetStore()
        #expect(store.nextDeadline(after: now) == nil)
        func hook(_ kind: PetActivityKind, session: String) -> PetActivityEvent {
            PetActivityEvent(provider: .codex, sessionId: session, turnId: "t", eventId: UUID().uuidString,
                             kind: kind, occurredAt: 1000, toolId: nil)
        }
        store.apply(hook(.turnEnded, session: "done"), at: now)
        #expect(store.nextDeadline(after: now) == now.addingTimeInterval(3))
        store.apply(hook(.waiting, session: "wait"), at: now)
        #expect(store.nextDeadline(after: now) == now.addingTimeInterval(0.3))
        #expect(store.nextDeadline(after: now.addingTimeInterval(0.3)) == now.addingTimeInterval(3))
        _ = store.drainNotices(at: now.addingTimeInterval(0.31))
        #expect(store.nextDeadline(after: now.addingTimeInterval(0.31)) == now.addingTimeInterval(3))
        #expect(store.nextDeadline(after: now.addingTimeInterval(3)) == nil)
        store.apply(hook(.waiting, session: "second"), at: now.addingTimeInterval(4))
        store.apply(hook(.running, session: "second"), at: now.addingTimeInterval(4.1))
        #expect(store.nextDeadline(after: now.addingTimeInterval(4.1)) == nil)
    }

    @Test func snapshotResultDurationTracksActiveTurnReceiveTime() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .thinking)]), at: now)
        store.apply(snapshot([session(phase: .waiting)], seq: 2), at: now.addingTimeInterval(2))
        #expect(store.drainNotices(at: now.addingTimeInterval(2)).first?.turnDuration == nil)
        store.apply(snapshot([session(phase: .completed, result: SessionResult(id: "r1", outcome: "completed"))], seq: 3), at: now.addingTimeInterval(12))
        #expect(store.drainNotices(at: now.addingTimeInterval(12)).first?.turnDuration == 12)
        store.apply(snapshot([session(phase: .working, turn: 2)], seq: 4), at: now.addingTimeInterval(20))
        store.apply(snapshot([session(phase: .stopped, turn: 2, result: SessionResult(id: "r2", outcome: "aborted"))], seq: 5), at: now.addingTimeInterval(24))
        #expect(store.drainNotices(at: now.addingTimeInterval(24)).first?.turnDuration == 4)
        store.disconnect(sourceID: "a", at: now)
        store.apply(snapshot([session()]), at: now)
        store.apply(snapshot([session(phase: .error, result: SessionResult(id: "unknown", outcome: "error"))], seq: 2), at: now.addingTimeInterval(10))
        #expect(store.drainNotices(at: now.addingTimeInterval(10)).first?.turnDuration == nil)
    }

    @Test func resultForUnobservedTurnHasUnknownDuration() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .thinking, turn: 1)]), at: now)
        store.apply(snapshot([session(phase: .completed, turn: 2, result: SessionResult(id: "r", outcome: "completed"))], seq: 2), at: now.addingTimeInterval(30))
        #expect(store.drainNotices(at: now.addingTimeInterval(30)).first?.turnDuration == nil)
    }

    @Test func snapshotDurationIsScopedToSourceSessionAndActiveEpisode() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .thinking), session("other", phase: .working)]), at: now)
        store.apply(snapshot([session(phase: .thinking)], source: "b"), at: now.addingTimeInterval(2))
        store.apply(snapshot([session(phase: .working, turn: 2), session("other")], seq: 2), at: now.addingTimeInterval(5))
        let result = SessionResult(id: "done", outcome: "completed")
        store.apply(snapshot([session(phase: .completed, turn: 2, result: result), session("other", phase: .completed, result: result)], seq: 3),
                    at: now.addingTimeInterval(12))
        store.apply(snapshot([session(phase: .completed, result: result)], seq: 2, source: "b"), at: now.addingTimeInterval(12))
        let notices = store.drainNotices(at: now.addingTimeInterval(12))
        #expect(notices.map(\.sourceId) == ["a", "a", "b"])
        #expect(notices.map(\.turnDuration) == [7, nil, 10])
        store.apply(snapshot([session(phase: .thinking, turn: 2)], seq: 4), at: now.addingTimeInterval(20))
        store.apply(snapshot([], seq: 5), at: now.addingTimeInterval(21))
        store.apply(snapshot([session(phase: .completed, turn: 2, result: result)], seq: 6), at: now.addingTimeInterval(30))
        #expect(store.drainNotices(at: now.addingTimeInterval(30)).first?.turnDuration == nil)
    }

    @Test func everyOutcomeCarriesStructuredNoticeAndFeedback() throws {
        let cases: [(String, PetFeedbackKind, PetNoticeKind)] = [
            ("completed", .completed, .ended), ("error", .failed, .error),
            ("aborted", .interrupted, .interrupted), ("blocked", .blocked, .ended),
            ("max-tokens", .maxTokens, .ended), ("other", .other, .ended),
        ]
        for (outcome, expectedFeedback, expectedNotice) in cases {
            let store = PetStore()
            store.apply(snapshot([session(phase: .thinking)]), at: now)
            store.apply(snapshot([session(phase: .stopped, result: SessionResult(id: "r", outcome: outcome))], seq: 2), at: now)
            let state = store.presentation(at: now)
            #expect(state.feedback?.kind == expectedFeedback)
            #expect(state.feedback?.sourceLabel == "DSH")
            let notice = try #require(store.drainNotices(at: now).first)
            #expect(notice.kind == expectedNotice)
            #expect(notice.feedback == expectedFeedback)
        }
        let store = PetStore()
        store.apply(snapshot([session(phase: .thinking)]), at: now)
        store.apply(snapshot([session(phase: .waiting)], seq: 2), at: now)
        let notice = try #require(store.drainNotices(at: now).first)
        #expect(notice.kind == .waiting && notice.feedback == nil)
    }

}
