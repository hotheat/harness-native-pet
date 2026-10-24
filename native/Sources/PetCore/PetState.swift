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
        try rejectUnknownKeys(decoder, allowed: ["id", "outcome"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        outcome = try values.decode(String.self, forKey: .outcome)
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let sessionId: String
    public let turn: Int?
    public let phase: SessionPhase
    public let activeTools: Int
    public let pendingApprovals: Int
    public let result: SessionResult?

    public init(sessionId: String, turn: Int?, phase: SessionPhase, activeTools: Int,
                pendingApprovals: Int, result: SessionResult?) {
        self.sessionId = sessionId
        self.turn = turn
        self.phase = phase
        self.activeTools = activeTools
        self.pendingApprovals = pendingApprovals
        self.result = result
    }

    enum CodingKeys: String, CodingKey { case sessionId, turn, phase, activeTools, pendingApprovals, result }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["sessionId", "turn", "phase", "activeTools", "pendingApprovals", "result"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try values.decode(String.self, forKey: .sessionId)
        turn = try values.decode(Int?.self, forKey: .turn)
        phase = try values.decode(SessionPhase.self, forKey: .phase)
        activeTools = try values.decode(Int.self, forKey: .activeTools)
        pendingApprovals = try values.decode(Int.self, forKey: .pendingApprovals)
        result = try values.decode(SessionResult?.self, forKey: .result)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sessionId, forKey: .sessionId)
        try values.encode(turn, forKey: .turn)
        try values.encode(phase, forKey: .phase)
        try values.encode(activeTools, forKey: .activeTools)
        try values.encode(pendingApprovals, forKey: .pendingApprovals)
        try values.encode(result, forKey: .result)
    }
}

private func rejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let raw = try decoder.container(keyedBy: DynamicKey.self)
    guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw BridgeMessageError.invalid("unknown session or result fields")
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
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
    public let title: String
    public let body: String
}

public struct PresentedSession: Equatable, Sendable {
    public let sourceId: String
    public let sourceLabel: String
    public let sessionId: String
    public let turn: Int?
    public let phase: SessionPhase
    public let activeTools: Int
    public let pendingApprovals: Int
    public let result: SessionResult?
    public let isStale: Bool

    public init(sourceId: String, sourceLabel: String, session: SessionSnapshot, isStale: Bool = false) {
        self.sourceId = sourceId
        self.sourceLabel = sourceLabel
        sessionId = session.sessionId
        turn = session.turn
        phase = session.phase
        activeTools = session.activeTools
        pendingApprovals = session.pendingApprovals
        result = session.result
        self.isStale = isStale
    }
}

public struct PetPresentation: Sendable {
    public let pose: PetPose
    public let text: String
    public let activeCount: Int
    public let waitingCount: Int
    public let connectedSources: Int
    public let sessions: [PresentedSession]

    public init(pose: PetPose, text: String, activeCount: Int, waitingCount: Int,
                connectedSources: Int, sessions: [PresentedSession]) {
        self.pose = pose
        self.text = text
        self.activeCount = activeCount
        self.waitingCount = waitingCount
        self.connectedSources = connectedSources
        self.sessions = sessions
    }
}
