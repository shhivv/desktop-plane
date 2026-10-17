import Foundation

/// Registers the plane's MCP endpoint with coding agents on this Mac. The app's onboarding and
/// `planed mcp` both use it.
public enum AgentSetup {
    public enum Agent: String, CaseIterable, Sendable {
        case claude, codex
        public var title: String { self == .claude ? "Claude Code" : "Codex" }
    }

    public static let serverName = "desktop-plane"
    public static let codexTokenVar = "DESKTOP_PLANE_TOKEN"

    /// For Codex on another computer: the server's table for ~/.codex/config.toml.
    public static func codexConfig(_ s: HostSettings) -> String {
        "[mcp_servers.\(serverName)]\nurl = \"\(s.mcpURL)\"\nhttp_headers = { Authorization = \"Bearer \(s.adminToken)\" }"
    }

    /// What to run to add the plane, ready to paste.
    public static func command(_ agent: Agent, _ s: HostSettings) -> String {
        switch agent {
        case .claude:
            return "claude mcp add --scope user --transport http \(serverName) \(s.mcpURL) "
                + "--header \"Authorization: Bearer \(s.adminToken)\""
        case .codex:
            return "# add to ~/.codex/config.toml\n" + codexConfig(s)
        }
    }

    /// Whether the agent's CLI is on the user's login shell PATH.
    public static func isInstalled(_ agent: Agent) async -> Bool {
        (try? await shell("command -v \(agent.rawValue)")).map { $0.status == 0 } ?? false
    }

    /// Whether the agent already has the plane at this host's current URL.
    public static func isConfigured(_ agent: Agent, _ s: HostSettings) async -> Bool {
        guard let r = try? await shell("\(agent.rawValue) mcp get \(serverName)"), r.status == 0 else { return false }
        return r.output.contains(s.mcpURL)
    }

    /// Adds (or replaces) the plane in the agent's config. For Codex the token goes into the
    /// server's headers in ~/.codex/config.toml, so no environment variable is needed.
    public static func install(_ agent: Agent, _ s: HostSettings) async throws -> String {
        let script: String
        switch agent {
        case .claude:
            script = "claude mcp remove --scope user \(serverName) >/dev/null 2>&1; " + command(.claude, s)
        case .codex:
            script = "codex mcp remove \(serverName) >/dev/null 2>&1; codex mcp add \(serverName) --url \(s.mcpURL)"
        }
        let r = try await shell(script)
        guard r.status == 0 else { throw PlaneError(r.output.isEmpty ? "\(agent.rawValue) exited with \(r.status)" : r.output) }
        if agent == .codex { try addCodexHeader(s.adminToken) }
        return r.output
    }

    /// Puts `http_headers = { Authorization = "Bearer …" }` in the server's table.
    static func addCodexHeader(_ token: String) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let header = "[mcp_servers.\(serverName)]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            throw PlaneError("codex did not add \(header) to \(url.path)")
        }
        var end = start + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        let body = lines[(start + 1)..<end].filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("http_headers") }
        let entry = "http_headers = { Authorization = \"Bearer \(token)\" }"
        lines.replaceSubrange((start + 1)..<end, with: [entry] + body)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o600)
    }

    /// Runs a program directly, without a shell. With a timeout, a program still running then is
    /// stopped and whatever it printed so far is returned (status -1).
    static func run(_ path: String, _ args: [String], timeout: TimeInterval? = nil) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                let lock = NSLock()
                var out = Data()
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    lock.withLock { out.append(d) }
                }
                do {
                    try p.run()
                    if let timeout {
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
                    }
                    p.waitUntilExit()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                    let text = lock.withLock { String(decoding: out + rest, as: UTF8.self) }
                    let status = p.terminationReason == .uncaughtSignal ? -1 : p.terminationStatus
                    cont.resume(returning: (status, text.trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Runs a command in the user's login shell, so a GUI app sees the same PATH as Terminal.
    static func shell(_ script: String) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", script]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do {
                    try p.run()
                    let out = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: (p.terminationStatus,
                                            String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}
