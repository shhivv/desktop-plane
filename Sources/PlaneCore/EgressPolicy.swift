import Foundation

/// Decides which destinations a VM may reach through the egress proxy.
///
/// Non-public addresses are always refused, whatever the allow list says: they are how a
/// guest would reach the host, the LAN, another VM or a cloud metadata endpoint. The check
/// runs on the resolved address that the proxy then connects to, so DNS rebinding cannot
/// slip a private address past it.
public struct EgressPolicy: Codable, Sendable, Equatable {
    /// false: no egress at all.
    public var enabled: Bool
    /// Host patterns. Empty means any public host. "example.com" matches it and its subdomains;
    /// "*" matches everything.
    public var allow: [String]
    /// Host patterns refused even when allowed.
    public var deny: [String]
    /// Destination ports. Empty means any port.
    public var ports: [Int]

    public init(enabled: Bool = true, allow: [String] = [], deny: [String] = [], ports: [Int] = [80, 443]) {
        self.enabled = enabled
        self.allow = allow
        self.deny = deny
        self.ports = ports
    }

    /// Missing fields take their defaults, so `{"enabled": false}` or `{"allow": [...]}` work.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EgressPolicy()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        allow = try c.decodeIfPresent([String].self, forKey: .allow) ?? d.allow
        deny = try c.decodeIfPresent([String].self, forKey: .deny) ?? d.deny
        ports = try c.decodeIfPresent([Int].self, forKey: .ports) ?? d.ports
    }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(String)
    }

    /// Checks the hostname and port, before DNS.
    public func check(host: String, port: Int) -> Verdict {
        guard enabled else { return .denied("egress disabled for this session") }
        guard (1...65535).contains(port) else { return .denied("bad port") }
        if !ports.isEmpty && !ports.contains(port) { return .denied("port \(port) not allowed") }
        let h = Self.normalize(host)
        if h.isEmpty { return .denied("empty host") }
        if deny.contains(where: { Self.matches(pattern: $0, host: h) }) { return .denied("host denied") }
        if !allow.isEmpty && !allow.contains(where: { Self.matches(pattern: $0, host: h) }) {
            return .denied("host not in allow list")
        }
        // A literal IP must also pass the address check.
        if let bytes = IPAddress.parse(h), !IPAddress.isPublic(bytes) {
            return .denied("non-public address")
        }
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") {
            return .denied("local name")
        }
        return .allowed
    }

    static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func matches(pattern: String, host: String) -> Bool {
        var p = normalize(pattern)
        if p == "*" { return true }
        if p.hasPrefix("*.") { p.removeFirst(2) }
        if p.hasPrefix(".") { p.removeFirst() }
        return host == p || host.hasSuffix("." + p)
    }
}

public enum IPAddress {
    /// Parses a literal IPv4 (4 bytes) or IPv6 (16 bytes) address.
    public static func parse(_ s: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    /// true only for globally routable unicast addresses.
    public static func isPublic(_ b: [UInt8]) -> Bool {
        if b.count == 4 { return isPublicV4(b) }
        if b.count == 16 { return isPublicV6(b) }
        return false
    }

    static func inV4(_ b: [UInt8], _ net: [UInt8], _ bits: Int) -> Bool {
        let a = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        let n = UInt32(net[0]) << 24 | UInt32(net[1]) << 16 | UInt32(net[2]) << 8 | UInt32(net[3])
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        return a & mask == n & mask
    }

    static let blockedV4: [([UInt8], Int)] = [
        ([0, 0, 0, 0], 8),        // "this network"
        ([10, 0, 0, 0], 8),       // private
        ([100, 64, 0, 0], 10),    // CGNAT (also Tailscale)
        ([127, 0, 0, 0], 8),      // loopback
        ([169, 254, 0, 0], 16),   // link-local, cloud metadata
        ([172, 16, 0, 0], 12),    // private
        ([192, 0, 0, 0], 24),     // IETF protocol assignments
        ([192, 0, 2, 0], 24),     // TEST-NET-1
        ([192, 88, 99, 0], 24),   // 6to4 relay
        ([192, 168, 0, 0], 16),   // private
        ([198, 18, 0, 0], 15),    // benchmarking
        ([198, 51, 100, 0], 24),  // TEST-NET-2
        ([203, 0, 113, 0], 24),   // TEST-NET-3
        ([224, 0, 0, 0], 4),      // multicast
        ([240, 0, 0, 0], 4),      // reserved + broadcast
    ]

    static func isPublicV4(_ b: [UInt8]) -> Bool {
        !blockedV4.contains { inV4(b, $0.0, $0.1) }
    }

    static func isPublicV6(_ b: [UInt8]) -> Bool {
        // IPv4-mapped (::ffff:a.b.c.d) and NAT64 (64:ff9b::/96): judge the embedded IPv4.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isPublicV4(Array(b[12..<16]))
        }
        if b[0..<12] == [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] {
            return isPublicV4(Array(b[12..<16]))
        }
        // Only global unicast 2000::/3 is public.
        guard b[0] & 0xe0 == 0x20 else { return false }
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false } // documentation
        if b[0] == 0x20 && b[1] == 0x02 { return false } // 6to4 can embed private IPv4
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00 { return false } // Teredo
        return true
    }
}
