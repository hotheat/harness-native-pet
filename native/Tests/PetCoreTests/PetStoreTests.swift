import Foundation
import Testing
@testable import PetCore

@MainActor
struct PetStoreTests {
    private let now = Date(timeIntervalSince1970: 1000)

    private func session(_ id: String = "s", phase: SessionPhase = .idle, turn: Int? = 1,
                         tools: Int = 0, approvals: Int = 0, result: SessionResult? = nil) -> SessionSnapshot {
        SessionSnapshot(sessionId: id, turn: turn, phase: phase, activeTools: tools, pendingApprovals: approvals, result: result)
    }

    private func snapshot(_ sessions: [SessionSnapshot], seq: Int = 1, source: String = "a") -> SourceSnapshot {
        SourceSnapshot(sourceId: source, sourceLabel: "DSH", seq: seq, sessions: sessions)
    }

    @Test func baselineAndReconnectAreSilent() {
        let store = PetStore()
        let finished = session(phase: .completed, result: SessionResult(id: "r", outcome: "completed"))
        store.apply(snapshot([finished]), at: now)
        #expect(store.presentation(at: now).pose == .idle)
        store.disconnect(sourceID: "a", at: now)
        #expect(store.presentation(at: now).connectedSources == 0)
        #expect(store.presentation(at: now).text == "未连接宿主")
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
        #expect(value.text.contains("已完成"))
    }

    @Test func waitingAndWorkingAreBothVisible() {
        let store = PetStore()
        store.apply(snapshot([session("a", phase: .waiting, tools: 1, approvals: 1), session("b", phase: .working, tools: 2)]), at: now)
        let value = store.presentation(at: now)
        #expect(value.pose == .waiting)
        #expect(value.waitingCount == 1)
        #expect(value.activeCount == 1)
        #expect(value.text.contains("仍在执行"))
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
        let expected = ["aborted": "任务已停止", "blocked": "任务受阻，请查看 DSH",
                        "max-tokens": "达到输出上限", "other": "本轮已结束"]
        for (outcome, text) in expected {
            let store = PetStore()
            store.apply(snapshot([session(phase: .thinking)]), at: now)
            store.apply(snapshot([session(phase: .stopped, result: SessionResult(id: "r", outcome: outcome))], seq: 2), at: now)
            #expect(store.presentation(at: now).pose == .idle)
            #expect(store.presentation(at: now).text == text)
            #expect(store.presentation(at: now.addingTimeInterval(4)).text == "准备就绪")
        }
    }

    @Test func freshActivityInvalidatesOldCompletion() {
        let store = PetStore()
        store.apply(snapshot([session(phase: .thinking)]), at: now)
        store.apply(snapshot([session(phase: .completed, result: SessionResult(id: "r", outcome: "completed"))], seq: 2), at: now)
        store.apply(snapshot([session(phase: .thinking, turn: 2)], seq: 3), at: now.addingTimeInterval(1))
        #expect(!store.presentation(at: now.addingTimeInterval(1)).text.contains("已完成"))
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
        #expect(!value.text.contains("仍在执行"))
    }

}
