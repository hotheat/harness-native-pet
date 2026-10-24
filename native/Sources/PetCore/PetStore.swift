import Foundation

@MainActor
public final class PetStore {
    private struct Source {
        var snapshot: SourceSnapshot
        var resultIDs: [String: Set<String>]
    }
    private struct Feedback {
        let sourceID: String
        let sessionID: String
        let resultID: String?
        let pose: PetPose
        let text: String
        let expiresAt: Date
    }
    private struct SessionKey: Hashable {
        let source: String
        let session: String
    }
    private struct HookSession {
        let provider: PetProvider
        let sessionID: String
        var turnID: String?
        var retiredTurns: [String] = []
        var turnStartedAt: Double
        var latestOccurredAt: Double
        var phaseOccurredAt: Double
        var lastReceivedAt: Date
        var phase: SessionPhase = .idle
        var tools: Set<String> = []
        var finishedTools: Set<String> = []
        var terminal = false
        var closed = false
        var waitingAt: Date?
        var waitingNotified = false
        var result: SessionResult?
    }

    private var sources: [String: Source] = [:]
    private var hooks: [SessionKey: HookSession] = [:]
    private var feedback: Feedback?
    private var notices: [PetNotice] = []
    private var eventIDs: Set<String> = []
    private var eventOrder: [String] = []
    private var snapshotWaiting: [SessionKey: Date] = [:]
    private var snapshotWaitingNotified: Set<SessionKey> = []

    public init() {}

    public func apply(_ snapshot: SourceSnapshot, at: Date = Date()) {
        if let previous = sources[snapshot.sourceId], snapshot.seq <= previous.snapshot.seq { return }
        let previous = sources[snapshot.sourceId]
        var resultIDs = previous?.resultIDs ?? [:]
        let previousSessions = Dictionary(uniqueKeysWithValues: (previous?.snapshot.sessions ?? []).map { ($0.sessionId, $0) })
        let activePhases: Set<SessionPhase> = [.running, .thinking, .working, .waiting]
        if snapshot.sessions.contains(where: { session in
            guard activePhases.contains(session.phase) else { return false }
            guard let old = previousSessions[session.sessionId] else { return true }
            return old.turn != session.turn || !activePhases.contains(old.phase)
        }) { feedback = nil }

        let liveIDs = Set(snapshot.sessions.map(\.sessionId))
        snapshotWaiting = snapshotWaiting.filter { $0.key.source != snapshot.sourceId || liveIDs.contains($0.key.session) }
        snapshotWaitingNotified = snapshotWaitingNotified.filter { $0.source != snapshot.sourceId || liveIDs.contains($0.session) }
        for session in snapshot.sessions {
            let key = SessionKey(source: snapshot.sourceId, session: session.sessionId)
            if session.phase == .waiting {
                if snapshotWaiting[key] == nil {
                    snapshotWaiting[key] = at
                    // A reconnect baseline reports state but does not replay old prompts.
                    if previous == nil { snapshotWaitingNotified.insert(key) }
                }
            } else {
                snapshotWaiting.removeValue(forKey: key)
                snapshotWaitingNotified.remove(key)
            }
            guard let result = session.result else { continue }
            if previous != nil, !(resultIDs[session.sessionId] ?? []).contains(result.id) {
                let pose: PetPose
                let text: String
                let kind: PetNoticeKind
                switch result.outcome {
                case "completed": (pose, text, kind) = (.completed, "任务已完成", .ended)
                case "error": (pose, text, kind) = (.error, "任务未完成，请查看 \(snapshot.sourceLabel)", .error)
                case "aborted": (pose, text, kind) = (.idle, "任务已停止", .interrupted)
                case "blocked": (pose, text, kind) = (.idle, "任务受阻，请查看 \(snapshot.sourceLabel)", .ended)
                case "max-tokens": (pose, text, kind) = (.idle, "达到输出上限", .ended)
                default: (pose, text, kind) = (.idle, "本轮已结束", .ended)
                }
                recordNotice(id: "\(snapshot.sourceId):\(session.sessionId):\(result.id)", source: snapshot.sourceId,
                             label: snapshot.sourceLabel, session: session.sessionId, kind: kind, body: text)
                showFeedback(source: snapshot.sourceId, session: session.sessionId, resultID: result.id, pose: pose, text: text, at: at)
            }
            resultIDs[session.sessionId, default: []].insert(result.id)
        }
        resultIDs = resultIDs.filter { liveIDs.contains($0.key) }
        sources[snapshot.sourceId] = Source(snapshot: snapshot, resultIDs: resultIDs)
        if let current = feedback, current.sourceID == snapshot.sourceId,
           !snapshot.sessions.contains(where: { $0.sessionId == current.sessionID && $0.result?.id == current.resultID }) {
            feedback = nil
        }
    }

