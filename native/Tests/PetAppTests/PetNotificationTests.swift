import AppKit
import Foundation
import PetCore
import Testing
@testable import DSHNativePet

@Suite("来源呈现与通知", .serialized)
@MainActor
struct PetNotificationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ kind: PetActivityKind, id: String, provider: PetProvider = .codex,
                       session: String = "same", turn: String = "turn") -> PetActivityEvent {
        PetActivityEvent(provider: provider, sessionId: session, turnId: turn,
                         eventId: id, kind: kind, occurredAt: now.timeIntervalSince1970, toolId: nil)
    }

    @Test func recordingConsumesEachNoticeOnceWhileAnotherHostRuns() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("pet-notices-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        let adapter = try RecordingPetNotificationAdapter(logURL: log)
        let dispatcher = PetNotificationDispatcher(adapter: adapter)
        let store = PetStore()
        store.apply(event(.turnStarted, id: "claude-start", provider: .claudeCode), at: now)
        store.apply(event(.turnStarted, id: "codex-start"), at: now)
        let ended = event(.turnEnded, id: "codex-end")
        store.apply(ended, at: now)
        #expect(store.presentation(at: now).pose == .thinking)
        dispatcher.refresh(store: store, enabled: true, at: now)
        store.apply(ended, at: now)
        dispatcher.refresh(store: store, enabled: true, at: now)
        #expect(adapter.notices.count == 1)
        #expect(dispatcher.requestCount == 1)
        #expect(adapter.notices.first?.sourceLabel == "Codex")
        #expect(adapter.notices.first?.sessionId == "same")
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String]
        #expect(object?["sourceId"] == "hook:codex")
        #expect(object?["kind"] == "ended")
    }

    @Test func disablingNotificationsDropsPendingNoticeWithoutReplay() throws {
        let adapter = try RecordingPetNotificationAdapter()
        let dispatcher = PetNotificationDispatcher(adapter: adapter)
        let store = PetStore()
        store.apply(event(.turnStarted, id: "start"), at: now)
        store.apply(event(.waiting, id: "wait"), at: now)
        dispatcher.refresh(store: store, enabled: false, at: now.addingTimeInterval(0.4))
        dispatcher.refresh(store: store, enabled: true, at: now.addingTimeInterval(0.5))
        #expect(adapter.notices.isEmpty)
        #expect(dispatcher.requestCount == 0)
        #expect(store.presentation(at: now.addingTimeInterval(0.4)).pose == .waiting)
    }

    @Test func recordingAuthorizationAvoidsSystemPermission() async throws {
        let adapter = try RecordingPetNotificationAdapter()
        #expect(await adapter.authorization(request: true) == .recording)
        #expect(await adapter.authorization(request: false) == .recording)
    }

    @Test func sourceRowsHaveStableDistinctIdentityAndMenuShowsHosts() {
        _ = NSApplication.shared
        let store = PetStore()
        store.apply(event(.turnStarted, id: "codex", provider: .codex), at: now)
        store.apply(event(.turnStarted, id: "claude", provider: .claudeCode), at: now)
        let model = PetStatusModel()
        model.update(store.presentation(at: now))
        #expect(model.sessionRows.count == 2)
        #expect(Set(model.sessionRows.map(\.id)).count == 2)
        #expect(model.sessionRows.contains { $0.title == "Codex · same" })
        #expect(model.sessionRows.contains { $0.title == "Claude Code · same" })
        let codexID = model.sessionRows.first { $0.title == "Codex · same" }?.id
        store.apply(SourceSnapshot(sourceId: "aaa", sourceLabel: "DSH", seq: 1, sessions: [
            SessionSnapshot(sessionId: "earlier", turn: 1, phase: .idle, activeTools: 0, pendingApprovals: 0, result: nil),
        ]), at: now)
        model.update(store.presentation(at: now))
        #expect(model.sessionRows.first { $0.title == "Codex · same" }?.id == codexID)
        #expect(model.summary.contains("Codex"))
        let name = "PetNotificationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PetPreferences(defaults: defaults)
        #expect(preferences.systemNotifications)
        let menu = StatusMenu(preferences: preferences)
        menu.update(summary: model.summary, error: nil, sourceLabels: model.sourceLabels, authorization: .denied)
        #expect(menu.sourceSummary == "来源：Claude Code、Codex、DSH")
        menu.setSystemNotifications(false)
        #expect(!preferences.systemNotifications)
        #expect(!PetPreferences(defaults: defaults).systemNotifications)
        #expect(PetNotificationAuthorization.denied.title.contains("系统设置"))
    }

    @Test func deniedPermissionLeavesPetStateAvailable() async {
        let dispatcher = PetNotificationDispatcher(adapter: DeniedNotificationAdapter())
        #expect(await dispatcher.authorization(request: true) == .denied)
        let store = PetStore()
        store.apply(event(.turnStarted, id: "start"), at: now)
        store.apply(event(.waiting, id: "wait"), at: now)
        var error: String?
        dispatcher.onError = { error = $0 }
        dispatcher.refresh(store: store, enabled: true, at: now.addingTimeInterval(0.4))
        #expect(error == "通知未授权")
        #expect(store.presentation(at: now.addingTimeInterval(0.4)).pose == .waiting)
        let status = PetStatusModel()
        status.update(store.presentation(at: now))
        #expect(status.sessionRows.count == 1)
    }

    @Test func automatedPreferencesDoNotWriteUserDefaults() {
        let name = "PetNotificationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("character", forKey: "pet.skin")
        let preferences = PetPreferences(defaults: defaults, persistChanges: false)
        preferences.skin = .dshPet
        preferences.visible = false
        preferences.animations = false
        preferences.systemNotifications = false
        preferences.size = .large
        #expect(defaults.string(forKey: "pet.skin") == "character")
        #expect(defaults.object(forKey: "pet.visible") == nil)
        #expect(defaults.object(forKey: "pet.animations") == nil)
        #expect(defaults.object(forKey: "pet.systemNotifications") == nil)
        #expect(defaults.object(forKey: "pet.size") == nil)
    }

    @Test func closedLastSessionRetainsCoreFeedbackInRenderedLabel() throws {
        _ = NSApplication.shared
        let view = PetView(assets: try PetAssets())
        view.frame = NSRect(x: 0, y: 0, width: 140, height: 154)
        for (kind, expected) in [(PetActivityKind.turnEnded, "本轮回应已结束"), (.interrupted, "本轮回应已中断")] {
            let store = PetStore()
            store.apply(event(.turnStarted, id: "start"), at: now)
            store.apply(event(kind, id: "terminal"), at: now)
            store.apply(event(.sessionEnded, id: "closed"), at: now)
            let presentation = store.presentation(at: now)
            #expect(presentation.connectedSources == 0)
            #expect(presentation.sessions.isEmpty)
            let text = AppDelegate.presentationText(presentation, pose: presentation.pose)
            try view.render(pose: presentation.pose, text: text, animated: false)
            let label = try #require(view.subviews.compactMap { $0 as? NSTextField }.first)
            #expect(label.stringValue == presentation.text)
            #expect(label.stringValue.contains("Codex"))
            #expect(label.stringValue.contains(expected))
        }
    }

    @Test func permissionRequestFollowsEnableAndDoesNotRepeatAfterDenial() async {
        let adapter = AuthorizationTrackingAdapter()
        let dispatcher = PetNotificationDispatcher(adapter: adapter)
        #expect(await dispatcher.authorization(request: false) == .notDetermined)
        #expect(adapter.requests == [false])
        #expect(await dispatcher.authorization(request: true) == .denied)
        #expect(adapter.requests == [false, false, true])
        #expect(await dispatcher.authorization(request: true) == .denied)
        #expect(adapter.requests == [false, false, true, false])
        adapter.status = .authorized
        #expect(await dispatcher.authorization(request: true) == .authorized)
        #expect(adapter.requests.last == false)
    }

    @Test func parallelEndFeedbackFitsTwoLinesWithSourceAndRemainingWork() throws {
        _ = NSApplication.shared
        let store = PetStore()
        store.apply(event(.turnStarted, id: "codex-start"), at: now)
        store.apply(PetActivityEvent(provider: .codex, sessionId: "same", turnId: "turn",
                                     eventId: "tool-start", kind: .toolStarted,
                                     occurredAt: now.timeIntervalSince1970, toolId: "tool"), at: now)
        store.apply(event(.turnStarted, id: "claude-start", provider: .claudeCode), at: now)
        store.apply(event(.turnEnded, id: "claude-end", provider: .claudeCode), at: now)
        let presentation = store.presentation(at: now)
        #expect(presentation.pose == .working)
        let assets = try PetAssets(skin: .dshPet)
        let view = PetView(assets: assets)
        view.frame = NSRect(origin: .zero, size: try assets.requiredPanelSize(characterHeight: 100))
        try view.render(pose: presentation.pose, text: AppDelegate.presentationText(presentation, pose: presentation.pose))
        view.layoutSubtreeIfNeeded()
        let label = try #require(view.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(label.stringValue == "Claude Code\n本轮结束 · 1 执行中")
        label.maximumNumberOfLines = 0
        let measured = try #require(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 1000)))
        label.maximumNumberOfLines = 2
        #expect(measured.height <= label.frame.height)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/afk-ui-parallel-short.png"))
    }

    @Test func structuredFeedbackKeepsSingleAndParallelText() {
        for provider in [PetProvider.codex, .claudeCode] {
            let store = PetStore()
            store.apply(event(.turnEnded, id: "stop", provider: provider), at: now)
            let single = store.presentation(at: now)
            #expect(single.feedback == PresentedFeedback(pose: .completed, text: "本轮回应已结束", sourceLabel: provider.title))
            #expect(AppDelegate.presentationText(single, pose: single.pose) == "\(provider.title)：本轮回应已结束")
            store.apply(event(.running, id: "other", session: "other"), at: now)
            let parallel = store.presentation(at: now)
            #expect(AppDelegate.presentationText(parallel, pose: parallel.pose) == "\(provider.title)\n本轮结束 · 1 执行中")
        }
        for phase in [SessionPhase.working, .thinking] {
            let store = PetStore()
            let busy = SessionSnapshot(sessionId: "busy", turn: 1, phase: phase, activeTools: 0, pendingApprovals: 0, result: nil)
            store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 1, sessions: [busy]), at: now)
            let completed = SessionSnapshot(sessionId: "done", turn: 1, phase: .completed, activeTools: 0, pendingApprovals: 0,
                                            result: SessionResult(id: "r", outcome: "completed"))
            store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 2, sessions: [busy, completed]), at: now)
            let state = store.presentation(at: now)
            #expect(state.feedback == PresentedFeedback(pose: .completed, text: "任务已完成", sourceLabel: nil))
            #expect(AppDelegate.presentationText(state, pose: state.pose) == "任务已完成，1 \(phase == .working ? "执行中" : "思考中")")
        }
    }

    @Test func terminalSettingsRowsExpireWithoutUncertainty() {
        let store = PetStore()
        store.apply(event(.turnEnded, id: "stop"), at: now)
        let model = PetStatusModel()
        model.update(store.presentation(at: now.addingTimeInterval(899)))
        #expect(model.sessionRows.first?.detail == "本轮回应结束 · 工具 0 · 待决定 0")
        model.update(store.presentation(at: now.addingTimeInterval(901)))
        #expect(model.sessionRows.isEmpty)
        #expect(model.sourceLabels.isEmpty)
    }

    @Test func staleSessionShowsUncertainty() {
        let store = PetStore()
        store.apply(event(.turnStarted, id: "start"), at: now)
        let model = PetStatusModel()
        model.update(store.presentation(at: now.addingTimeInterval(901)))
        #expect(model.sessionRows.first?.detail == "状态待确认")
    }
}

@MainActor
private final class DeniedNotificationAdapter: PetNotificationAdapter {
    func authorization(request: Bool) async -> PetNotificationAuthorization { .denied }
    func submit(_ notice: PetNotice, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        completion("通知未授权")
    }
}

@MainActor
private final class AuthorizationTrackingAdapter: PetNotificationAdapter {
    var status: PetNotificationAuthorization = .notDetermined
    private(set) var requests: [Bool] = []
    func authorization(request: Bool) async -> PetNotificationAuthorization {
        requests.append(request)
        if request { status = .denied }
        return status
    }
    func submit(_ notice: PetNotice, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        completion(nil)
    }
}
