import Darwin
import Foundation

/// Claude Code's OAuth credentials, as stored in the `Claude Code-credentials` keychain item.
struct ClaudeCredentials: Equatable {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?

    static func parse(_ data: Data) throws -> ClaudeCredentials {
        let creds = try jsonObject(data)
        guard let oauth = creds["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.notLoggedIn(ClaudeProvider.hint)
        }
        return ClaudeCredentials(accessToken: token,
                                 expiresAt: number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) },
                                 subscriptionType: oauth["subscriptionType"] as? String)
    }

    func isExpired(now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

/// Gets an expired Claude Code token renewed by Claude Code itself.
///
/// The refresh token can rotate on use, so refreshing it here could sign Claude Code out. Instead this
/// briefly starts `claude`, which renews the token on startup and writes it back to the keychain.
actor ClaudeTokenRefresher {
    typealias Attempt = @Sendable (_ isRefreshed: @escaping @Sendable () async -> Bool) async -> Bool

    static let shared = ClaudeTokenRefresher { await ClaudeCLIWaker.run(until: $0) }

    private let attempt: Attempt
    private let cooldown: TimeInterval
    private var lastFailure: Date?
    private var inFlight: Task<Bool, Never>?

    init(cooldown: TimeInterval = 10 * 60, attempt: @escaping Attempt) {
        self.cooldown = cooldown
        self.attempt = attempt
    }

    /// Returns whether `isRefreshed` reported success. After a failed attempt, further calls return
    /// `false` without launching `claude` until the cooldown passes; concurrent calls share one attempt.
    func refresh(now: Date = Date(), until isRefreshed: @escaping @Sendable () async -> Bool) async -> Bool {
        if let inFlight { return await inFlight.value }
        if let lastFailure, now.timeIntervalSince(lastFailure) < cooldown { return false }
        let attempt = self.attempt
        let task = Task { await attempt(isRefreshed) }
        inFlight = task
        let ok = await task.value
        inFlight = nil
        lastFailure = ok ? nil : now
        return ok
    }
}

/// Runs interactive `claude` in a pseudo-terminal until the token is renewed, then stops it.
enum ClaudeCLIWaker {
    /// No MCP servers, hooks or Remote Control: only startup (and its token renewal) is needed.
    static let arguments = ["--strict-mcp-config", "--settings", #"{"remoteControlAtStartup":false,"disableAllHooks":true}"#]

    static func run(_ executable: String = "claude", arguments: [String] = arguments, timeout: TimeInterval = 30,
                    statusAfter: TimeInterval = 8,
                    until isRefreshed: @escaping @Sendable () async -> Bool) async -> Bool {
        guard let dir = try? workingDirectory(),
              let session = try? PTYSession.launch(executable, arguments, in: dir, environment: environment())
        else { return false }
        let start = Date()
        var output = ""
        var lastOutput: Date?
        var trustAnswers = 0
        var statusSent = false
        var nextCheck = start
        var refreshed = false
        while Date().timeIntervalSince(start) < timeout, session.isRunning {
            let chunk = session.readAvailable()
            if !chunk.isEmpty {
                output = String((output + chunk).suffix(8000))
                lastOutput = Date()
            }
            if trustAnswers < 3, isTrustPrompt(output) {
                session.send("\r")
                trustAnswers += 1
                output = ""
            }
            if Date() >= nextCheck {
                if await isRefreshed() { refreshed = true; break }
                nextCheck = Date().addingTimeInterval(1)
            }
            // Startup normally renews the token; `/status` makes Claude Code check the account if it didn't.
            // Only typed once the screen has rendered and settled, so it can't land in the trust prompt.
            if !statusSent, Date().timeIntervalSince(start) >= statusAfter,
               let lastOutput, Date().timeIntervalSince(lastOutput) >= 1 {
                session.send("/status\r")
                statusSent = true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await session.terminate()
        if refreshed { return true }
        return await isRefreshed()
    }

    /// Claude Code asks whether to trust a folder the first time it starts there; the default answer is yes.
    static func isTrustPrompt(_ terminalOutput: String) -> Bool {
        let text = terminalOutput
            .replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\u{1B}\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)"#, with: "", options: .regularExpression)
            .lowercased()
            .filter { $0.isLetter || $0 == "?" }
        return text.contains("doyoutrustthefilesinthisfolder?") || text.contains("yesitrustthisfolder")
            || text.contains("readytocodehere?")
    }

    /// A dedicated folder, so trusting it doesn't trust anything of the user's.
    private static func workingDirectory() throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FuelGauge/claude-token-refresh", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE_CODE_OAUTH_")
        }
        env["PATH"] = Shell.path
        env["TERM"] = "xterm-256color"
        env["DISABLE_AUTOUPDATER"] = "1"
        return env
    }
}

/// A child process attached to a pseudo-terminal, for CLIs that only run interactively.
private final class PTYSession {
    private let process: Process
    private let primary: Int32
    private let secondary: FileHandle
    private let group: pid_t?

    private init(process: Process, primary: Int32, secondary: FileHandle, group: pid_t?) {
        self.process = process
        self.primary = primary
        self.secondary = secondary
        self.group = group
    }

    static func launch(_ executable: String, _ args: [String], in dir: URL,
                       environment: [String: String]) throws -> PTYSession {
        var primary: Int32 = -1, secondary: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &size) == 0 else { throw POSIXError(.ENOTTY) }
        _ = fcntl(primary, F_SETFL, O_NONBLOCK)
        let secondaryHandle = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [executable] + args
        p.currentDirectoryURL = dir
        var env = environment
        env["PWD"] = dir.path
        p.environment = env
        p.standardInput = secondaryHandle
        p.standardOutput = secondaryHandle
        p.standardError = secondaryHandle
        do { try p.run() } catch {
            close(primary)
            throw error
        }
        // Own process group, so stopping it also stops anything it spawned.
        let pid = p.processIdentifier
        let group: pid_t? = (setpgid(pid, pid) == 0 || getpgid(pid) == pid) ? pid : nil
        return PTYSession(process: p, primary: primary, secondary: secondaryHandle, group: group)
    }

    var isRunning: Bool { process.isRunning }

    /// Drains pending output; it has to be read, or the child blocks once the terminal buffer fills.
    func readAvailable() -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(primary, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(primary, $0.baseAddress, $0.count) }
    }

    func terminate() async {
        signal(SIGTERM)
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { signal(SIGKILL) }
        close(primary)
        try? secondary.close()
    }

    private func signal(_ sig: Int32) {
        if let group { killpg(group, sig) } else { kill(process.processIdentifier, sig) }
    }
}