    public func apply(_ event: PetActivityEvent, at: Date = Date()) {
        pruneHooks(at: at)
        let dedupeID = "\(event.sourceId):\(event.sessionId):\(event.eventId)"
        guard eventIDs.insert(dedupeID).inserted else { return }
        eventOrder.append(dedupeID)
        if eventOrder.count > 4096 { eventIDs.remove(eventOrder.removeFirst()) }
        let key = SessionKey(source: event.sourceId, session: event.sessionId)
        var state = hooks[key] ?? HookSession(provider: event.provider, sessionID: event.sessionId,
                                             turnID: event.turnId, turnStartedAt: event.occurredAt,
                                             latestOccurredAt: event.occurredAt, phaseOccurredAt: event.occurredAt, lastReceivedAt: at)
        if let turnID = event.turnId, turnID != state.turnID {
            guard !state.retiredTurns.contains(turnID), event.occurredAt >= state.latestOccurredAt else { return }
            if let old = state.turnID { state.retiredTurns.append(old) }
            if state.retiredTurns.count > 32 { state.retiredTurns.removeFirst() }
            state.turnID = turnID
            state.turnStartedAt = event.occurredAt
            state.phaseOccurredAt = event.occurredAt
            state.phase = .idle
            state.tools = []
            state.finishedTools = []
            state.terminal = false
            state.closed = false
            state.waitingAt = nil
            state.waitingNotified = false
            state.result = nil
        }
        guard event.occurredAt >= state.turnStartedAt else { return }
        state.latestOccurredAt = max(state.latestOccurredAt, event.occurredAt)
        state.lastReceivedAt = at
        if event.kind == .sessionEnded {
            state.closed = true
            state.terminal = true
            state.phase = .idle
            state.tools = []
            state.waitingAt = nil
            hooks[key] = state
            return
        }
        // A terminal turn cannot be revived by delayed running/tool facts.
        if state.terminal { hooks[key] = state; return }
        switch event.kind {
        case .sessionStarted:
            break
        case .turnStarted, .running:
            guard event.occurredAt >= state.phaseOccurredAt else { break }
            state.phaseOccurredAt = event.occurredAt
            state.phase = event.kind == .running ? .running : state.tools.isEmpty ? .thinking : .working
            state.waitingAt = nil
            state.waitingNotified = false
            if feedback?.sourceID == event.sourceId && feedback?.sessionID == event.sessionId { feedback = nil }
        case .toolStarted:
            if let toolID = event.toolId, !state.finishedTools.contains(toolID), state.tools.count < 512 {
                state.tools.insert(toolID)
            }
            guard event.occurredAt >= state.phaseOccurredAt else { break }
            state.phaseOccurredAt = event.occurredAt
            state.phase = state.tools.isEmpty ? .thinking : .working
            state.waitingAt = nil
            state.waitingNotified = false
        case .toolFinished:
            finishTool(event.toolId, state: &state)
            guard event.occurredAt >= state.phaseOccurredAt else { break }
            state.phaseOccurredAt = event.occurredAt
            state.phase = state.tools.isEmpty ? .thinking : .working
            state.waitingAt = nil
            state.waitingNotified = false
        case .waiting:
            guard event.occurredAt >= state.phaseOccurredAt else { break }
            state.phaseOccurredAt = event.occurredAt
            if state.waitingAt == nil { state.waitingAt = at }
            state.phase = .waiting
        case .turnEnded, .failed, .interrupted:
            if event.kind == .failed, event.toolId != nil {
                // A failed tool does not establish a failed turn.
                finishTool(event.toolId, state: &state)
                guard event.occurredAt >= state.phaseOccurredAt else { break }
                state.phaseOccurredAt = event.occurredAt
                state.phase = state.tools.isEmpty ? .thinking : .working
                state.waitingAt = nil
                state.waitingNotified = false
                break
            }
            state.terminal = true
            state.tools = []
            state.waitingAt = nil
            let kind: PetNoticeKind
            let pose: PetPose
            let body: String
            switch event.kind {
            case .failed:
                (state.phase, kind, pose, body) = (.error, .error, .error, "本轮回应出错，请查看 \(event.provider.title)")
            case .interrupted:
                (state.phase, kind, pose, body) = (.stopped, .interrupted, .idle, "本轮回应已中断")
            default:
                (state.phase, kind, pose, body) = (.completed, .ended, .completed, "本轮回应已结束")
            }
            state.result = SessionResult(id: event.eventId, outcome: event.kind == .failed ? "error" : event.kind == .interrupted ? "aborted" : "other")
            // An explicit live Stop is meaningful even when it is the first event.
            recordNotice(id: dedupeID, source: event.sourceId, label: event.provider.title,
                         session: event.sessionId, kind: kind, body: body)
            showFeedback(source: event.sourceId, session: event.sessionId, pose: pose,
                         text: "\(event.provider.title)：\(body)", at: at)
        case .sessionEnded:
            break
        }
        hooks[key] = state
        pruneHooks(at: at)
    }

