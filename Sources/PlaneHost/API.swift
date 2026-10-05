import Foundation
import PlaneCore

/// REST + MCP routes.
///
///     GET    /v1/health
///     POST   /v1/sessions                     admin
///     GET    /v1/sessions                     admin
///     GET    /v1/sessions/:id                 admin or that session's token
///     DELETE /v1/sessions/:id                 admin or that session's token
///     POST   /v1/sessions/:id/mcp             MCP Streamable HTTP (JSON responses)
///     DELETE /v1/sessions/:id/mcp             end an MCP session (Mcp-Session-Id header)
///     GET    /v1/sessions/:id/screenshot      PNG
struct API {
    let manager: SessionManager

    @MainActor
    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        // Browsers must not be able to drive this API from a web page (DNS rebinding, CSRF).
        if let origin = req.header("origin"), !Self.isLocalOrigin(origin) {
            return .error(403, "cross-origin requests are not allowed")
        }
        // "/v1/sessions/ses_x/mcp" -> route "/v1/sessions/:id/mcp", id "ses_x"
        var parts = req.path.split(separator: "/").map(String.init)
        var id = ""
        if parts.count >= 3, parts[0] == "v1", parts[1] == "sessions" { id = parts[2]; parts[2] = ":id" }
        let route = req.method + " /" + parts.joined(separator: "/")
        do {
            switch route {
            case "GET /v1/health":
                let image = VMImage.load(named: manager.settings.image)
                return .json(200, ["ok": true, "image": image?.meta.stage.rawValue ?? "missing",
                                   "slots_total": manager.settings.maxVMs,
                                   "slots_free": manager.settings.maxVMs - manager.live.count])

            case "POST /v1/sessions":
                try requireAdmin(req)
                let body = req.body.isEmpty ? Data("{}".utf8) : req.body
                guard let create = try? JSONDecoder().decode(SessionManager.CreateRequest.self, from: body) else {
                    throw APIError(400, "invalid JSON body")
                }
                let s = try await manager.create(create)
                var obj = describe(s, req)
                obj["token"] = s.token
                return .json(201, obj)

            case "GET /v1/sessions":
                try requireAdmin(req)
                return .json(200, ["sessions": manager.sessions.map { describe($0, req) }])

            case "GET /v1/sessions/:id":
                return .json(200, describe(try authorize(req, id), req))

            case "DELETE /v1/sessions/:id":
                _ = try authorize(req, id)
                await manager.destroy(id, reason: "deleted via API")
                return HTTPResponse(status: 204)

            case "POST /v1/sessions/:id/mcp":
                return try await mcp(req, try authorize(req, id))

            case "DELETE /v1/sessions/:id/mcp":
                let s = try authorize(req, id)
                if let mid = req.header("mcp-session-id"), let b = s.mcp[mid] { b.close() }
                return HTTPResponse(status: 204)

            case "GET /v1/sessions/:id/mcp":
                // No server-initiated stream; allowed by the Streamable HTTP transport.
                return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])

            case "GET /v1/sessions/:id/screenshot":
                let s = try authorize(req, id)
                s.touch()
                let png = try await s.link.screenshot()
                return HTTPResponse(status: 200, headers: ["Content-Type": "image/png"], body: png)

            default:
                return .error(404, "not found")
            }
        } catch let e as APIError {
            return .error(e.status, e.message)
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    @MainActor
    private func mcp(_ req: HTTPRequest, _ s: Session) async throws -> HTTPResponse {
        s.touch()
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            throw APIError(400, "expected one JSON-RPC message")
        }
        let bridge: MCPBridge
        var headers: [String: String] = [:]
        if let mid = req.header("mcp-session-id") {
            guard let b = s.mcp[mid] else { throw APIError(404, "unknown MCP session; initialize again") }
            bridge = b
        } else if obj["method"] as? String == "initialize" {
            bridge = try await manager.openMCP(s)
            headers["Mcp-Session-Id"] = bridge.id
        } else {
            throw APIError(400, "missing Mcp-Session-Id header")
        }
        guard let reply = try await bridge.send(req.body) else { return HTTPResponse(status: 202, headers: headers) }
        s.touch()
        headers["Content-Type"] = "application/json"
        return HTTPResponse(status: 200, headers: headers, body: reply)
    }

    @MainActor
    private func requireAdmin(_ req: HTTPRequest) throws {
        guard let t = req.bearer, Token.equal(t, manager.settings.adminToken) else {
            throw APIError(401, "admin token required")
        }
    }

    /// The admin token opens any session; a session token opens only its own.
    @MainActor
    private func authorize(_ req: HTTPRequest, _ id: String) throws -> Session {
        guard let t = req.bearer else { throw APIError(401, "bearer token required") }
        if Token.equal(t, manager.settings.adminToken) {
            guard let s = manager.session(id) else { throw APIError(404, "no such session") }
            return s
        }
        // Same answer for "wrong token" and "no such session": a token reveals nothing about others.
        guard let s = manager.authorize(token: t, session: id) else { throw APIError(404, "no such session") }
        return s
    }

    @MainActor
    private func describe(_ s: Session, _ req: HTTPRequest) -> [String: Any] {
        let base = "http://\(req.header("host") ?? "127.0.0.1:\(manager.settings.port)")/v1/sessions/\(s.id)"
        let f = ISO8601DateFormatter()
        let net = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s.policy))) ?? [:]
        return ["id": s.id, "state": s.state.rawValue, "boot": s.bootMode, "detail": s.detail,
                "created_at": f.string(from: s.created), "expires_at": f.string(from: s.expires),
                "last_activity": f.string(from: s.lastActivity),
                "idle_timeout_seconds": Int(s.idleTimeout), "network": net,
                "mcp_url": base + "/mcp", "screenshot_url": base + "/screenshot"]
    }

    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
