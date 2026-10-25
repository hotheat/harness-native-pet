import Foundation
import PetCore
import Testing
@testable import PetHooks

struct HookAdapterTests {
    private func input(_ name: String, _ extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["hook_event_name": name, "session_id": "session", "turn_id": "turn", "prompt_id": "prompt", "tool_use_id": "tool"]
        object.merge(extra) { _, value in value }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test func supportedEventsMapForBothProviders() throws {
        let mapping: [(String, PetActivityKind)] = [
            ("SessionStart", .sessionStarted), ("UserPromptSubmit", .turnStarted),
            ("PreToolUse", .toolStarted), ("PostToolUse", .toolFinished),
            ("PostToolUseFailure", .toolFinished), ("PermissionRequest", .waiting),
            ("Stop", .turnEnded), ("StopFailure", .failed),
            ("Interrupt", .interrupted), ("SessionEnd", .sessionEnded),
        ]
        for provider in [PetProvider.codex, .claudeCode] {
            for (name, kind) in mapping {
                let event = try #require(try HookAdapter.normalize(input(name), provider: provider, occurredAt: Date(timeIntervalSince1970: 123)))
                #expect(event.kind == kind)
                #expect(event.provider == provider)
                #expect(event.turnId == (provider == .codex ? "turn" : "prompt"))
                #expect(event.occurredAt == 123)
            }
        }
    }

    @Test func onlyPermissionNotificationsWait() throws {
        let permission = try input("Notification", ["notification_type": "permission_prompt"])
        #expect(try HookAdapter.normalize(permission, provider: .claudeCode)?.kind == .waiting)
        #expect(try HookAdapter.normalize(permission, provider: .codex) == nil)
        for type in ["idle_prompt", "auth_success", "elicitation_dialog", "other"] {
            #expect(try HookAdapter.normalize(input("Notification", ["notification_type": type]), provider: .claudeCode) == nil)
        }
        #expect(try HookAdapter.normalize(input("UnknownEvent"), provider: .codex) == nil)
    }

    @Test func backgroundStopAndPreviouslyContinuedFinalStop() throws {
        for key in ["background_tasks", "session_crons"] {
            let event = try HookAdapter.normalize(input("Stop", [key: [["id": "background"]], "stop_hook_active": true]), provider: .claudeCode)
            #expect(event?.kind == .running)
        }
        for active in [true, false] {
            let event = try HookAdapter.normalize(input("Stop", ["background_tasks": [], "stop_hook_active": active]), provider: .claudeCode)
            #expect(event?.kind == .turnEnded)
        }
    }

    @Test func subagentsCannotOverwriteParentAndAgentTypeAloneIsMainSession() throws {
        for provider in [PetProvider.codex, .claudeCode] {
            for name in ["PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd", "SubagentStart", "SubagentStop"] {
                #expect(try HookAdapter.normalize(input(name, ["agent_id": "child", "agent_type": "Explore"]), provider: provider) == nil)
            }
            #expect(try HookAdapter.normalize(input("Stop", ["agent_type": "reviewer"]), provider: provider)?.kind == .turnEnded)
        }
    }

    @Test func sessionEventsPermitMissingTurnOtherEventsRequireCurrentHostTurn() throws {
        for provider in [PetProvider.codex, .claudeCode] {
            let missing: [String: Any] = ["turn_id": NSNull(), "prompt_id": NSNull()]
            for name in ["SessionStart", "SessionEnd"] {
                let event = try #require(try HookAdapter.normalize(input(name, missing), provider: provider))
                #expect(event.turnId == nil)
            }
            for name in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "StopFailure"] {
                #expect(try HookAdapter.normalize(input(name, missing), provider: provider) == nil)
            }
            #expect(try HookAdapter.normalize(input("PreToolUse", ["tool_use_id": NSNull()]), provider: provider) == nil)
        }
    }

