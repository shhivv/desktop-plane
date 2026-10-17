import Foundation
import PlaneCore

/// The plane's own MCP server at `/v1/mcp`: one stable endpoint an agent registers once.
///
/// It has tools to start, list, open apps in, screenshot and end desktops, and it forwards the
/// desktop driver's tools (arc-cua's `observe`, `act`, …) with one extra `desktop` argument
/// that picks the desktop. Leave `desktop` out when only one is running.
///
/// The driver's tool list comes from the last desktop that answered it, kept in
/// `guest-tools.json`. Until a desktop has run once, only `desktop_call` reaches the driver.
@MainActor
final class PlaneMCP {
    private unowned let manager: SessionManager
    /// MCP sessions (Mcp-Session-Id) on the plane endpoint.
    private var clients: [String: Client] = [:]

    final class Client {
        /// Desktops this client started, oldest first.
        var desktops: [String] = []
        /// Whether it has ever started one; such a client never falls back to someone else's.
        var startedAny = false
        /// One initialized driver connection per desktop.
        var bridges: [String: MCPBridge] = [:]
        /// Connections being opened, so parallel calls share one instead of racing.
        var opening: [String: Task<MCPBridge, Error>] = [:]
        /// Desktops whose driver must restart before the next call (an app was opened).
        var stale: Set<String> = []
        var lastSeen = Date()
        /// From initialize's clientInfo, e.g. "claude-code".
        var name = ""
        var version = ""
        var address = ""
    }

    /// Agents seen in the last ten minutes, most recent first. An agent opens a new MCP session
    /// each time it starts (and for health checks), so sessions from the same agent on the same
    /// computer are one entry.
    var connected: [ConnectedAgent] {
        let cutoff = Date().addingTimeInterval(-600)
        let recent = clients.values.filter { $0.lastSeen > cutoff }
        let groups = Dictionary(grouping: recent) { "\($0.name)|\($0.address)" }
        return groups.map { key, cs in
            let latest = cs.max { $0.lastSeen < $1.lastSeen }!
            return ConnectedAgent(id: key, name: latest.name, version: latest.version, address: latest.address,
                                  lastSeen: latest.lastSeen,
                                  desktops: cs.reduce(0) { $0 + $1.desktops.filter { self.manager.session($0) != nil }.count },
                                  sessions: cs.count)
        }
        .sorted { $0.lastSeen > $1.lastSeen }
    }

    init(manager: SessionManager) { self.manager = manager }

    static let version = "2025-06-18"
    static let cacheURL = Paths.root.appendingPathComponent("guest-tools.json")

    // MARK: transport

