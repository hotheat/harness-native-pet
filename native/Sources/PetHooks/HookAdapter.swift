import CryptoKit
import Foundation
import PetCore

public enum HookInputError: Error {
    case invalidJSON, oversized, invalidIdentity
}

/// Reads host facts only; no hook response or authorization decision is produced.
public enum HookAdapter {
    public static let maximumInputBytes = 1_048_576

    public static func normalize(_ data: Data, provider: PetProvider,
                                 occurredAt: Date = Date()) throws -> PetActivityEvent? {
        guard data.count <= maximumInputBytes else { throw HookInputError.oversized }
        guard let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInputError.invalidJSON
        }
        guard let name = input["hook_event_name"] as? String else { throw HookInputError.invalidJSON }
        // Subagent hooks share the parent's session_id. Their state cannot end that session.
        guard name != "SubagentStart", name != "SubagentStop", input["agent_id"] == nil || input["agent_id"] is NSNull else {
            return nil
        }
        let kind: PetActivityKind
        switch name {
        case "SessionStart": kind = .sessionStarted
        case "UserPromptSubmit": kind = .turnStarted
        case "PreToolUse": kind = .toolStarted
        case "PostToolUse", "PostToolUseFailure": kind = .toolFinished
        case "PermissionRequest": kind = .waiting
        case "Notification" where provider == .claudeCode && input["notification_type"] as? String == "permission_prompt":
            kind = .waiting
        case "Stop":
            // stop_hook_active describes an earlier continuation, not the outcome of this Stop.
            // A Stop is only an observed response boundary; another hook may still continue it.
            let background = input["background_tasks"] as? [Any] ?? []
            let scheduled = input["session_crons"] as? [Any] ?? []
            kind = provider == .claudeCode && (!background.isEmpty || !scheduled.isEmpty) ? .running : .turnEnded
        case "StopFailure": kind = .failed
        case "Interrupt": kind = .interrupted
        case "SessionEnd": kind = .sessionEnded
        default: return nil
        }
        guard let sessionID = identity(input["session_id"]) else { throw HookInputError.invalidIdentity }
        let turnID = identity(input[provider == .codex ? "turn_id" : "prompt_id"])
        let sessionEvent = kind == .sessionStarted || kind == .sessionEnded
        // Current hosts supply turn IDs after user input. An uncorrelated terminal/tool event
        // cannot safely mutate whichever turn happens to be active in the receiver.
        guard sessionEvent || turnID != nil else { return nil }
        let toolID = identity(input["tool_use_id"])
        guard (kind != .toolStarted && kind != .toolFinished) || toolID != nil else { return nil }
        let canonical = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        var digestInput = Data(provider.rawValue.utf8)
        digestInput.append(0)
        digestInput.append(canonical)
        let eventID = SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
        return PetActivityEvent(provider: provider, sessionId: sessionID, turnId: turnID,
                                eventId: eventID, kind: kind, occurredAt: occurredAt.timeIntervalSince1970,
                                toolId: toolID, label: label(input["cwd"]))
    }

    /// Explicit nulls keep the nine-field wire contract independent of synthesized Codable.
    public static func encode(_ event: PetActivityEvent) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": event.type, "provider": event.provider.rawValue, "sessionId": event.sessionId,
            "turnId": event.turnId as Any? ?? NSNull(), "eventId": event.eventId,
            "kind": event.kind.rawValue, "occurredAt": event.occurredAt,
            "toolId": event.toolId as Any? ?? NSNull(),
            "label": event.label as Any? ?? NSNull(),
        ], options: [.sortedKeys])
    }

    private static func label(_ value: Any?) -> String? {
        guard let path = value as? String,
              let component = path.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last else { return nil }
        return PetWireText.normalize(String(component))
    }

    private static func identity(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
}
