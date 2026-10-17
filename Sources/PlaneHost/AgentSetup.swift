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

    /// What to run to add the plane, ready to paste.
    public static func command(_ agent: Agent, _ s: HostSettings) -> String {
        switch agent {
        case .claude:
            return "claude mcp add --scope user --transport http \(serverName) \(s.mcpURL) "
                + "--header \"Authorization: Bearer \(s.adminToken)\""
        case .codex:
            return "codex mcp add \(serverName) --url \(s.mcpURL) --bearer-token-env-var \(codexTokenVar)\n"
                + "export \(codexTokenVar)=\(s.adminToken)   # add this line to ~/.zshrc"
        }
    }

    /// Whether the agent's CLI is on the user's login shell PATH.
    public static func isInstalled(_ agent: Agent) async -> Bool {
        (try? await shell("command -v \(agent.rawValue)")).map { $0.status == 0 } ?? false
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
