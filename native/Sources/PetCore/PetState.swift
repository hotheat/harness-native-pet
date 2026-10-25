import Foundation

public enum SessionPhase: String, Codable, Sendable {
    case idle, running, thinking, working, waiting, completed, error, stopped
}

public enum PetPose: String, CaseIterable, Sendable {
    case idle, thinking, working, waiting, completed, error, sleeping, poke, drag
}

public struct SessionResult: Codable, Equatable, Sendable {
    public let id: String
    public let outcome: String

    public init(id: String, outcome: String) {
        self.id = id
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey { case id, outcome }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        outcome = try values.decode(String.self, forKey: .outcome)
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let sessionId: String
    public let title: String?
    public let turn: Int?
    public let phase: SessionPhase
    public let activeTools: Int
    public let pendingApprovals: Int
    public let result: SessionResult?

    public init(sessionId: String, turn: Int?, phase: SessionPhase, activeTools: Int,
                pendingApprovals: Int, result: SessionResult?, title: String? = nil) {
        self.sessionId = sessionId
        self.title = title
        self.turn = turn
        self.phase = phase
        self.activeTools = activeTools
        self.pendingApprovals = pendingApprovals
        self.result = result
    }

    enum CodingKeys: String, CodingKey { case sessionId, title, turn, phase, activeTools, pendingApprovals, result }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try values.decode(String.self, forKey: .sessionId)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        turn = try values.decode(Int?.self, forKey: .turn)
        phase = try values.decode(SessionPhase.self, forKey: .phase)
        activeTools = try values.decode(Int.self, forKey: .activeTools)
        pendingApprovals = try values.decode(Int.self, forKey: .pendingApprovals)
        result = try values.decode(SessionResult?.self, forKey: .result)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sessionId, forKey: .sessionId)
        try values.encode(title, forKey: .title)
        try values.encode(turn, forKey: .turn)
        try values.encode(phase, forKey: .phase)
        try values.encode(activeTools, forKey: .activeTools)
        try values.encode(pendingApprovals, forKey: .pendingApprovals)
        try values.encode(result, forKey: .result)
    }
}

public struct SourceSnapshot: Equatable, Sendable {
    public let sourceId: String
    public let sourceLabel: String
    public let seq: Int
    public let sessions: [SessionSnapshot]

    public init(sourceId: String, sourceLabel: String, seq: Int, sessions: [SessionSnapshot]) {
        self.sourceId = sourceId
        self.sourceLabel = sourceLabel
        self.seq = seq
        self.sessions = sessions
    }
}

public struct Heartbeat: Equatable, Sendable {
    public let sourceId: String
    public let seq: Int

    public init(sourceId: String, seq: Int) {
        self.sourceId = sourceId
        self.seq = seq
    }
}

public enum PetNoticeKind: String, Sendable {
    case waiting, ended, error, interrupted
}

public struct PetNotice: Sendable {
    public let id: String
    public let sourceId: String
    public let sourceLabel: String
    public let sessionId: String
    public let kind: PetNoticeKind
    public let feedback: PetFeedbackKind?
    public let turnDuration: TimeInterval?
    public let sessionTitle: String?

    init(id: String, sourceId: String, sourceLabel: String, sessionId: String,
         kind: PetNoticeKind, feedback: PetFeedbackKind?, turnDuration: TimeInterval?, sessionTitle: String? = nil) {
        self.id = id
        self.sourceId = sourceId
        self.sourceLabel = sourceLabel
        self.sessionId = sessionId
        self.kind = kind
        self.feedback = feedback
        self.turnDuration = turnDuration
        self.sessionTitle = sessionTitle
    }
}

public struct PresentedSession: Equatable, Sendable {
    public let sourceId: String
    public let sourceLabel: String
    public let session: SessionSnapshot
    public let isStale: Bool

    public init(sourceId: String, sourceLabel: String, session: SessionSnapshot, isStale: Bool = false) {
        self.sourceId = sourceId
        self.sourceLabel = sourceLabel
        self.session = session
        self.isStale = isStale
    }
}

public enum PetFeedbackKind: String, Sendable {
    case completed, failed, interrupted, blocked, maxTokens, other
}

public struct PresentedFeedback: Equatable, Sendable {
    public let pose: PetPose
    public let kind: PetFeedbackKind
    public let sourceLabel: String?
    public let title: String?

    public init(pose: PetPose, kind: PetFeedbackKind, sourceLabel: String?, title: String? = nil) {
        self.pose = pose
        self.kind = kind
        self.sourceLabel = sourceLabel
        self.title = title
    }
}

public struct PetPresentation: Sendable {
    public let pose: PetPose
    public let hasReceivedHook: Bool
    public let activeCount: Int
    public let waitingCount: Int
    public let connectedSources: Int
    public let feedback: PresentedFeedback?
    public let sessions: [PresentedSession]

    public init(pose: PetPose, activeCount: Int, waitingCount: Int,
                connectedSources: Int, sessions: [PresentedSession], feedback: PresentedFeedback?, hasReceivedHook: Bool = false) {
        self.pose = pose
        self.hasReceivedHook = hasReceivedHook
        self.activeCount = activeCount
        self.waitingCount = waitingCount
        self.connectedSources = connectedSources
        self.feedback = feedback
        self.sessions = sessions
    }
}
