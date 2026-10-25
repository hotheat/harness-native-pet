import Foundation
import Testing
@testable import PetCore

struct ContractTests {
    private func fixtures(_ file: String) throws -> [(String, Data, Data?)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/\(file)"))
        let values = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        return try values.map { value in
            (value["name"] as! String, try JSONSerialization.data(withJSONObject: value["message"]!),
             try value["normalized"].map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) })
        }
    }

    @Test func sharedValidFixtures() throws {
        for (name, data, expected) in try fixtures("snapshots.json") + fixtures("activity.json") {
            let message = try BridgeMessage.decode(data)
            #expect(try canonicalJSON(message) == #require(expected), Comment(rawValue: name))
        }
    }

    @Test func sharedInvalidFixtures() throws {
        for (name, data, _) in try fixtures("invalid-messages.json") {
            #expect(throws: (any Error).self, Comment(rawValue: name)) { try BridgeMessage.decode(data) }
        }
    }

    @Test func strictBoundaryCases() throws {
        let invalid = [
            #"{"type":"heartbeat","sourceId":"a","seq":true}"#,
            #"{"type":"snapshot","sourceId":"a","sourceLabel":"DSH","seq":1,"sessions":[{"sessionId":"s","turn":null,"phase":"idle","activeTools":0,"pendingApprovals":0}]}"#,
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
        #expect(object["title"] is NSNull)
    }

    @Test func activityBoundaryRequiresFieldsAndReservesHookSources() throws {
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
                             ("occurredAt", -1 as Any)] {
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
    @Test func unsupportedVersionsHaveDistinctError() throws {
        for version in ["2", "null", "\"1\"", "true", "1.5"] {
            for type in ["heartbeat", "snapshot", "activity"] {
                let data = Data("{\"type\":\"\(type)\",\"v\":\(version)}".utf8)
                #expect(throws: BridgeMessageError.unsupportedVersion) { try BridgeMessage.decode(data) }
            }
        }
    }

    @Test func optionalTitlesAndLabelsDecodeAndRoundTrip() throws {
        for (_, data, _) in try fixtures("snapshots.json") {
            guard case .snapshot(let snapshot) = try BridgeMessage.decode(data) else { continue }
            for session in snapshot.sessions {
                #expect(try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(session)) == session)
            }
        }
        for (name, data, _) in try fixtures("activity.json") {
            guard case .activity(let event) = try BridgeMessage.decode(data) else { continue }
            if name == "activity-with-label" { #expect(event.label == "harness-native-pet") }
            if name == "activity-null-label" { #expect(event.label == nil) }
        }
    }

    @Test func textNormalizationAndDecoderScalarBoundaries() throws {
        var cases: [(String?, String?)] = [
            (nil, nil), ("", nil), (" \t\u{200b} ", nil),
            (" \0会\n话\u{007f}\u{0085}\u{200b}\u{202e}标题\u{feff} ", "会话标题"),
            ("\u{00a0}\u{2000}\u{2028}标题\u{2029}\u{3000}", "标题"),
            (String(repeating: "e\u{0301}", count: 129), String(repeating: "e\u{0301}", count: 128)),
            (String(repeating: "中", count: 255) + "😀尾", String(repeating: "中", count: 255) + "😀"),
        ]
        for character in ["a", "中", "😀"] {
            for count in [64, 65, 256, 257, 1024] {
                cases.append((String(repeating: character, count: count), String(repeating: character, count: min(count, 256))))
            }
        }
        #expect(PetWireText.maximumScalars == 256)
        for (input, expected) in cases {
            #expect(PetWireText.normalize(input) == expected)
            let event = PetActivityEvent(provider: .codex, sessionId: "s", turnId: "t", eventId: "e",
                                         kind: .waiting, occurredAt: 1000, toolId: nil, label: input)
            guard case .activity(let decoded) = try BridgeMessage.decode(JSONEncoder().encode(event)) else {
                Issue.record("expected activity")
                continue
            }
            #expect(decoded.label == expected)
            #expect(decoded.kind == .waiting)
            let session = SessionSnapshot(sessionId: "s", turn: nil, phase: .idle,
                                          activeTools: 0, pendingApprovals: 0, result: nil, title: input)
            let message = BridgeMessage.snapshot(SourceSnapshot(sourceId: "dsh", sourceLabel: "DSH", seq: 1, sessions: [session]))
            guard case .snapshot(let snapshot) = try BridgeMessage.decode(canonicalJSON(message)) else {
                Issue.record("expected snapshot")
                continue
            }
            #expect(snapshot.sessions.first?.title == expected)
        }
    }

    /// Re-encode the decoded wire fields, including explicit nulls, then sort JSON keys.
    private func canonicalJSON(_ message: BridgeMessage) throws -> Data {
        let object: Any
        switch message {
        case .activity(let event):
            object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
        case .heartbeat(let heartbeat):
            object = ["type": "heartbeat", "sourceId": heartbeat.sourceId, "seq": heartbeat.seq]
        case .snapshot(let snapshot):
            object = ["type": "snapshot", "sourceId": snapshot.sourceId, "sourceLabel": snapshot.sourceLabel,
                      "seq": snapshot.seq,
                      "sessions": try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.sessions))]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