    private func finishTool(_ toolID: String?, state: inout HookSession) {
        guard let toolID else { return }
        state.tools.remove(toolID)
        if state.finishedTools.count < 512 { state.finishedTools.insert(toolID) }
    }

    public func disconnect(sourceID: String, at: Date = Date()) {
        sources.removeValue(forKey: sourceID)
        snapshotWaiting = snapshotWaiting.filter { $0.key.source != sourceID }
        snapshotWaitingNotified = snapshotWaitingNotified.filter { $0.source != sourceID }
        if feedback?.sourceID == sourceID { feedback = nil }
        // Disconnect never revokes an already queued notice.
    }

    public func drainNotices(at: Date = Date()) -> [PetNotice] {
        pruneHooks(at: at)
        for key in hooks.keys.sorted(by: { ($0.source, $0.session) < ($1.source, $1.session) }) {
            guard var state = hooks[key], let waitingAt = state.waitingAt,
                  !state.waitingNotified, at.timeIntervalSince(waitingAt) >= 0.3,
                  at.timeIntervalSince(state.lastReceivedAt) < 900 else { continue }
            state.waitingNotified = true
            hooks[key] = state
            recordNotice(id: "\(key.source):\(key.session):waiting:\(waitingAt.timeIntervalSince1970)", source: key.source,
                         label: state.provider.title, session: key.session, kind: .waiting,
                         body: "有待处理请求，请查看 \(state.provider.title)")
        }
        for (key, waitingAt) in snapshotWaiting where !snapshotWaitingNotified.contains(key) && at.timeIntervalSince(waitingAt) >= 0.3 {
            snapshotWaitingNotified.insert(key)
            recordNotice(id: "\(key.source):\(key.session):waiting:\(waitingAt.timeIntervalSince1970)", source: key.source,
                         label: sources[key.source]?.snapshot.sourceLabel ?? "DSH", session: key.session,
                         kind: .waiting, body: "有待处理请求，请查看 \(sources[key.source]?.snapshot.sourceLabel ?? "DSH")")
        }
        let result = notices
        notices = []
        return result
    }

    private func recordNotice(id: String, source: String, label: String, session: String, kind: PetNoticeKind, body: String) {
        notices.append(PetNotice(id: id, sourceId: source, sourceLabel: label, sessionId: session,
                                 kind: kind, title: "\(label) 会话提醒", body: body))
        if notices.count > 256 { notices.removeFirst(notices.count - 256) }
    }

