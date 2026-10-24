import Foundation

public enum PetProvider: String, Codable, Sendable {
    case codex, claudeCode
    public var title: String { self == .codex ? "Codex" : "Claude Code" }
}

public enum PetActivityKind: String, Codable, Sendable {
    case sessionStarted, turnStarted, toolStarted, toolFinished, waiting
    case running, turnEnded, failed, interrupted, sessionEnded
}

/// 一次性交付的宿主事实；连接结束不代表会话结束。
public struct PetActivityEvent: Codable, Equatable, Sendable {
    public let type: String
    public let provider: PetProvider
    public let sessionId: String
    public let turnId: String?
    public let eventId: String
    public let kind: PetActivityKind
    public let occurredAt: Double
    public let toolId: String?

    public init(provider: PetProvider, sessionId: String, turnId: String?, eventId: String,
                kind: PetActivityKind, occurredAt: Double, toolId: String?) {
        type = "activity"
        self.provider = provider
        self.sessionId = sessionId
        self.turnId = turnId
        self.eventId = eventId
        self.kind = kind
        self.occurredAt = occurredAt
        self.toolId = toolId
    }

    enum CodingKeys: String, CodingKey { case type, provider, sessionId, turnId, eventId, kind, occurredAt, toolId }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(provider, forKey: .provider)
        try values.encode(sessionId, forKey: .sessionId)
        try values.encode(turnId, forKey: .turnId)
        try values.encode(eventId, forKey: .eventId)
        try values.encode(kind, forKey: .kind)
        try values.encode(occurredAt, forKey: .occurredAt)
        try values.encode(toolId, forKey: .toolId)
    }

    public var sourceId: String { "hook:\(provider.rawValue)" }
}
