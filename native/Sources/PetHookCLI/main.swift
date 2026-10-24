import Darwin
import Foundation
import PetCore
import PetHooks
import PetIPC

let arguments = Array(CommandLine.arguments.dropFirst())
let strict = arguments.contains("--strict")
let dryRun = arguments.contains("--dry-run")
let deadline = HookDeadline()

do {
    guard let host = arguments.first,
          host == "codex" || host == "claude-code",
          arguments.dropFirst().allSatisfy({ $0 == "--strict" || $0 == "--dry-run" }) else {
        throw HookInputError.invalidJSON
    }
    let provider: PetProvider = host == "codex" ? .codex : .claudeCode
    let input = try HookTransport.readInput(fd: STDIN_FILENO, deadline: deadline)
    if let event = try HookAdapter.normalize(input, provider: provider) {
        var encoded = try HookAdapter.encode(event)
        if dryRun {
            encoded.append(0x0A)
            FileHandle.standardOutput.write(encoded)
        } else {
            try HookTransport.send(encoded, socketPath: PetRuntimeLocation.socketPath, deadline: deadline)
            FileHandle.standardOutput.write(Data("{}\n".utf8))
        }
    } else {
        FileHandle.standardOutput.write(Data("{}\n".utf8))
    }
    exit(0)
} catch {
    FileHandle.standardError.write(Data("pet-hook: event not delivered\n".utf8))
    FileHandle.standardOutput.write(Data("{}\n".utf8))
    exit(strict ? 1 : 0)
}
