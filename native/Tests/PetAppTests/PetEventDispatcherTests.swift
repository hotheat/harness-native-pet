import Foundation
import PetCore
import Testing
@testable import DSHNativePet

@Suite("IPC 到 UI 顺序", .serialized)
@MainActor
struct PetEventDispatcherTests {
    @Test func activityDeliverySurvivesShortConnectionAndRefreshesUI() async throws {
        let store = PetStore()
        let adapter = try RecordingPetNotificationAdapter()
        let notifications = PetNotificationDispatcher(adapter: adapter)
        let events = PetEventDispatcher(store: store, onUpdate: { _ in
            notifications.refresh(store: store, enabled: true)
        })
        let start = PetActivityEvent(provider: .codex, sessionId: "hook-session", turnId: "turn",
                                     eventId: "start", kind: .turnStarted, occurredAt: Date().timeIntervalSince1970, toolId: nil)
        let end = PetActivityEvent(provider: .codex, sessionId: "hook-session", turnId: "turn",
                                   eventId: "end", kind: .turnEnded, occurredAt: Date().timeIntervalSince1970, toolId: nil)
        await withCheckedContinuation { continuation in
            events.enqueue(.message(.activity(start)))
            events.enqueue(.message(.activity(end)))
            events.enqueue(.message(.activity(end)))
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(store.presentation().sessions.first?.sourceLabel == "Codex")
        #expect(adapter.notices.count == 1)
        #expect(adapter.notices.first?.kind == .ended)
    }

    @Test func replacementKeepsNewSourceBaseline() async {
        let store = PetStore()
        let events = PetEventDispatcher(store: store)
        let old = SourceSnapshot(sourceId: "same-source", sourceLabel: "DSH", seq: 50, sessions: [
            SessionSnapshot(sessionId: "old", turn: 1, phase: .working, activeTools: 1, pendingApprovals: 0, result: nil),
        ])
        let new = SourceSnapshot(sourceId: "same-source", sourceLabel: "DSH", seq: 1, sessions: [
            SessionSnapshot(sessionId: "new", turn: 1, phase: .thinking, activeTools: 0, pendingApprovals: 0, result: nil),
        ])
        await withCheckedContinuation { continuation in
            // 对应实际 IPC 串行回调顺序，旧 seq 不应污染新连接。
            events.enqueue(.message(.snapshot(old)))
            events.enqueue(.disconnect("same-source"))
            events.enqueue(.message(.snapshot(new)))
            DispatchQueue.main.async { continuation.resume() }
        }
        let state = store.presentation()
        #expect(state.connectedSources == 1)
        #expect(state.pose == .thinking)
        #expect(state.sessions.map(\.sessionId) == ["new"])
    }
    @Test func protocolWarningDoesNotReplaceHealthyPresentation() async {
        let store = PetStore()
        let status = PetStatusModel()
        let events = PetEventDispatcher(store: store, onUpdate: { _ in status.update(store.presentation()) },
                                        onError: { status.connectionError = $0 },
                                        onReady: { status.connectionError = nil },
                                        onIncompatible: { status.protocolWarning = $0 })
        let snapshot = SourceSnapshot(sourceId: "healthy", sourceLabel: "DSH", seq: 1, sessions: [
            SessionSnapshot(sessionId: "s", turn: 1, phase: .working, activeTools: 1, pendingApprovals: 0, result: nil),
        ])
        await withCheckedContinuation { continuation in
            events.enqueue(.message(.snapshot(snapshot)))
            events.enqueue(.incompatible("协议不兼容"))
            events.enqueue(.ready)
            DispatchQueue.main.async { continuation.resume() }
        }
        let state = store.presentation()
        #expect(status.protocolWarning == "协议不兼容")
        #expect(status.connectionError == nil)
        #expect(state.connectedSources == 1)
        #expect(AppDelegate.presentationText(state, pose: state.pose) == "1 个会话正在执行")
    }

}
