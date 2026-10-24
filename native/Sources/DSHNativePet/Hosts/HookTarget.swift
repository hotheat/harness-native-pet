import Foundation
import PetCore

enum HookTarget: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode = "claude-code"

    var id: String { rawValue }
    var provider: PetProvider { self == .codex ? .codex : .claudeCode }
    var title: String { provider.title }

    func command(helperPath: String) -> String {
        Self.shellQuote(helperPath) + " " + rawValue
    }

    static func shellQuote(_ value: String) -> String {
        let safe = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"
        if !value.isEmpty, value.utf8.allSatisfy({ safe.utf8.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    var events: [String] {
        switch self {
        case .codex:
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]
        case .claudeCode:
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "SessionEnd"]
        }
    }
}