    @Test func canonicalInputDedupesWhileProvidersToolsAndStagesStayDistinct() throws {
        let original = try input("PreToolUse", ["tool_use_id": "first"])
        let a = try #require(try HookAdapter.normalize(original, provider: .codex))
        let pretty = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: original), options: [.prettyPrinted])
        let duplicate = try #require(try HookAdapter.normalize(pretty, provider: .codex))
        #expect(a.eventId == duplicate.eventId)
        let otherTool = try #require(try HookAdapter.normalize(input("PreToolUse", ["tool_use_id": "second"]), provider: .codex))
        #expect(a.eventId != otherTool.eventId)
        #expect(a.toolId == "first")
        #expect(otherTool.toolId == "second")
        let finished = try #require(try HookAdapter.normalize(input("PostToolUse", ["tool_use_id": "first"]), provider: .codex))
        #expect(a.eventId != finished.eventId)
        #expect(try a.eventId != HookAdapter.normalize(original, provider: .claudeCode)?.eventId)
    }

    @Test func wireContainsExactlyNineMetadataFieldsAndExplicitNulls() throws {
        let data = try input("SessionStart", ["turn_id": NSNull(), "tool_use_id": NSNull(),
            "prompt": "private prompt", "last_assistant_message": "private answer", "cwd": "/private/work",
            "transcript_path": "/secret/transcript", "tool_input": ["api_key": "secret key"]])
        let event = try #require(try HookAdapter.normalize(data, provider: .codex))
        let encoded = try HookAdapter.encode(event)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == Set(["type", "provider", "sessionId", "turnId", "eventId", "kind", "occurredAt", "toolId", "label"]))
        #expect(object["label"] as? String == "work")
        #expect(object["turnId"] is NSNull)
        #expect(object["toolId"] is NSNull)
        let text = String(decoding: encoded, as: UTF8.self)
        for secret in ["private prompt", "private answer", "/private/work", "/secret/transcript", "secret key", "tool_input"] {
            #expect(!text.contains(secret))
        }
        #expect(try JSONDecoder().decode(PetActivityEvent.self, from: encoded) == event)
    }

    @Test func cwdLabelUsesOnlyTheLastComponentAndNormalizesScalars() throws {
        for provider in [PetProvider.codex, .claudeCode] {
            for cwd in ["/Users/person/project", "/Users/person/project/", "/Users/person/ \u{0000}project\t "] {
                let event = try #require(try HookAdapter.normalize(input("Stop", ["cwd": cwd]), provider: provider))
                #expect(event.label == "project")
                #expect(!String(decoding: try HookAdapter.encode(event), as: UTF8.self).contains("/Users/person"))
            }
            for cwd in ["/", "///", "", " \n ", "/\u{0000}\t "] {
                let event = try #require(try HookAdapter.normalize(input("Stop", ["cwd": cwd]), provider: provider))
                #expect(event.label == nil)
            }
            let missing = try #require(try HookAdapter.normalize(input("Stop"), provider: provider))
            #expect(missing.label == nil)
            let object = try #require(JSONSerialization.jsonObject(with: HookAdapter.encode(missing)) as? [String: Any])
            #expect(object["label"] is NSNull)
            var cases = [(" \u{200b}项目\u{202e} ", "项目"),
                         (String(repeating: "e\u{0301}", count: 129), String(repeating: "e\u{0301}", count: 128))]
            for character in ["a", "中", "😀"] {
                for count in [64, 65, 256, 257, 1024] {
                    cases.append((String(repeating: character, count: count), String(repeating: character, count: min(count, 256))))
                }
            }
            for (name, expected) in cases {
                let event = try #require(try HookAdapter.normalize(input("Stop", ["cwd": "/parent/\(name)"]), provider: provider))
                #expect(event.label == expected)
                guard case .activity(let decoded) = try BridgeMessage.decode(HookAdapter.encode(event)) else {
                    Issue.record("expected activity")
                    continue
                }
                #expect(decoded == event)
            }
        }
    }

    @Test func malformedAndOversizedInputIsRejected() throws {
        for value in ["", "[]", "null", "{", "{}"] {
            #expect(throws: HookInputError.self) { try HookAdapter.normalize(Data(value.utf8), provider: .codex) }
        }
        #expect(throws: HookInputError.self) {
            try HookAdapter.normalize(Data(repeating: 32, count: HookAdapter.maximumInputBytes + 1), provider: .codex)
        }
        #expect(throws: HookInputError.self) { try HookAdapter.normalize(input("Stop", ["session_id": ""]), provider: .codex) }
    }
}
