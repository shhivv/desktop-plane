import Foundation
import Virtualization
import PlaneCore

/// One tenant's desktop: a throwaway VM cloned from the golden image, its private LAN, its
/// egress proxy, and its MCP connections. Nothing in it outlives `destroy`.
@MainActor
public final class Session: NSObject, Identifiable {
    public enum State: String, Sendable { case starting, ready, stopping, stopped, failed }

    public let id: String
    let token: String
    public let created = Date()
    public let expires: Date
    public let idleTimeout: TimeInterval
    public let policy: EgressPolicy
    public internal(set) var lastActivity = Date()
    public internal(set) var state: State = .starting { didSet { onChange?() } }
    public internal(set) var bootMode = ""
    public internal(set) var detail = ""
    public internal(set) var vm: VZVirtualMachine?
    let dir: URL
    /// The image slot this session was cloned from. Its machine identity is in use while it runs.
    var slot: URL?
    /// Data volume plugged in after boot, if the session asked for one.
    public internal(set) var volume: Volume?
    private var usbDevice: AnyObject?
    var lan: VirtualLAN?
    var mcp: [String: MCPBridge] = [:]
    var proxyListener: VZVirtioSocketListener?
    private var proxyDelegate: ProxyListenerDelegate?
    var onChange: (() -> Void)?
    var onGuestStopped: ((Session) -> Void)?

    init(ttl: TimeInterval, idleTimeout: TimeInterval, policy: EgressPolicy) {
        id = "ses_" + Token.random(bytes: 8)
        token = "dpt_" + Token.random()
        expires = Date().addingTimeInterval(ttl)
        self.idleTimeout = idleTimeout
        self.policy = policy
        dir = Paths.sessions.appendingPathComponent(id)
        super.init()
    }

    func touch() { lastActivity = Date() }

    var link: GuestLink {
        get throws {
            guard let vm, state == .ready else { throw PlaneError("session is \(state.rawValue)") }
            return try GuestLink(vm: vm)
        }
    }

    // MARK: lifecycle

    func boot(image: VMImage, settings: HostSettings) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        let disk = dir.appendingPathComponent("disk.img")
        let aux = dir.appendingPathComponent("aux.img")
        // Copy-on-write clones: instant, and they share blocks with the image until written.
        try Self.clone(image.disk, to: disk)
        try Self.clone(image.aux, to: aux)
        // Clones keep the golden image's read-only mode; the VM needs to write its own copy.
        for f in [disk, aux] { chmod(f.path, 0o600) }

        let lan = try VirtualLAN(session: id)
        self.lan = lan
        let config = try VMFactory.configuration(image: image, disk: disk, aux: aux,
                                                 cpus: image.meta.cpus ?? settings.cpusPerVM,
                                                 memoryGB: image.meta.memoryGB ?? settings.memoryGBPerVM,
                                                 purpose: .runtime(nic: lan.guestEnd))
        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = self
        self.vm = vm

        // The VM's only way out: this listener on its own vsock device.
        let delegate = ProxyListenerDelegate(policy: policy, session: id) { [weak self] in
            Task { @MainActor in self?.touch() }
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        try GuestLink(vm: vm).device.setSocketListener(listener, forPort: VsockPort.hostProxy)
        proxyListener = listener
        proxyDelegate = delegate

        let t0 = Date()
        var restored = false
        if FileManager.default.fileExists(atPath: image.state.path) {
            do {
                try await vm.restoreMachineStateFrom(url: image.state)
                try await vm.resume()
                restored = true
            } catch {
                Log.warn("restore failed, cold booting: \(error.localizedDescription)", session: id)
            }
        }
        if !restored { try await vm.start() }
        bootMode = restored ? "restored" : "cold"

        let reply = try await waitForAgent(timeout: restored ? 90 : 300)
        guard reply.accessibility else {
            throw PlaneError("guest agent lacks Accessibility permission; re-provision the image")
        }
        let hello = try await GuestLink(vm: vm).control(.init(kind: .hello, sessionID: id, hostTime: Date().timeIntervalSince1970))
        if !hello.ok { Log.warn("guest hello: \(hello.error ?? "failed")", session: id) }
        if let volume {
            guard #available(macOS 15.0, *) else { throw PlaneError("data volumes need macOS 15 or later on the host") }
            try await attach(volume)
        }
        detail = "arc-cua \(reply.arcCUA ?? "?") · screen recording \(reply.screenRecording ? "on" : "off")"
            + (volume.map { " · volume \($0.meta.name)" } ?? "")
        Log.info("ready in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s (\(bootMode))", session: id)
        state = .ready
    }