    private func showFeedback(source: String, session: String, resultID: String? = nil, pose: PetPose, text: String, at: Date) {
        if pose == .error || feedback.map({ $0.pose != .error || $0.expiresAt <= at }) ?? true {
            feedback = Feedback(sourceID: source, sessionID: session, resultID: resultID, pose: pose, text: text, expiresAt: at.addingTimeInterval(3))
        }
    }

    private func pruneHooks(at: Date) {
        hooks = hooks.filter { at.timeIntervalSince($0.value.lastReceivedAt) < 86_400 }
        if hooks.count > 256 {
            let oldest = hooks.sorted {
                let leftIdle = $0.value.terminal || $0.value.phase == .idle || at.timeIntervalSince($0.value.lastReceivedAt) >= 900
                let rightIdle = $1.value.terminal || $1.value.phase == .idle || at.timeIntervalSince($1.value.lastReceivedAt) >= 900
                if leftIdle != rightIdle { return leftIdle }
                return $0.value.lastReceivedAt < $1.value.lastReceivedAt
            }.prefix(hooks.count - 256)
            for entry in oldest { hooks.removeValue(forKey: entry.key) }
        }
    }

    public func presentation(at: Date = Date()) -> PetPresentation {
        pruneHooks(at: at)
        var sessions = sources.keys.sorted().flatMap { key in
            let source = sources[key]!.snapshot
            return source.sessions.sorted { $0.sessionId < $1.sessionId }.map {
                PresentedSession(sourceId: key, sourceLabel: source.sourceLabel, session: $0)
            }
        }
        sessions += hooks.keys.filter { hooks[$0]?.closed == false }.sorted { ($0.source, $0.session) < ($1.source, $1.session) }.map { key in
            let state = hooks[key]!
            let stale = at.timeIntervalSince(state.lastReceivedAt) >= 900
            let pending = state.waitingAt.map { at.timeIntervalSince($0) >= 0.3 } ?? false
            let phase: SessionPhase = stale ? .idle : state.phase == .waiting && !pending ? .thinking : state.phase
            return PresentedSession(sourceId: key.source, sourceLabel: state.provider.title,
                                    session: SessionSnapshot(sessionId: key.session, turn: nil, phase: phase,
                                                             activeTools: stale ? 0 : state.tools.count,
                                                             pendingApprovals: phase == .waiting ? 1 : 0, result: state.result), isStale: stale)
        }
        let waitingCount = sessions.filter { $0.phase == .waiting }.count
        let activeCount = sessions.filter { $0.phase != .waiting && ([.running, .thinking, .working].contains($0.phase) || $0.activeTools > 0) }.count
        if let current = feedback, current.expiresAt <= at { feedback = nil }
        let pose: PetPose
        let text: String
        if waitingCount > 0 {
            pose = .waiting
            let labels = Set(sessions.filter { $0.phase == .waiting }.map(\.sourceLabel)).sorted().joined(separator: "、")
            text = "\(waitingCount) 个会话待处理，请查看 \(labels)" + (activeCount > 0 ? "，\(activeCount) 个仍在执行" : "")
        } else if sessions.contains(where: { [.working, .running].contains($0.phase) || $0.activeTools > 0 }) {
            pose = .working
            text = feedback?.pose == .completed ? "\(feedback!.text)，\(activeCount) 个会话仍在执行" : "\(activeCount) 个会话正在执行"
        } else if sessions.contains(where: { $0.phase == .thinking }) {
            pose = .thinking
            text = feedback?.pose == .completed ? "\(feedback!.text)，\(activeCount) 个会话仍在思考" : "正在思考"
        } else if let current = feedback {
            pose = current.pose
            text = current.text
        } else {
            pose = .idle
            text = sessions.contains(where: \.isStale) ? "状态待确认" : sources.isEmpty && sessions.isEmpty ? "未连接宿主" : "准备就绪"
        }
        return PetPresentation(pose: pose, text: text, activeCount: activeCount,
                               waitingCount: waitingCount, connectedSources: sources.count + Set(hooks.filter { !$0.value.closed }.keys.map(\.source)).count, sessions: sessions)
    }
}
