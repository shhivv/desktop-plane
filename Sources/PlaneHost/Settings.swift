import Foundation

public enum Paths {
    public static var root: URL {
        if let o = ProcessInfo.processInfo.environment["PLANE_HOME"] { return URL(fileURLWithPath: o) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DesktopPlane")
    }
    public static var ipsw: URL { root.appendingPathComponent("ipsw") }
    public static var images: URL { root.appendingPathComponent("images") }
    public static var sessions: URL { root.appendingPathComponent("sessions") }
    public static var settings: URL { root.appendingPathComponent("settings.json") }
    public static var log: URL { root.appendingPathComponent("planed.log") }
    public static var lock: URL { root.appendingPathComponent("planed.lock") }

    public static func ensure() throws {
        for d in [root, ipsw, images, sessions] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // Nothing in here is for anyone but this user.
        chmod(root.path, 0o700)
    }
}

public struct HostSettings: Codable, Sendable {
    /// Address the API binds to. Keep it on loopback and put a tunnel (Tailscale, SSH) in front
    /// to reach it from elsewhere.
    public var bindAddress: String = "127.0.0.1"
    public var port: UInt16 = 7480
    /// Bearer token for creating, listing and deleting sessions.
    public var adminToken: String = Token.random()
    /// Concurrent VMs. macOS allows at most 2 macOS guests per host.
    public var maxVMs: Int = 2
    public var cpusPerVM: Int = 4
    public var memoryGBPerVM: Int = 8
    public var defaultTTLSeconds: Int = 3600
    public var maxTTLSeconds: Int = 24 * 3600
    public var defaultIdleTimeoutSeconds: Int = 900
    public var image: String = "default"
    /// Command run in the guest per MCP session. Empty = the guest agent's default (`arc-cua mcp`).
    public var guestMCPCommand: String = ""

    public init() {}

    public static func load() -> HostSettings {
        if let data = try? Data(contentsOf: Paths.settings),
           let s = try? JSONDecoder().decode(HostSettings.self, from: data) {
            return s.clamped()
        }
        let s = HostSettings()
        try? s.save()
        return s
    }

    public func save() throws {
        try Paths.ensure()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Paths.settings, options: .atomic)
        chmod(Paths.settings.path, 0o600)
    }

    func clamped() -> HostSettings {
        var s = self
        s.maxVMs = min(max(s.maxVMs, 1), 2)
        s.cpusPerVM = max(2, s.cpusPerVM)
        s.memoryGBPerVM = max(4, s.memoryGBPerVM)
        return s
    }
}

public enum Token {
    public static func random(bytes: Int = 32) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes, &b) == errSecSuccess)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison.
    public static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }
}
