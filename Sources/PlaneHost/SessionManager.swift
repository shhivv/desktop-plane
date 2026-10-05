import Foundation
import Virtualization
import PlaneCore

/// Owns the VM slots. A slot is never reused: every session boots a fresh clone, and
/// destroying a session deletes its clone.
@MainActor
public final class SessionManager: ObservableObject {
    @Published public private(set) var sessions: [Session] = []
    @Published public private(set) var volumes: [Volume] = []
    public private(set) var settings: HostSettings
    private var reaper: Timer?

    public init(settings: HostSettings) {
        self.settings = settings
        // Anything left from a crash belongs to sessions that no longer exist.
        if let leftovers = try? FileManager.default.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil) {
            for d in leftovers { try? FileManager.default.removeItem(at: d) }
        }
        volumes = Volume.loadAll()
        reaper = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reap() }
        }
    }

    public func update(settings: HostSettings) { self.settings = settings }

    var live: [Session] { sessions.filter { $0.state != .stopped && $0.state != .failed } }

    public struct CreateRequest: Codable, Sendable {
        public var ttl_seconds: Int?
        public var idle_timeout_seconds: Int?
        public var network: EgressPolicy?
        /// Id of a data volume to plug in. One session per volume at a time.
        public var volume: String?
        public init() {}
    }

    public func create(_ req: CreateRequest) async throws -> Session {
        guard let image = VMImage.load(named: settings.image), image.meta.stage == .ready else {
            throw APIError(409, "image '\(settings.image)' is not ready; build it in the app or with `planed image`")
        }
        guard live.count < settings.maxVMs else {
            throw APIError(429, "all \(settings.maxVMs) VM slots are busy")
        }
        let ttl = min(max(req.ttl_seconds ?? settings.defaultTTLSeconds, 60), settings.maxTTLSeconds)
        let idle = max(req.idle_timeout_seconds ?? settings.defaultIdleTimeoutSeconds, 60)
        // A slot whose machine identity is not running already: two restores of one identity
        // cannot run at once. If every slot is taken (settings allow more VMs than slots),
        // reuse slot 0; that session cold boots instead of restoring.
        let used = Set(live.compactMap { $0.slot })
        let slot = image.slotImages().first { !used.contains($0.dir) } ?? image
        var volume: Volume?
        if let vid = req.volume {
            guard #available(macOS 15.0, *) else { throw APIError(501, "data volumes need macOS 15 or later on the host") }
            guard let v = volumes.first(where: { $0.id == vid }) else { throw APIError(404, "no such volume") }
            if let other = attachedSession(v.id) { throw APIError(409, "volume is in use by \(other)") }
            volume = v
        }
        let s = Session(ttl: TimeInterval(ttl), idleTimeout: TimeInterval(idle), policy: req.network ?? EgressPolicy())
        s.slot = slot.dir
        // Reserved before any await, so a second request for the same volume sees it taken.
        s.volume = volume
        s.onChange = { [weak self] in self?.objectWillChange.send() }
        s.onGuestStopped = { [weak self] s in Task { await self?.destroy(s.id, reason: "guest stopped") } }
        sessions.append(s)
        Log.info("creating (ttl \(ttl)s, idle \(idle)s, egress \(s.policy.enabled ? "on" : "off"))", session: s.id)
        do {
            try await s.boot(image: slot, settings: settings)
            if var v = s.volume, let i = volumes.firstIndex(where: { $0.id == v.id }) {
                v.meta.lastAttached = Date()
                try? v.save()
                volumes[i] = v
            }
        } catch {
            Log.error("boot failed: \(error.localizedDescription)", session: s.id)
            await s.teardown()
            s.state = .failed
            sessions.removeAll { $0 === s }
            throw error
        }
        return s
    }

    // MARK: volumes

    public func attachedSession(_ volumeID: String) -> String? {
        live.first { $0.volume?.id == volumeID }?.id
    }

    public func createVolume(name: String?, sizeGB: Int) throws -> Volume {
        guard (1...2000).contains(sizeGB) else { throw APIError(400, "size_gb must be 1–2000") }
        let v = try Volume.create(name: name, sizeGB: sizeGB)
        volumes.append(v)
        Log.info("volume \(v.id) created (\(sizeGB) GB)")
        return v
    }

    public func deleteVolume(_ id: String) throws {
        guard let v = volumes.first(where: { $0.id == id }) else { throw APIError(404, "no such volume") }
        if let s = attachedSession(id) { throw APIError(409, "volume is in use by \(s); end that session first") }
        try v.remove()
        volumes.removeAll { $0.id == id }
        Log.info("volume \(id) deleted")
    }

    public func session(_ id: String) -> Session? { sessions.first { $0.id == id && $0.state != .stopped } }

    /// Session tokens open their own session only.
    func authorize(token: String, session id: String) -> Session? {
        guard let s = session(id) else { return nil }
        return Token.equal(s.token, token) ? s : nil
    }

    public func destroy(_ id: String, reason: String) async {
        guard let s = sessions.first(where: { $0.id == id }), s.state != .stopping, s.state != .stopped else { return }
        Log.info("destroying: \(reason)", session: id)
        await s.teardown()
        sessions.removeAll { $0 === s }
    }

    public func destroyAll(reason: String) async {
        for s in sessions { await destroy(s.id, reason: reason) }
    }

    private func reap() async {
        let now = Date()
        for s in sessions where s.state == .ready {
            if now >= s.expires {
                await destroy(s.id, reason: "TTL expired")
            } else if now.timeIntervalSince(s.lastActivity) >= s.idleTimeout {
                await destroy(s.id, reason: "idle for \(Int(s.idleTimeout))s")
            }
        }
    }

    // MARK: per-session operations

    func openMCP(_ s: Session) async throws -> MCPBridge {
        let fd = try await s.link.connect(port: VsockPort.guestMCP)
        // The first line on the MCP port picks the command the agent runs.
        let header = settings.guestMCPCommand.isEmpty ? "#!default\n" : "#!cmd \(settings.guestMCPCommand)\n"
        try FD.writeAll(fd, Data(header.utf8))
        let b = MCPBridge(fd: fd, session: s.id)
        b.onClose = { [weak s, id = b.id] in Task { @MainActor in s?.mcp.removeValue(forKey: id) } }
        s.mcp[b.id] = b
        return b
    }
}

public struct APIError: Error, LocalizedError {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    public var errorDescription: String? { message }
}
