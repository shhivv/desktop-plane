import Foundation

/// The host process: settings, VM slots and the API server. The menu bar app and the headless
/// `planed` daemon both run exactly this; a lock file keeps it to one per user.
@MainActor
public final class PlaneService: ObservableObject {
    public let manager: SessionManager
    public private(set) var settings: HostSettings
    private var server: HTTPServer?
    private var lockFD: Int32 = -1
    private var activity: NSObjectProtocol?
    private var settingsWatch: Timer?
    private var settingsStamp: Date?

    public init() throws {
        try Paths.ensure()
        lockFD = open(Paths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw PlaneError("another Desktop Plane host is already running for this user")
        }
        settings = HostSettings.load()
        manager = SessionManager(settings: settings)
    }

    /// Where this Mac reaches its own API. 0.0.0.0 is a bind address, not one to connect to.
    public var baseURL: String {
        let host = settings.bindAddress == "0.0.0.0" ? "127.0.0.1" : settings.bindAddress
        return "http://\(host):\(settings.port)"
    }

    public func start() throws {
        let api = API(manager: manager)
        let server = HTTPServer { req in await api.handle(req) }
        try server.start(address: settings.bindAddress, port: settings.port)
        self.server = server
        // A spare Mac serving desktops must not doze off.
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                         reason: "Serving desktop VMs")
        if settings.bindAddress != "127.0.0.1" && settings.bindAddress != "::1" {
            Log.warn("API is listening on \(settings.bindAddress): anyone who can reach it and has a token can use it")
        }
        Log.info("listening on \(baseURL)")
        // Pick up edits made by `planed config` or by hand while running.
        settingsStamp = Self.settingsModified()
        settingsWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let m = Self.settingsModified(), m != self.settingsStamp else { return }
                self.settingsStamp = m
                Log.info("settings file changed; reloading")
                try? self.apply(HostSettings.load(), save: false)
            }
        }
    }

    /// Validates, saves and applies settings. Changing the address or port restarts the API
    /// listener; CPU and memory apply once the image is re-snapshotted.
    public func apply(_ new: HostSettings, save: Bool = true) throws {
        if let e = new.errors().first { throw PlaneError(e) }
        let old = settings
        if save {
            try new.save()
            settingsStamp = Self.settingsModified()
        }
        settings = new
        manager.update(settings: new)
        // Served on the tailnet: keep `tailscale serve` pointed at the API's port.
        if Reachability.mode(old) == .tailscale, Reachability.mode(new) == .tailscale, old.port != new.port {
            Task { [weak self] in
                await Reachability.stopServing(old)
                if let n = try? await Reachability.useTailscale(new) { try? self?.apply(n) }
            }
        }
        objectWillChange.send()
        if old.bindAddress != new.bindAddress || old.port != new.port, server != nil {
            server?.stop()
            let api = API(manager: manager)
            let s = HTTPServer { req in await api.handle(req) }
            try s.start(address: new.bindAddress, port: new.port)
            server = s
            Log.info("listening on \(baseURL)")
        }
    }

    static func settingsModified() -> Date? {
        (try? Paths.settings.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    public func shutdown() async {
        settingsWatch?.invalidate()
        server?.stop()
        await manager.destroyAll(reason: "host shutting down")
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}
