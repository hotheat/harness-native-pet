import Foundation

public enum BridgeMessageError: Error, Equatable {
    case invalid(String)
}

public enum BridgeMessage: Sendable {
    case snapshot(SourceSnapshot)
    case heartbeat(Heartbeat)
    case activity(PetActivityEvent)

    public static let maximumLineBytes = 262_144
    public static let maximumSafeInteger = 9_007_199_254_740_991

    public var sourceID: String {
        switch self {
        case .snapshot(let value): value.sourceId
        case .heartbeat(let value): value.sourceId
        case .activity(let value): value.sourceId
        }
    }

    public var sequence: Int {
        switch self {
        case .snapshot(let value): value.seq
        case .heartbeat(let value): value.seq
        case .activity: 0
        }
    }

    public static func decode(_ data: Data) throws -> BridgeMessage {
        guard data.count <= maximumLineBytes else { throw BridgeMessageError.invalid("message too large") }
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if raw?["type"] as? String == "activity" {
            let fields: Set<String> = ["type", "provider", "sessionId", "turnId", "eventId", "kind", "occurredAt", "toolId"]
            guard let raw, Set(raw.keys) == fields else {
                throw BridgeMessageError.invalid("missing or unexpected activity fields")
            }
            let event = try JSONDecoder().decode(PetActivityEvent.self, from: data)
            try validateID(event.sessionId, name: "sessionId")
            try validateID(event.eventId, name: "eventId")
            if let turnId = event.turnId { try validateID(turnId, name: "turnId") }
            if let toolId = event.toolId { try validateID(toolId, name: "toolId") }
            guard event.occurredAt.isFinite, event.occurredAt >= 0 else {
                throw BridgeMessageError.invalid("invalid occurredAt")
            }
            return .activity(event)
        }
        let envelope = try JSONDecoder().decode(WireMessage.self, from: data)
        try validateID(envelope.sourceId, name: "sourceId")
        guard !envelope.sourceId.hasPrefix("hook:") else { throw BridgeMessageError.invalid("reserved sourceId") }
        guard envelope.seq > 0, envelope.seq <= maximumSafeInteger else {
            throw BridgeMessageError.invalid("invalid seq")
        }
        switch envelope.type {
        case "heartbeat":
            return .heartbeat(Heartbeat(sourceId: envelope.sourceId, seq: envelope.seq))
        case "snapshot":
            guard let label = envelope.sourceLabel, !label.isEmpty,
                  let sessions = envelope.sessions else {
                throw BridgeMessageError.invalid("invalid snapshot fields")
            }
            var ids: Set<String> = []
            for session in sessions {
                try validateID(session.sessionId, name: "sessionId")
                guard ids.insert(session.sessionId).inserted else {
                    throw BridgeMessageError.invalid("duplicate sessionId")
                }
                guard session.turn.map({ $0 >= 0 && $0 <= maximumSafeInteger }) ?? true,
                      session.activeTools >= 0, session.activeTools <= maximumSafeInteger,
                      session.pendingApprovals >= 0, session.pendingApprovals <= maximumSafeInteger else {
                    throw BridgeMessageError.invalid("invalid session counts")
                }
                if let result = session.result {
                    try validateID(result.id, name: "result.id")
                    guard ["completed", "error", "aborted", "blocked", "max-tokens", "other"].contains(result.outcome) else {
                        throw BridgeMessageError.invalid("invalid result outcome")
                    }
                }
            }
            return .snapshot(SourceSnapshot(sourceId: envelope.sourceId, sourceLabel: label,
                                            seq: envelope.seq, sessions: sessions))
        default:
            throw BridgeMessageError.invalid("unknown message type")
        }
    }

    private static func validateID(_ value: String, name: String) throws {
        guard !value.isEmpty else {
            throw BridgeMessageError.invalid("invalid \(name)")
        }
    }
}

private struct WireMessage: Decodable {
    let type: String
    let sourceId: String
    let sourceLabel: String?
    let seq: Int
    let sessions: [SessionSnapshot]?

    enum CodingKeys: String, CodingKey {
        case type, sourceId, sourceLabel, seq, sessions
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        let expected: Set<String> = type == "heartbeat" ? ["type", "sourceId", "seq"] : ["type", "sourceId", "sourceLabel", "seq", "sessions"]
        guard Set(raw.allKeys.map(\.stringValue)) == expected else {
            throw BridgeMessageError.invalid("missing or unexpected message fields")
        }
        sourceId = try values.decode(String.self, forKey: .sourceId)
        sourceLabel = try values.decodeIfPresent(String.self, forKey: .sourceLabel)
        seq = try values.decode(Int.self, forKey: .seq)
        sessions = try values.decodeIfPresent([SessionSnapshot].self, forKey: .sessions)
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