    /// Handles one POSTed JSON-RPC message. Returns the reply (nil for notifications) and, on
    /// initialize, the new Mcp-Session-Id.
    func handle(_ obj: [String: Any], session mid: String?, from address: String = "") async throws -> (Data?, String?) {
        let method = obj["method"] as? String
        var newID: String?
        let client: Client
        if let mid {
            guard let c = clients[mid] else { throw APIError(404, "unknown MCP session; initialize again") }
            client = c
        } else if method == "initialize" {
            prune()
            let id = Token.random(bytes: 16)
            client = Client()
            clients[id] = client
            newID = id
        } else {
            throw APIError(400, "missing Mcp-Session-Id header")
        }
        client.lastSeen = Date()
        if !address.isEmpty { client.address = address }
        client.bridges = client.bridges.filter { id, b in manager.session(id)?.mcp[b.id] != nil }
        guard let method, let rawID = obj["id"], !(rawID is NSNull) else { return (nil, newID) }
        let params = obj["params"] as? [String: Any] ?? [:]
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": rawID]
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any] {
                client.name = info["name"] as? String ?? ""
                client.version = info["version"] as? String ?? ""
            }
            reply["result"] = ["protocolVersion": params["protocolVersion"] as? String ?? Self.version,
                               "capabilities": ["tools": [:]],
                               "serverInfo": ["name": "desktop-plane", "version": "0.2.0"],
                               "instructions": instructions()]
        case "ping":
            reply["result"] = [:] as [String: Any]
        case "tools/list":
            reply["result"] = ["tools": tools()]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            if let forwarded = try await call(name, args, id: rawID, client: client) {
                return (forwarded, newID)
            }
            return (nil, newID)
        default:
            reply["error"] = ["code": -32601, "message": "unknown method \(method)"]
        }
        return (try JSONSerialization.data(withJSONObject: reply), newID)
    }

    func close(_ mid: String) {
        guard let c = clients.removeValue(forKey: mid) else { return }
        for b in c.bridges.values { b.close() }
    }

    /// Forgets clients that have been quiet for an hour; their desktops end on their own TTLs.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-3600)
        for (id, c) in clients where c.lastSeen < cutoff { close(id) }
    }

    // MARK: tools

    private func instructions() -> String {
        var s = """
        Desktop Plane gives you throwaway macOS desktops, each a fresh VM that is deleted when it ends.
        Start one with desktop_create, passing the apps or URLs you need in `open` (for example ["Safari", \
        "https://example.com"]); desktop_open opens more later. Then drive it with the other tools. Every \
        driver tool takes an optional `desktop` id; leave it out when one desktop is running. \
        desktop_screenshot shows the whole screen. Call desktop_end when you are done.
        """
        // Host-owned text only: nothing a guest says reaches every agent.
        s += "\n\nDriver: call observe(pid) to get a snapshot id and the window's elements, then " +
            "act(snapshot, action, element). apps lists running apps and their pids. If act returns " +
            "'changed' or 'stale', decide again from the fresh snapshot it returns. type_text, click_at, " +
            "press and scroll_at work at points in a window for what the elements don't cover."
        return s
    }

    private static let desktopArg: [String: Any] = [
        "type": "string",
        "description": "Desktop id from desktop_create or desktop_list. Optional when one desktop is running.",
    ]

    private func tools() -> [[String: Any]] {
        func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
            ["type": "object", "properties": props, "required": required, "additionalProperties": false]
        }
        let openArg: [String: Any] = ["type": "array", "items": ["type": "string"], "maxItems": 10,
                                      "description": "App names (\"Safari\", \"TextEdit\") or URLs to open."]
        var list: [[String: Any]] = [
            ["name": "desktop_create",
             "description": "Start a fresh macOS desktop and wait until it is ready (about 10–20 seconds). "
                + "Returns its id. Internet access defaults to ports 80 and 443 on any public host.",
             "inputSchema": schema([
                "open": openArg,
                "ttl_seconds": ["type": "integer", "description": "Lifetime in seconds (default 3600)."],
                "idle_timeout_seconds": ["type": "integer", "description": "End after this long without activity (default 900)."],
                "network": ["type": "object", "description": "Egress policy.",
                            "properties": ["enabled": ["type": "boolean"],
                                           "allow": ["type": "array", "items": ["type": "string"],
                                                     "description": "Host patterns, e.g. \"github.com\" or \"*.example.com\". Empty allows all."],
                                           "deny": ["type": "array", "items": ["type": "string"]],
                                           "ports": ["type": "array", "items": ["type": "integer"]]]],
                "volume": ["type": "string", "description": "Data volume id to mount at /Volumes/Data."],
             ])],
            ["name": "desktop_list",
             "description": "Desktops on this host: id, state, expiry, and whether you started it.",
             "inputSchema": schema([:])],
            ["name": "desktop_open",
             "description": "Open apps or URLs on a desktop, the way `open` does in Terminal. The driver "
                + "acts only on windows that are open, so use this to launch an app. Snapshots taken "
                + "before this call are no longer valid; observe again afterwards.",
             "inputSchema": schema(["desktop": Self.desktopArg, "targets": openArg], required: ["targets"])],
            ["name": "desktop_screenshot",
             "description": "A PNG of the desktop's whole screen.",
             "inputSchema": schema(["desktop": Self.desktopArg])],
            ["name": "desktop_end",
             "description": "End a desktop. Its VM and everything on it is deleted.",
             "inputSchema": schema(["desktop": Self.desktopArg])],
            ["name": "desktop_call",
             "description": "Call a driver tool by name on a desktop. Use it for a tool not listed here.",
             "inputSchema": schema(["desktop": Self.desktopArg,
                                    "tool": ["type": "string"],
                                    "arguments": ["type": "object"]], required: ["tool"])],
        ]
        let ours = Set(list.compactMap { $0["name"] as? String })
        for var t in (Self.cache()?["tools"] as? [[String: Any]]) ?? [] {
            guard let name = t["name"] as? String, !ours.contains(name) else { continue }
            var input = t["inputSchema"] as? [String: Any] ?? ["type": "object"]
            var props = input["properties"] as? [String: Any] ?? [:]
            props["desktop"] = Self.desktopArg
            input["properties"] = props
            t["inputSchema"] = input
            list.append(t)
        }
        return list
    }

    /// Runs a tool. Driver tools return the guest's reply as is; ours are built here.
    private func call(_ name: String, _ argsIn: [String: Any], id: Any, client: Client) async throws -> Data? {
        var args = argsIn
        func result(_ content: [[String: Any]], error: Bool = false) throws -> Data {
            var r: [String: Any] = ["content": content]
            if error { r["isError"] = true }
            return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": r])
        }
        func text(_ obj: Any) throws -> Data {
            let d = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            return try result([["type": "text", "text": String(decoding: d, as: UTF8.self)]])
        }
        do {
            switch name {
            case "desktop_create":
                let body = try JSONSerialization.data(withJSONObject: args)
                guard let req = try? JSONDecoder().decode(SessionManager.CreateRequest.self, from: body) else {
                    throw APIError(400, "invalid arguments")
                }
                let s = try await manager.create(req)
                client.desktops.append(s.id)
                client.startedAny = true
                return try text(describe(s, client))
            case "desktop_list":
                return try text(["desktops": manager.sessions.map { describe($0, client) }])
            case "desktop_open":
                let s = try desktop(args, client)
                guard let targets = args["targets"] as? [String], !targets.isEmpty else { throw APIError(400, "targets is required") }
                let r = try await s.openItems(targets)
                // arc-cua reads the running apps once, when it starts, so apps opened after that
                // are invisible to it. Drop the driver connections to this desktop; the next
                // call starts a fresh driver that sees them.
                for c in clients.values where c.bridges[s.id] != nil { c.stale.insert(s.id) }
                return try text(["desktop": s.id, "opened": targets, "error": r.map { $0 as Any } ?? NSNull()])
            case "desktop_screenshot":
                let s = try desktop(args, client)
                s.touch()
                let png = try await s.link.screenshot()
                return try result([["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]])
            case "desktop_end":
                let s = try desktop(args, client, ending: true)
                client.bridges.removeValue(forKey: s.id)?.close()
                await manager.destroy(s.id, reason: "ended by agent")
                client.desktops.removeAll { $0 == s.id }
                return try text(["desktop": s.id, "ended": true])
            case "desktop_call":
                guard let tool = args["tool"] as? String else { throw APIError(400, "tool is required") }
                let s = try desktop(args, client)
                return try await forward(tool, args["arguments"] as? [String: Any] ?? [:], id: id, s, client)
            default:
                let s = try desktop(args, client)
                args.removeValue(forKey: "desktop")
                return try await forward(name, args, id: id, s, client)
            }
        } catch {
            return try result([["type": "text", "text": error.localizedDescription]], error: true)
        }
    }

    /// The desktop a call means: the one named, else the only one this client started, else the
    /// only one running.
    /// The desktop a call means: the one named, else the only one this client started. A client
    /// that has never started one may use the only desktop running. Never another agent's
    /// desktop by default, and never to end it.
    private func desktop(_ args: [String: Any], _ client: Client, ending: Bool = false) throws -> Session {
        if let id = args["desktop"] as? String, !id.isEmpty {
            guard let s = manager.session(id) else { throw APIError(404, "no desktop \(id); desktop_list shows them") }
            return s
        }
        let ready = manager.sessions.filter { $0.state == .ready }
        let mine = ready.filter { client.desktops.contains($0.id) }
        if mine.count == 1 { return mine[0] }
        if mine.count > 1 {
            throw APIError(400, "you have several desktops (\(mine.map(\.id).joined(separator: ", "))); pass `desktop`")
        }
        if !ending, !client.startedAny, ready.count == 1 { return ready[0] }
        if client.startedAny { throw APIError(404, "your desktop has ended; start one with desktop_create") }
        if ready.isEmpty { throw APIError(404, "no desktop is running; start one with desktop_create") }
        throw APIError(400, ending ? "pass `desktop` to end a desktop you didn't start"
                                   : "several desktops are running (\(ready.map(\.id).joined(separator: ", "))); pass `desktop`")
    }

    private func describe(_ s: Session, _ client: Client) -> [String: Any] {
        let f = ISO8601DateFormatter()
        return ["desktop": s.id, "state": s.state.rawValue, "expires_at": f.string(from: s.expires),
                "mine": client.desktops.contains(s.id),
                "volume": s.volume == nil ? NSNull() : Volume.guestMountPoint as Any]
    }

    // MARK: driver

    private func forward(_ tool: String, _ args: [String: Any], id: Any, _ s: Session, _ client: Client) async throws -> Data? {
        let bridge = try await driver(s, client)
        s.touch()
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                  "params": ["name": tool, "arguments": args]]
        let reply = try await bridge.send(try JSONSerialization.data(withJSONObject: msg))
        s.touch()
        return reply
    }

    /// An initialized driver connection to the desktop, opened on first use.
    private func driver(_ s: Session, _ client: Client) async throws -> MCPBridge {
        if client.stale.remove(s.id) != nil, let old = client.bridges.removeValue(forKey: s.id) {
            // Calls already sent on the old connection may still be running; let them finish.
            Task { try? await Task.sleep(nanoseconds: 120_000_000_000); old.close() }
        }
        if let b = client.bridges[s.id], s.mcp[b.id] != nil { return b }
        if let t = client.opening[s.id] { return try await t.value }
        let manager = self.manager
        let t = Task { @MainActor () throws -> MCPBridge in
            let b = try await manager.openMCP(s)
            do {
                let initMsg: [String: Any] = ["jsonrpc": "2.0", "id": "plane:init", "method": "initialize",
                                              "params": ["protocolVersion": Self.version, "capabilities": [:] as [String: Any],
                                                         "clientInfo": ["name": "desktop-plane", "version": "0.2.0"]]]
                _ = try await b.send(try JSONSerialization.data(withJSONObject: initMsg), timeout: 60)
                _ = try await b.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
                return b
            } catch {
                b.close()
                throw error
            }
        }
        client.opening[s.id] = t
        defer { client.opening[s.id] = nil }
        let b = try await t.value
        client.bridges[s.id] = b
        return b
    }

    /// The driver's tool list, learned once from the golden image while it was snapshotted (a
    /// guest the owner built), never from a tenant's desktop. Loaded once per process.
    static func cache() -> [String: Any]? {
        if let c = cached { return c }
        guard let d = try? Data(contentsOf: cacheURL), d.count <= maxCacheBytes,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        cached = o
        return o
    }
    nonisolated(unsafe) private static var cached: [String: Any]?
    static let maxCacheBytes = 256 << 10

    /// Records the driver's tools from a tools/list reply, within limits.
    static func remember(tools: Data?) {
        guard let tools, let o = try? JSONSerialization.jsonObject(with: tools) as? [String: Any],
              let list = (o["result"] as? [String: Any])?["tools"] as? [[String: Any]], !list.isEmpty else { return }
        let kept = list.prefix(64).compactMap { t -> [String: Any]? in
            guard let name = t["name"] as? String, name.count <= 64,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
            var t = t
            if let d = t["description"] as? String, d.count > 2000 { t["description"] = String(d.prefix(2000)) }
            return t
        }
        guard let d = try? JSONSerialization.data(withJSONObject: ["tools": kept], options: [.sortedKeys]),
              d.count <= maxCacheBytes else { return }
        try? d.write(to: cacheURL, options: .atomic)
        cached = nil
    }
}

/// An agent connected to the plane endpoint, for the app to show.
public struct ConnectedAgent: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let address: String
    public let lastSeen: Date
    public let desktops: Int
    /// MCP sessions this agent has open from that computer.
    public let sessions: Int
}
