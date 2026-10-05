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
    /// Size of the virtual disk when the golden image is installed. Sparse: only what the
    /// guest writes takes space.
    public var diskGB: Int = 80
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

    // Older settings files lack newer keys; decode each with its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HostSettings()
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? d.bindAddress
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        adminToken = try c.decodeIfPresent(String.self, forKey: .adminToken) ?? d.adminToken
        maxVMs = try c.decodeIfPresent(Int.self, forKey: .maxVMs) ?? d.maxVMs
        cpusPerVM = try c.decodeIfPresent(Int.self, forKey: .cpusPerVM) ?? d.cpusPerVM
        memoryGBPerVM = try c.decodeIfPresent(Int.self, forKey: .memoryGBPerVM) ?? d.memoryGBPerVM
        diskGB = try c.decodeIfPresent(Int.self, forKey: .diskGB) ?? d.diskGB
        defaultTTLSeconds = try c.decodeIfPresent(Int.self, forKey: .defaultTTLSeconds) ?? d.defaultTTLSeconds
        maxTTLSeconds = try c.decodeIfPresent(Int.self, forKey: .maxTTLSeconds) ?? d.maxTTLSeconds
        defaultIdleTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .defaultIdleTimeoutSeconds) ?? d.defaultIdleTimeoutSeconds
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? d.image
        guestMCPCommand = try c.decodeIfPresent(String.self, forKey: .guestMCPCommand) ?? d.guestMCPCommand
    }

    public static var hostCPUs: Int { ProcessInfo.processInfo.activeProcessorCount }
    public static var hostMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }
    public static let cpuRange = 2...max(2, hostCPUs)
    public static let memoryRange = 4...max(4, hostMemoryGB - 4)
    public static let diskRange = 40...1000

    func clamped() -> HostSettings {
        var s = self
        s.maxVMs = min(max(s.maxVMs, 1), 2)
        s.cpusPerVM = min(max(s.cpusPerVM, Self.cpuRange.lowerBound), Self.cpuRange.upperBound)
        s.memoryGBPerVM = min(max(s.memoryGBPerVM, Self.memoryRange.lowerBound), Self.memoryRange.upperBound)
        s.diskGB = min(max(s.diskGB, Self.diskRange.lowerBound), Self.diskRange.upperBound)
        s.defaultTTLSeconds = max(60, s.defaultTTLSeconds)
        s.maxTTLSeconds = max(s.defaultTTLSeconds, s.maxTTLSeconds)
        s.defaultIdleTimeoutSeconds = max(60, s.defaultIdleTimeoutSeconds)
        return s
    }

    /// Problems that make the settings unusable.
    public func errors() -> [String] {
        var e: [String] = []
        if !(1...2).contains(maxVMs) { e.append("running desktops must be 1 or 2 (macOS allows 2 VMs per host)") }
        if !Self.cpuRange.contains(cpusPerVM) { e.append("CPUs per VM must be \(Self.cpuRange.lowerBound)–\(Self.cpuRange.upperBound)") }
        if !Self.memoryRange.contains(memoryGBPerVM) { e.append("memory per VM must be \(Self.memoryRange.lowerBound)–\(Self.memoryRange.upperBound) GB") }
        if !Self.diskRange.contains(diskGB) { e.append("disk must be \(Self.diskRange.lowerBound)–\(Self.diskRange.upperBound) GB") }
        if port < 1024 { e.append("port must be 1024 or higher") }
        var a = in_addr()
        if inet_pton(AF_INET, bindAddress, &a) != 1 { e.append("bind address must be an IPv4 address, like 127.0.0.1 or 0.0.0.0") }
        if defaultTTLSeconds < 60 || defaultIdleTimeoutSeconds < 60 { e.append("TTL and idle timeout must be at least 60 seconds") }
        return e
    }

    /// Allowed, but worth a second look.
    public func warnings() -> [String] {
        var w: [String] = []
        if memoryGBPerVM * maxVMs > Self.hostMemoryGB - 4 {
            w.append("\(maxVMs) × \(memoryGBPerVM) GB leaves less than 4 GB for macOS on this \(Self.hostMemoryGB) GB Mac")
        }
        if cpusPerVM * maxVMs > Self.hostCPUs {
            w.append("\(maxVMs) × \(cpusPerVM) CPUs is more than this Mac's \(Self.hostCPUs) cores; VMs will compete")
        }
        if bindAddress != "127.0.0.1" {
            w.append("the API will be reachable from other machines on \(bindAddress); prefer a tunnel such as Tailscale or SSH")
        }
        return w
    }

    /// Whether the golden image's snapshots were taken with different CPU/memory than these
    /// settings, or there are fewer snapshot slots than running VMs allowed. Sessions keep using the snapshot's size until the image is re-snapshotted.
    public func needsResnapshot(_ image: VMImage?) -> Bool {
        guard let image, image.meta.stage == .ready else { return false }
        let m = image.meta
        return m.cpus != cpusPerVM || m.memoryGB != memoryGBPerVM || image.slotImages().count < maxVMs
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
