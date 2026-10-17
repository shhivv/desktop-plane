import Foundation

/// How agents on other computers reach this Mac. The agents run on the person's own computer;
/// this Mac only serves desktops, so its API has to be reachable from there.
public enum Reachability {
    public enum Mode: String, Sendable { case local, tailscale, lan }

    public struct Tailnet: Sendable {
        /// e.g. "mini.tail1234.ts.net"
        public let dnsName: String
        public func url(port: UInt16) -> String { "https://\(dnsName):\(port)" }
    }

    /// The mode the settings describe right now.
    public static func mode(_ s: HostSettings) -> Mode {
        if s.publicURL.hasPrefix("https://"), URL(string: s.publicURL)?.host?.hasSuffix(".ts.net") == true { return .tailscale }
        if s.bindAddress != "127.0.0.1" { return .lan }
        return .local
    }

    /// The Tailscale CLI, if Tailscale is installed (the app bundle's CLI or a PATH one).
    static func tailscaleCLI() -> String? {
        ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// This Mac's name on the tailnet, when Tailscale is installed and connected.
    public static func tailnet() async -> Tailnet? {
        guard let cli = tailscaleCLI(), let r = try? await AgentSetup.run(cli, ["status", "--json"]), r.status == 0,
              let obj = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any],
              obj["BackendState"] as? String == "Running",
              let me = obj["Self"] as? [String: Any], var dns = me["DNSName"] as? String, !dns.isEmpty else { return nil }
        if dns.hasSuffix(".") { dns.removeLast() }
        return Tailnet(dnsName: dns)
    }

    public static var tailscaleInstalled: Bool { tailscaleCLI() != nil }

    /// Serves the API on the tailnet over HTTPS (`tailscale serve`) on the API's own port, so
    /// nothing else the person serves on the tailnet is touched. Keeps the API on loopback and
    /// records the tailnet URL as the address clients use.
    public static func useTailscale(_ s: HostSettings) async throws -> HostSettings {
        guard let cli = tailscaleCLI() else { throw PlaneError("Tailscale isn't installed on this Mac") }
        guard let net = await tailnet() else { throw PlaneError("Tailscale is installed but not signed in. Open Tailscale and sign in.") }
        let r = try await AgentSetup.run(cli, ["serve", "--bg", "--https=\(s.port)", "http://127.0.0.1:\(s.port)"], timeout: 20)
        if let link = r.output.range(of: #"https://login\.tailscale\.com/\S+"#, options: .regularExpression) {
            // Serve or HTTPS certificates are off for the tailnet; the admin has to turn them on.
            throw PlaneError("Tailscale needs Serve turned on for your tailnet. Open \(r.output[link]), turn it on, then try again.")
        }
        guard r.status == 0 else { throw PlaneError(r.output.isEmpty ? "tailscale serve didn't finish" : r.output) }
        var n = s
        n.bindAddress = "127.0.0.1"
        n.publicURL = net.url(port: s.port)
        return n
    }

    /// Stops serving the API on the tailnet, if this app set it up.
    static func stopServing(_ s: HostSettings) async {
        guard mode(s) == .tailscale, let cli = tailscaleCLI() else { return }
        let port = URL(string: s.publicURL)?.port ?? 443
        _ = try? await AgentSetup.run(cli, ["serve", "--https=\(port)", "off"], timeout: 10)
    }

    /// Listens on every network so computers on the same network can reach it, at this Mac's
    /// Bonjour name. Plain HTTP: the token crosses the network unencrypted.
    public static func useLAN(_ s: HostSettings) async -> HostSettings {
        await stopServing(s)
        var n = s
        n.bindAddress = "0.0.0.0"
        n.publicURL = "http://\(localHostName()):\(s.port)"
        return n
    }

    /// Back to this Mac only. Turns `tailscale serve` off if it was serving the API.
    public static func useLocalOnly(_ s: HostSettings) async -> HostSettings {
        await stopServing(s)
        var n = s
        n.bindAddress = "127.0.0.1"
        n.publicURL = ""
        return n
    }

    /// "Shivs-Mac-mini.local"
    public static func localHostName() -> String {
        (SCLocalHostName() ?? ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "localhost") + ".local"
    }

    private static func SCLocalHostName() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        p.arguments = ["--get", "LocalHostName"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