    /// Plugs the volume in as a USB drive and waits for the guest to mount it.
    @available(macOS 15.0, *)
    private func attach(_ v: Volume) async throws {
        guard let vm, let usb = vm.usbControllers.first else {
            throw PlaneError("this image has no USB controller; redo the snapshot step to use volumes")
        }
        let disk = try VZDiskImageStorageDeviceAttachment(url: v.disk, readOnly: false,
                                                          cachingMode: .automatic, synchronizationMode: .full)
        let device = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: disk))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            usb.attach(device: device) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        usbDevice = device
        let link = try GuestLink(vm: vm)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let r = try? await link.control(.init(kind: .ping), timeout: 3), r.volumes?.contains(Volume.label) == true {
                Log.info("volume \(v.id) mounted at \(Volume.guestMountPoint)", session: id)
                return
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw PlaneError("the guest did not mount the volume within 30s")
    }

    /// Ejects in the guest (flushing its writes), then unplugs.
    private func detachVolume(_ vm: VZVirtualMachine) async {
        guard #available(macOS 15.0, *), let device = usbDevice as? VZUSBMassStorageDevice,
              let usb = vm.usbControllers.first else { return }
        if vm.state == .running {
            do {
                let r = try await GuestLink(vm: vm).control(.init(kind: .eject, volume: Volume.label), timeout: 20)
                if let e = r.error { Log.warn("volume eject: \(e)", session: id) }
            } catch {
                Log.warn("volume eject failed: \(error.localizedDescription)", session: id)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            usb.detach(device: device) { _ in c.resume() }
        }
        usbDevice = nil
    }

    private func waitForAgent(timeout: TimeInterval) async throws -> ControlReply {
        guard let vm else { throw PlaneError("no VM") }
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = PlaneError("guest agent did not answer")
        while Date() < deadline {
            if vm.state != .running { throw PlaneError("VM stopped while booting") }
            do {
                return try await GuestLink(vm: vm).control(.init(kind: .ping), timeout: 3)
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw PlaneError("guest agent not reachable after \(Int(timeout))s: \(lastError.localizedDescription)")
    }

    func teardown() async {
        guard state != .stopped else { return }
        state = .stopping
        for b in mcp.values { b.close() }
        mcp.removeAll()
        if let vm {
            if let d = vm.socketDevices.first as? VZVirtioSocketDevice {
                d.removeSocketListener(forPort: VsockPort.hostProxy)
            }
            await detachVolume(vm)
            if vm.canStop { try? await vm.stop() }
        }
        vm = nil
        proxyListener = nil
        proxyDelegate = nil
        lan?.close()
        lan = nil
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            Log.error("could not delete session files: \(error.localizedDescription)", session: id)
        }
        state = .stopped
    }

    static func clone(_ src: URL, to dst: URL) throws {
        if Darwin.clonefile(src.path, dst.path, 0) == 0 { return }
        let e = errno
        // Not on APFS (or crossing volumes): fall back to a full copy.
        Log.warn("clonefile failed (\(e)), copying \(src.lastPathComponent)")
        try FileManager.default.copyItem(at: src, to: dst)
    }
}

extension Session: VZVirtualMachineDelegate {
    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            Log.info("guest shut down", session: self.id)
            self.onGuestStopped?(self)
        }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            Log.error("VM stopped: \(error.localizedDescription)", session: self.id)
            self.onGuestStopped?(self)
        }
    }
}

/// Accepts the guest's egress connections on the host proxy port.
final class ProxyListenerDelegate: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    let policy: EgressPolicy
    let session: String
    let onActivity: @Sendable () -> Void

    init(policy: EgressPolicy, session: String, onActivity: @escaping @Sendable () -> Void) {
        self.policy = policy
        self.session = session
        self.onActivity = onActivity
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else { return false }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let policy = policy, session = session
        onActivity()
        Thread.detachNewThread {
            EgressProxy.serve(fd: fd, policy: policy, session: session)
            connection.close()
        }
        return true
    }
}
