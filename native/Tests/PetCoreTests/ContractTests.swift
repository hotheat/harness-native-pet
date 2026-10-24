import Foundation
import Testing
@testable import PetCore

struct ContractTests {
    private func fixtures(_ file: String) throws -> [(String, Data)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/\(file)"))
        let values = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        return try values.map { value in
            (value["name"] as! String, try JSONSerialization.data(withJSONObject: value["message"]!))
        }
    }

    @Test func sharedValidFixtures() throws {
        for (name, data) in try fixtures("snapshots.json") + fixtures("activity.json") {
            let message = try BridgeMessage.decode(data)
            #expect(!message.sourceID.isEmpty, Comment(rawValue: name))
        }
    }

    @Test func sharedInvalidFixtures() throws {
        for (name, data) in try fixtures("invalid-messages.json") {
            #expect(throws: (any Error).self, Comment(rawValue: name)) { try BridgeMessage.decode(data) }
        }
    }

    @Test func strictBoundaryCases() throws {
        let invalid = [
            #"{"type":"heartbeat","sourceId":"a","seq":1,"sessions":null}"#,
            #"{"type":"heartbeat","sourceId":"a","seq":true}"#,
            #"{"type":"snapshot","sourceId":"a","sourceLabel":"DSH","seq":1,"sessions":[{"sessionId":"s","turn":null,"phase":"idle","activeTools":0,"pendingApprovals":0}]}"#,
            #"{"type":"snapshot","sourceId":"a","sourceLabel":"DSH","seq":1,"sessions":[{"sessionId":"s","turn":null,"phase":"completed","activeTools":0,"pendingApprovals":0,"result":{"id":"r","outcome":"completed","text":"private"}}]}"#,
        ]
        for line in invalid { #expect(throws: (any Error).self) { try BridgeMessage.decode(Data(line.utf8)) } }
        #expect(throws: (any Error).self) { try BridgeMessage.decode(Data(repeating: 32, count: 262_145)) }
    }

    @Test func nullableFieldsEncodeAsNull() throws {
        let session = SessionSnapshot(sessionId: "s", turn: nil, phase: .idle, activeTools: 0, pendingApprovals: 0, result: nil)
        let encoded = try JSONEncoder().encode(session)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(object["turn"] is NSNull)
        #expect(object["result"] is NSNull)
    }

    @Test func activityBoundaryRequiresExactFieldsAndReservesHookSources() throws {
        let event = PetActivityEvent(provider: .codex, sessionId: "s", turnId: nil,
                                     eventId: "e", kind: .sessionStarted, occurredAt: 1000, toolId: nil)
        let data = try JSONEncoder().encode(event)
        guard case .activity(let decoded) = try BridgeMessage.decode(data) else {
            Issue.record("expected activity")
            return
        }
        #expect(decoded == event)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for (key, value) in [("provider", "unknown" as Any), ("kind", "unknown" as Any),
                             ("sessionId", "" as Any), ("turnId", "" as Any),
                             ("toolId", "" as Any), ("eventId", "" as Any),
                             ("occurredAt", -1 as Any), ("privateText", "secret" as Any)] {
            var invalid = object
            invalid[key] = value
            #expect(throws: (any Error).self) { try BridgeMessage.decode(JSONSerialization.data(withJSONObject: invalid)) }
        }
        object.removeValue(forKey: "toolId")
        #expect(throws: (any Error).self) { try BridgeMessage.decode(JSONSerialization.data(withJSONObject: object)) }
        #expect(throws: (any Error).self) {
            try BridgeMessage.decode(Data(#"{"type":"snapshot","sourceId":"hook:codex","sourceLabel":"DSH","seq":1,"sessions":[]}"#.utf8))
        }
    }
}
