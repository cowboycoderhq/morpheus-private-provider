import Foundation

/// The engine accepts only an allowlist of environment variables; anything
/// else (DYLD_*, MallocStackLogging, MTL_*, ...) refuses the start.
enum EnvGuard {
    private static let allowed: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "PWD", "OLDPWD", "SHLVL",
        "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "COLORTERM",
        "LANG", "MAIL", "_", "COMMAND_MODE", "XPC_FLAGS", "XPC_SERVICE_NAME",
        "SSH_CLIENT", "SSH_CONNECTION", "SSH_TTY", "SSH_AUTH_SOCK",
        "SEALED_ENGINE_PORT", "SEALED_PROVIDER_ADDR", "SEALED_PACKAGE", "SEALED_CHILD_DIR",
        "SEALED_DECOY", "SEALED_MAX_CONTEXT", "SEALED_ENGINE_LOG", "SEALED_KV_BUDGET_BYTES",
        "OSLogRateLimit",   // set by launchd for apps started through LaunchServices
    ]
    private static let prefixes = ["LC_", "__CF"]

    static func enforce() {
        let rejected = ProcessInfo.processInfo.environment.keys
            .filter { name in !allowed.contains(name) && !prefixes.contains { name.hasPrefix($0) } }
            .sorted()
        guard !rejected.isEmpty else { return }
        FileHandle.standardError.write(Data("refusing to start: environment variable(s) not allowed: \(rejected.joined(separator: ", "))\n".utf8))
        exit(4)
    }
}
