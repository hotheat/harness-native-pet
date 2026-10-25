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
                       session: String = "same", turn: String = "turn", time: Double? = nil) -> PetActivityEvent {
        PetActivityEvent(provider: provider, sessionId: session, turnId: turn,
                         eventId: id, kind: kind, occurredAt: time ?? now.timeIntervalSince1970, toolId: nil)
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
        #expect(adapter.notices.first?.userInfo["sessionId"] == "same")
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(object?["sourceId"] as? String == "hook:codex")
        #expect(object?["kind"] as? String == "ended")
        #expect(object?["sound"] as? Bool == false)
        #expect(object?["threadIdentifier"] as? String == "hook:codex:same")
        #expect(object?["userInfo"] as? [String: String] == ["sourceId": "hook:codex", "sessionId": "same"])
    }

    @Test func recordingContentWithoutIdentityWritesEmptyFields() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("pet-notices-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        let adapter = try RecordingPetNotificationAdapter(logURL: log)
        let content = PetNotificationContent(id: "n", kind: .ended, sourceLabel: "DSH",
                                             title: "DSH 会话提醒", body: "本轮已结束", sound: false,
                                             threadIdentifier: "", userInfo: [:])
        adapter.submit(content) { error in #expect(error == nil) }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Any]
        #expect(object?["sourceId"] as? String == "")
        #expect(object?["sessionId"] as? String == "")
        #expect(object?["userInfo"] as? [String: String] == [:])
        #expect(adapter.notices.count == 1)
    }

    @Test func dispatcherProjectsSessionTitlesForSnapshotAndHookNotices() throws {
        for showTitles in [false, true] {
            for title in [nil, "私密项目"] as [String?] {
                for kind in [PetNoticeKind.waiting, .ended, .error, .interrupted] {
                    for hook in [false, true] {
                        let store = PetStore()
                        let label = hook ? "Codex" : "DSH"
                        if hook {
                            // Terminal events without a label must retain the session's known title.
                            store.apply(PetActivityEvent(provider: .codex, sessionId: "s", turnId: "t", eventId: "start",
                                                         kind: .turnStarted, occurredAt: 1000, toolId: nil, label: title), at: now)
                            let activity: PetActivityKind = switch kind {
                            case .waiting: .waiting
                            case .ended: .turnEnded
                            case .error: .failed
                            case .interrupted: .interrupted
                            }
                            store.apply(PetActivityEvent(provider: .codex, sessionId: "s", turnId: "t", eventId: "notice",
                                                         kind: activity, occurredAt: 1001, toolId: nil), at: now)
                        } else {
                            store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: label, seq: 1, sessions: []), at: now)
                            let phase: SessionPhase = switch kind {
                            case .waiting: .waiting
                            case .ended: .completed
                            case .error: .error
                            case .interrupted: .stopped
                            }
                            let outcome = kind == .error ? "error" : kind == .interrupted ? "aborted" : "completed"
                            let session = SessionSnapshot(sessionId: "s", turn: 1, phase: phase, activeTools: 0,
                                                          pendingApprovals: kind == .waiting ? 1 : 0,
                                                          result: kind == .waiting ? nil : SessionResult(id: "r", outcome: outcome), title: title)
                            store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: label, seq: 2, sessions: [session]), at: now)
                        }
                        let adapter = try RecordingPetNotificationAdapter()
                        let dispatcher = PetNotificationDispatcher(adapter: adapter)
                        dispatcher.refresh(store: store, enabled: true, showSessionTitles: showTitles, at: now.addingTimeInterval(0.4))
                        let content = try #require(adapter.notices.first)
                        #expect(adapter.notices.count == 1)
                        #expect(content.title == (showTitles && title != nil ? "\(label) · 私密项目" : "\(label) 会话提醒"))
                        #expect(!content.body.contains("私密项目"))
                        #expect(content.userInfo == ["sourceId": hook ? "hook:codex" : "dsh", "sessionId": "s"])
                        #expect(content.threadIdentifier == (hook ? "hook:codex:s" : "dsh:s"))
                        #expect(content.sound == (kind == .waiting || kind == .error))
                    }
                }
            }
        }
    }

    @Test func notificationSessionTitlePreferenceDefaultsOffAndPersistsOnlyWhenEnabled() throws {
        let name = "PetNotificationTitleTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PetPreferences(defaults: defaults)
        #expect(!preferences.notificationSessionTitle)
        let automated = PetPreferences(defaults: defaults, persistChanges: false)
        automated.notificationSessionTitle = true
        #expect(defaults.object(forKey: "pet.notificationSessionTitle") == nil)
        preferences.notificationSessionTitle = true
        #expect(PetPreferences(defaults: defaults).notificationSessionTitle)
        let automatedWithSavedValue = PetPreferences(defaults: defaults, persistChanges: false)
        automatedWithSavedValue.notificationSessionTitle = false
        #expect(PetPreferences(defaults: defaults).notificationSessionTitle)
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
        #expect(codexID == PetMessageProjector.rowID(sourceId: "hook:codex", sessionId: "same"))
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
            let text = PetMessageProjector.bubble(presentation, pose: presentation.pose, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14)
            try view.render(pose: presentation.pose, text: text, animated: false)
            #expect(view.displayText == text)
            #expect(view.displayText.contains("Codex"))
            #expect(view.displayText.contains(expected))
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

    @Test func singleLineBubbleHugsContentAtHistoricalCenter() throws {
        _ = NSApplication.shared
        let view = PetView(assets: try PetAssets())
        view.frame = NSRect(x: 0, y: 0, width: 140, height: 154)
        try view.render(pose: .thinking, text: "正在思考")
        view.layoutSubtreeIfNeeded()
        let singleLineFrame = view.bubbleFrame
        #expect(singleLineFrame.height > 0)
        #expect(singleLineFrame.midY == view.bounds.height - 19)
        #expect(singleLineFrame.minX == 7)
        #expect(singleLineFrame.width == view.bounds.width - 14)
        try view.render(pose: .thinking, text: "Claude Code\n本轮结束 · 1 执行中")
        view.layoutSubtreeIfNeeded()
        #expect(view.bubbleFrame.height - singleLineFrame.height >= 10)
        #expect(view.bubbleFrame.height <= 32)
        #expect(view.bubbleFrame.midY == singleLineFrame.midY)
    }

    @Test func textOnlyRenderResizesBubbleAtHistoricalCenter() throws {
        _ = NSApplication.shared
        let view = PetView(assets: try PetAssets())
        view.frame = NSRect(x: 0, y: 0, width: 140, height: 154)
        try view.render(pose: .thinking, text: "正在思考")
        view.layoutSubtreeIfNeeded()
        let singleLineFrame = view.bubbleFrame
        #expect(!view.needsLayout)
        try view.render(pose: .thinking, text: "正在思考")
        #expect(!view.needsLayout)
        try view.render(pose: .thinking, text: "Claude Code\n本轮结束 · 1 执行中")
        #expect(view.needsLayout)
        view.layoutSubtreeIfNeeded()
        #expect(view.bubbleFrame.height - singleLineFrame.height >= 10)
        #expect(view.bubbleFrame.height <= 32)
        #expect(view.bubbleFrame.midY == singleLineFrame.midY)
        #expect(view.bubbleFrame.midY == view.bounds.height - 19)
        try view.render(pose: .thinking, text: "正在思考")
        view.layoutSubtreeIfNeeded()
        #expect(view.bubbleFrame == singleLineFrame)
    }

    @Test func bubblePassesMouseHitsToPetViewAndPreservesAccessibility() throws {
        _ = NSApplication.shared
        let view = PetView(assets: try PetAssets())
        view.frame = NSRect(x: 0, y: 0, width: 140, height: 154)
        try view.render(pose: .thinking, text: "正在思考")
        view.layoutSubtreeIfNeeded()
        let bubble = try #require(view.subviews.first)
        #expect(!bubble.isHidden)
        #expect(view.hitTest(NSPoint(x: view.bubbleFrame.midX, y: view.bubbleFrame.midY)) === view)
        #expect(view.toolTip == view.displayText)
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .button)
        #expect(view.accessibilityLabel() == "DSH 桌宠，点击互动，拖动移动")
        #expect(view.accessibilityValue() as? String == view.displayText)
        try view.render(pose: .thinking, text: "")
        #expect(view.displayText == "")
        #expect(bubble.isHidden)
        #expect(view.toolTip == "DSH 桌宠")
        #expect(view.accessibilityValue() as? String == "")
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
        try view.render(pose: presentation.pose, text: PetMessageProjector.bubble(presentation, pose: presentation.pose, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14))
        view.layoutSubtreeIfNeeded()
        #expect(view.displayText == "Claude Code\n本轮结束 · 1 执行中")
        #expect(view.bubbleFrame.height > 20)
        #expect(view.bubbleFrame.height <= 32)
        #expect(view.bubbleFrame.midY == view.bounds.height - 19)
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
            #expect(single.feedback == PresentedFeedback(pose: .completed, kind: .completed, sourceLabel: provider.title))
            #expect(PetMessageProjector.bubble(single, pose: single.pose, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == "\(provider.title)：本轮回应已结束")
            store.apply(event(.running, id: "other", session: "other"), at: now)
            let parallel = store.presentation(at: now)
            #expect(PetMessageProjector.bubble(parallel, pose: parallel.pose, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == "\(provider.title)\n本轮结束 · 1 执行中")
        }
        for phase in [SessionPhase.working, .thinking] {
            let store = PetStore()
            let busy = SessionSnapshot(sessionId: "busy", turn: 1, phase: phase, activeTools: 0, pendingApprovals: 0, result: nil)
            store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 1, sessions: [busy]), at: now)
            let completed = SessionSnapshot(sessionId: "done", turn: 1, phase: .completed, activeTools: 0, pendingApprovals: 0,
                                            result: SessionResult(id: "r", outcome: "completed"))
            store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 2, sessions: [busy, completed]), at: now)
            let state = store.presentation(at: now)
            #expect(state.feedback == PresentedFeedback(pose: .completed, kind: .completed, sourceLabel: "DSH"))
            #expect(PetMessageProjector.bubble(state, pose: state.pose, bubbleWidth: PetPreferences.Size.medium.panelSize.width - 14) == "DSH\n本轮结束 · 1 \(phase == .working ? "执行中" : "思考中")")
        }
    }

    @Test func terminalSettingsRowsExpireWithoutUncertainty() {
        let store = PetStore()
        store.apply(event(.turnEnded, id: "stop"), at: now)
        let model = PetStatusModel()
        model.update(store.presentation(at: now.addingTimeInterval(899)))
        #expect(model.sessionRows.first?.detail == "本轮回应已结束 · 工具 0 · 待决定 0")
        model.update(store.presentation(at: now.addingTimeInterval(901)))
        #expect(model.sessionRows.isEmpty)
        #expect(model.sourceLabels.isEmpty)
    }

    @Test func automationValidationRejectsMissingValuesAndConflictingModes() {
        for flag in ["--skin", "--demo-pose", "--capture-preview", "--capture-live", "--capture-skin-switch", "--capture-after", "--notification-log"] {
            for suffix in [[], ["--demo"], [""]] {
                #expect(throws: AppDelegate.AppError.self) { try AppDelegate.validateAutomationArguments(["pet", flag] + suffix) }
            }
        }
        for flags in [["--capture-live", "a", "--capture-preview", "b"],
                      ["--capture-live", "a", "--demo"], ["--capture-skin-switch", "a", "--capture-preview", "b"],
                      ["--demo", "--demo-pose", "idle"], ["--smoke-test", "--capture-live", "a"],
                      ["--capture-after", "1"], ["--capture-live", "a", "--capture-after", "nan"],
                      ["--capture-preview", "a", "--capture-after", "61"], ["--skin", "missing"],
                      ["--demo-pose", "missing"], ["--demo", "--demo"]] {
            #expect(throws: AppDelegate.AppError.self) { try AppDelegate.validateAutomationArguments(["pet"] + flags) }
        }
    }

    @Test func automationValidationKeepsExistingConsumersAndOneAutomationRule() throws {
        for flags in [["--smoke-test"], ["--demo"], ["--demo-pose", "working"],
                      ["--capture-preview", "a", "--demo-pose", "idle"],
                      ["--capture-live", "a", "--capture-after", "2", "--notification-log", "log"],
                      ["--capture-skin-switch", "dir"], ["--demo-pose", "working", "--capture-skin-switch", "dir"], ["--notification-log", "log"]] {
            let arguments = ["pet"] + flags
            try AppDelegate.validateAutomationArguments(arguments)
            #expect(AppDelegate.isAutomation(arguments: arguments, environment: [:]))
        }
        #expect(!AppDelegate.isAutomation(arguments: ["pet", "--skin", "dshPet"], environment: [:]))
        #expect(AppDelegate.isAutomation(arguments: ["pet"], environment: ["XCTestConfigurationFilePath": "tests"]))
        #expect(AppDelegate.isAutomation(arguments: ["pet", "--capture-live"], environment: [:]))
    }

    @Test func shortResultsAreDrainedWhileWaitingAndErrorsBypassThreshold() throws {
        let adapter = try RecordingPetNotificationAdapter()
        let dispatcher = PetNotificationDispatcher(adapter: adapter)
        let store = PetStore()
        for (session, kind, seconds) in [("short", PetActivityKind.turnEnded, 9.0), ("stop", .interrupted, 1),
                                         ("long", .turnEnded, 10), ("long-stop", .interrupted, 11), ("error", .failed, 1)] {
            store.apply(event(.turnStarted, id: "start-" + session, session: session), at: now)
            store.apply(event(kind, id: "end-" + session, session: session, time: now.timeIntervalSince1970 + seconds), at: now)
        }
        store.apply(event(.waiting, id: "waiting", session: "waiting"), at: now)
        dispatcher.refresh(store: store, enabled: true, minimumDuration: 10, at: now.addingTimeInterval(0.4))
        #expect(adapter.notices.map { $0.userInfo["sessionId"] } == ["long", "long-stop", "error", "waiting"])
        for notice in adapter.notices {
            #expect((SystemPetNotificationAdapter.content(for: notice).sound != nil) == [.waiting, .error].contains(notice.kind))
        }
        dispatcher.refresh(store: store, enabled: true, minimumDuration: 0, at: now.addingTimeInterval(1))
        #expect(dispatcher.requestCount == 4)
    }

    @Test func firstStopBypassesDurationThreshold() throws {
        let adapter = try RecordingPetNotificationAdapter()
        let dispatcher = PetNotificationDispatcher(adapter: adapter)
        let store = PetStore()
        store.apply(event(.turnEnded, id: "stop"), at: now)
        dispatcher.refresh(store: store, enabled: true, minimumDuration: 10, at: now)
        #expect(adapter.notices.count == 1)
        #expect(dispatcher.requestCount == 1)
        let notice = try #require(adapter.notices.first)
        #expect(notice.kind == .ended)
    }

    @Test func firstInterruptionBypassesDurationThreshold() throws {
        let adapter = try RecordingPetNotificationAdapter()
        let dispatcher = PetNotificationDispatcher(adapter: adapter)
        let store = PetStore()
        store.apply(event(.interrupted, id: "interrupt"), at: now)
        dispatcher.refresh(store: store, enabled: true, minimumDuration: 10, at: now)
        #expect(adapter.notices.count == 1)
        #expect(dispatcher.requestCount == 1)
        let notice = try #require(adapter.notices.first)
        #expect(notice.kind == .interrupted)
    }

    @Test func unknownDurationIsSubmittedAndResultContentIsSilent() throws {
        let adapter = try RecordingPetNotificationAdapter()
        let dispatcher = PetNotificationDispatcher(adapter: adapter)
        let store = PetStore()
        store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 1, sessions: []), at: now)
        store.apply(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 2, sessions: [
            SessionSnapshot(sessionId: "unknown", turn: 1, phase: .completed, activeTools: 0, pendingApprovals: 0,
                            result: SessionResult(id: "r", outcome: "completed")),
        ]), at: now)
        dispatcher.refresh(store: store, enabled: true, minimumDuration: 10, at: now)
        let ended = try #require(adapter.notices.first)
        let content = SystemPetNotificationAdapter.content(for: ended)
        #expect(content.sound == nil)
        #expect(content.userInfo["sourceId"] as? String == "dsh")
        #expect(content.userInfo["sessionId"] as? String == "unknown")
        store.apply(event(.failed, id: "error"), at: now)
        dispatcher.refresh(store: store, enabled: true, minimumDuration: 10, at: now)
        #expect(SystemPetNotificationAdapter.content(for: try #require(adapter.notices.last)).sound != nil)
    }

    @Test func successfulSubmissionClearsOldErrorAndOpenForwardsIdentity() {
        let adapter = AuthorizationTrackingAdapter()
        let dispatcher = PetNotificationDispatcher(adapter: adapter)
        let status = PetStatusModel()
        status.notificationError = "旧错误"
        dispatcher.onError = { status.notificationError = $0 }
        dispatcher.onOpen = { status.focusedSessionID = PetMessageProjector.rowID(sourceId: $0, sessionId: $1) }
        let store = PetStore()
        store.apply(event(.turnEnded, id: "end"), at: now)
        dispatcher.refresh(store: store, enabled: true, at: now)
        #expect(status.notificationError == nil)
        adapter.onOpen?("hook:codex", "same")
        #expect(status.focusedSessionID == PetMessageProjector.rowID(sourceId: "hook:codex", sessionId: "same"))
        #expect(PetMessageProjector.rowID(sourceId: "a", sessionId: "bc") != PetMessageProjector.rowID(sourceId: "ab", sessionId: "c"))
        #expect(PetMessageProjector.rowID(sourceId: "中", sessionId: "s") == "3:中s")
    }

    @Test func noticeMinimumPreferenceAcceptsNumberAndLaunchArgumentString() {
        let name = "PetNotificationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(PetPreferences(defaults: defaults).noticeMinimumSeconds == 10)
        defaults.set(2.5, forKey: "pet.noticeMinimumSeconds")
        #expect(PetPreferences(defaults: defaults).noticeMinimumSeconds == 2.5)
        defaults.set("0", forKey: "pet.noticeMinimumSeconds")
        #expect(PetPreferences(defaults: defaults).noticeMinimumSeconds == 0)
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
    var onOpen: ((String, String) -> Void)?
    func authorization(request: Bool) async -> PetNotificationAuthorization { .denied }
    func submit(_ notice: PetNotificationContent, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        completion("通知未授权")
    }
}

@MainActor
private final class AuthorizationTrackingAdapter: PetNotificationAdapter {
    var onOpen: ((String, String) -> Void)?
    var status: PetNotificationAuthorization = .notDetermined
    private(set) var requests: [Bool] = []
    func authorization(request: Bool) async -> PetNotificationAuthorization {
        requests.append(request)
        if request { status = .denied }
        return status
    }
    func submit(_ notice: PetNotificationContent, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        completion(nil)
    }
}
