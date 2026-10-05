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

    public init() throws {
        try Paths.ensure()
        lockFD = open(Paths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw PlaneError("another Desktop Plane host is already running for this user")
        }
        settings = HostSettings.load()
        manager = SessionManager(settings: settings)
    }

    public var baseURL: String { "http://\(settings.bindAddress):\(settings.port)" }

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
    }

    public func shutdown() async {
        server?.stop()
        await manager.destroyAll(reason: "host shutting down")
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}
