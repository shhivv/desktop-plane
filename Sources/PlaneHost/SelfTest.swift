import Foundation
import PlaneCore

/// End-to-end checks against a running host: the API's tenant boundaries, MCP through to
/// arc-cua, and network probes run inside a real guest. `planed selftest` runs it.
@MainActor
public enum SelfTest {
    struct Failure: Error { let msg: String }

    public static func run(service: PlaneService) async -> Bool {
        let base = service.baseURL
        let admin = service.settings.adminToken
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }

        @Sendable func call(_ method: String, _ path: String, token: String?, body: Any? = nil,
                  headers: [String: String] = [:]) async -> (Int, Data, [String: String]) {
            var r = URLRequest(url: URL(string: base + path)!)
            r.httpMethod = method
            r.timeoutInterval = 600
            if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            if let body {
                r.httpBody = try? JSONSerialization.data(withJSONObject: body)
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            guard let (data, res) = try? await URLSession.shared.data(for: r), let h = res as? HTTPURLResponse else {
                return (0, Data(), [:])
            }
            var hs: [String: String] = [:]
            for (k, v) in h.allHeaderFields { hs[String(describing: k).lowercased()] = String(describing: v) }
            return (h.statusCode, data, hs)
        }
        func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:] }

        print("Creating two sessions…")
        let t0 = Date()
        async let ca = call("POST", "/v1/sessions", token: admin, body: ["ttl_seconds": 600])
        async let cb = call("POST", "/v1/sessions", token: admin, body: ["ttl_seconds": 600, "network": ["enabled": false]])
        let (ra, rb) = await (ca, cb)
        let a = json(ra.1), b = json(rb.1)
        check("create session A", ra.0 == 201, "\(ra.0) \(a["error"] ?? a["boot"] ?? "")")
        check("create session B", rb.0 == 201, "\(rb.0) \(b["error"] ?? b["boot"] ?? "")")
        print(String(format: "  both ready in %.1fs", Date().timeIntervalSince(t0)))
        guard ra.0 == 201, let aid = a["id"] as? String, let atok = a["token"] as? String else {
            print("cannot continue without session A")
            return false
        }
        let bid = b["id"] as? String ?? "ses_none", btok = b["token"] as? String ?? "none"

        // Tenant boundaries in the API.
        check("A's token cannot read B", await call("GET", "/v1/sessions/\(bid)", token: atok).0 == 404)
        check("A's token cannot delete B", await call("DELETE", "/v1/sessions/\(bid)", token: atok).0 == 404)
        check("A's token cannot list sessions", await call("GET", "/v1/sessions", token: atok).0 == 401)
        check("A's token cannot create sessions", await call("POST", "/v1/sessions", token: atok, body: [:]).0 == 401)
        check("no token is refused", await call("GET", "/v1/sessions/\(aid)", token: nil).0 == 401)
        check("cross-origin browser request is refused",
              await call("GET", "/v1/sessions/\(aid)", token: atok, headers: ["Origin": "https://evil.example"]).0 == 403)

        // MCP through to arc-cua.
        let initBody: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                  "clientInfo": ["name": "selftest", "version": "1"]]]
        let ri = await call("POST", "/v1/sessions/\(aid)/mcp", token: atok, body: initBody)
        let mid = ri.2["mcp-session-id"] ?? ""
        check("MCP initialize", ri.0 == 200 && !mid.isEmpty, "\(ri.0) \(String(decoding: ri.1.prefix(160), as: UTF8.self))")
        _ = await call("POST", "/v1/sessions/\(aid)/mcp", token: atok,
                       body: ["jsonrpc": "2.0", "method": "notifications/initialized"], headers: ["Mcp-Session-Id": mid])
        let rl = await call("POST", "/v1/sessions/\(aid)/mcp", token: atok,
                            body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], headers: ["Mcp-Session-Id": mid])
        let tools = ((json(rl.1)["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        check("MCP tools/list", !tools.isEmpty, tools.prefix(8).joined(separator: ", "))
        if tools.contains("status") {
            let rs = await call("POST", "/v1/sessions/\(aid)/mcp", token: atok,
                                body: ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                       "params": ["name": "status", "arguments": [:]]],
                                headers: ["Mcp-Session-Id": mid])
            let text = String(decoding: rs.1, as: UTF8.self)
            check("arc-cua status reports accessibility", text.contains(#"\"accessibility\": true"#) || text.contains(#"\"accessibility\":true"#),
                  String(text.prefix(300)))
        }
        if rb.0 == 201 {
            check("A's MCP session is unknown to B",
                  await call("POST", "/v1/sessions/\(bid)/mcp", token: btok,
                             body: ["jsonrpc": "2.0", "id": 9, "method": "tools/list"], headers: ["Mcp-Session-Id": mid]).0 == 404)
        }
        let shot = await call("GET", "/v1/sessions/\(aid)/screenshot", token: atok)
        check("screenshot", shot.0 == 200 && shot.1.starts(with: [0x89, 0x50]), "\(shot.0), \(shot.1.count) bytes")

        // Network probes from inside guest A.
        if let sa = service.manager.session(aid) {
            let hostIP = lanAddress() ?? "192.168.1.1"
            let curl = "curl -s -o /dev/null -w '%{http_code}' -m 8"
            let proxy = "-x http://127.0.0.1:\(GuestLAN.proxyPort)"
            let probes: [(String, String, (String) -> Bool)] = [
                ("guest: direct internet is blocked", "\(curl) --noproxy '*' https://example.com", { $0 == "000" }),
                ("guest: host via gateway IP is blocked", "\(curl) --noproxy '*' http://\(GuestLAN.gatewayIP.map(String.init).joined(separator: ".")):\(service.settings.port)/v1/health", { $0 == "000" }),
                ("guest: direct LAN is blocked", "\(curl) --noproxy '*' http://\(hostIP):\(service.settings.port)/v1/health", { $0 == "000" }),
                ("guest: proxy reaches the internet", "\(curl) \(proxy) https://example.com", { $0 == "200" }),
                ("guest: proxy refuses host loopback", "\(curl) \(proxy) http://127.0.0.1:\(service.settings.port)/v1/health", { $0 == "403" }),
                ("guest: proxy refuses host LAN address", "\(curl) \(proxy) http://\(hostIP):\(service.settings.port)/v1/health", { $0 == "403" }),
                ("guest: proxy refuses metadata address", "\(curl) \(proxy) http://169.254.169.254/", { $0 == "403" }),
                ("guest: proxy refuses names that resolve private", "\(curl) \(proxy) http://localtest.me/", { $0 == "403" }),
                ("guest: proxy refuses non-web ports", "\(curl) \(proxy) https://github.com:22/", { $0 == "000" || $0 == "403" }),
            ]
            for (name, cmd, ok) in probes {
                let out = (try? await guestShell(sa, cmd)) ?? "error"
                check(name, ok(out.trimmingCharacters(in: .whitespacesAndNewlines)), out)
            }
            if rb.0 == 201, let sb = service.manager.session(bid) {
                let out = (try? await guestShell(sb, "\(curl) \(proxy) http://example.com")) ?? "error"
                check("guest B (egress disabled): proxy refuses everything", out == "403", out)
                let clockA = (try? await guestShell(sa, "date +%s")) ?? "0"
                let skew = abs((Double(clockA.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) - Date().timeIntervalSince1970)
                check("guest clock synced after restore", skew < 30, "skew \(Int(skew))s")
            }
        }

        // Teardown leaves nothing behind.
        let dirA = Paths.sessions.appendingPathComponent(aid)
        check("session files exist while running", FileManager.default.fileExists(atPath: dirA.path))
        check("A can delete itself", await call("DELETE", "/v1/sessions/\(aid)", token: atok).0 == 204)
        if rb.0 == 201 { _ = await call("DELETE", "/v1/sessions/\(bid)", token: admin) }
        check("session files are gone after delete", !FileManager.default.fileExists(atPath: dirA.path))
        check("deleted session's token is dead", await call("GET", "/v1/sessions/\(aid)", token: atok).0 == 404)

        // Data volumes: only the volume survives; the VM is new every time.
        print("Data volume…")
        let rv = await call("POST", "/v1/volumes", token: admin, body: ["name": "selftest", "size_gb": 2])
        let vid = json(rv.1)["id"] as? String ?? ""
        check("create volume", rv.0 == 201, "\(rv.0) \(json(rv.1)["error"] ?? vid)")
        if rv.0 == 201 {
            let rc = await call("POST", "/v1/sessions", token: admin, body: ["volume": vid])
            let c = json(rc.1)
            check("session with volume", rc.0 == 201 && (c["volume"] as? [String: Any])?["mount"] as? String == Volume.guestMountPoint,
                  "\(rc.0) \(c["error"] ?? c["detail"] ?? "")")
            check("volume cannot attach to two sessions",
                  await call("POST", "/v1/sessions", token: admin, body: ["volume": vid]).0 == 409)
            check("volume cannot be deleted while attached", await call("DELETE", "/v1/volumes/\(vid)", token: admin).0 == 409)
            if let cid = c["id"] as? String, let sc = service.manager.session(cid) {
                let w = (try? await guestShell(sc, "echo kept > \(Volume.guestMountPoint)/marker && echo wrote; echo gone > ~/dp-scratch")) ?? "error"
                check("write to volume", w.contains("wrote"), w.replacingOccurrences(of: "\n", with: " | "))
                _ = await call("DELETE", "/v1/sessions/\(cid)", token: admin)
            }
            check("volume is free after its session ends",
                  json(await call("GET", "/v1/volumes/\(vid)", token: admin).1)["attached_to"] is NSNull)
            let re = await call("POST", "/v1/sessions", token: admin, body: ["volume": vid])
            if re.0 == 201, let eid = json(re.1)["id"] as? String, let se = service.manager.session(eid) {
                let kept = (try? await guestShell(se, "cat \(Volume.guestMountPoint)/marker")) ?? ""
                check("volume data survives into a new session", kept.contains("kept"), kept)
                let gone = (try? await guestShell(se, "cat ~/dp-scratch 2>/dev/null || echo absent")) ?? ""
                check("data outside the volume does not", gone.contains("absent"), gone)
                _ = await call("DELETE", "/v1/sessions/\(eid)", token: admin)
            } else {
                check("second session with volume", false, "\(re.0)")
            }
            let vdir = Paths.volumes.appendingPathComponent(vid)
            check("delete volume", await call("DELETE", "/v1/volumes/\(vid)", token: admin).0 == 204)
            check("volume files are gone", !FileManager.default.fileExists(atPath: vdir.path))
        }

        print("\n\(passed) passed, \(failed) failed")
        return failed == 0
    }

    /// Runs a shell command in the guest through the agent's MCP port (host-only test hook:
    /// tenants cannot choose the command; only the host writes this header).
    static func guestShell(_ s: Session, _ cmd: String) async throws -> String {
        let fd = try await s.link.connect(port: VsockPort.guestMCP)
        return try await GuestLink.blocking(timeout: 30, fd: fd) {
            defer { close(fd) }
            try FD.writeAll(fd, Data("#!cmd \(cmd) </dev/null\n".utf8))
            var out = Data()
            while let chunk = try? FD.readSome(fd), !chunk.isEmpty { out.append(chunk) }
            return String(decoding: out, as: UTF8.self)
        }
    }

    /// The host's primary LAN IPv4 address, to prove the guest cannot reach it.
    static func lanAddress() -> String? {
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0, let first = ifs else { return nil }
        defer { freeifaddrs(first) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            let name = String(cString: i.pointee.ifa_name)
            if name.hasPrefix("en"), let a = i.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            p = i.pointee.ifa_next
        }
        return nil
    }
}
