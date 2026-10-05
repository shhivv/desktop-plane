import Foundation
import Virtualization
import PlaneCore

/// Builds the golden image in three steps:
///
/// 1. `install`   downloads the latest supported IPSW and installs macOS.
/// 2. `provision` boots it with NAT and the guest tools share, for the person to finish Setup
///                Assistant and run install.sh. Ends when the guest shuts down.
/// 3. `finalize`  boots the runtime configuration, waits for the agent, and saves the machine
///                state that every session restores from.
@MainActor
public final class ImageBuilder: NSObject, ObservableObject {
    @Published public private(set) var status = ""
    @Published public private(set) var progress: Double?
    @Published public private(set) var busy = false
    /// The VM being provisioned, for a window to show.
    @Published public private(set) var provisioningVM: VZVirtualMachine?

    public let name: String
    private var observation: NSKeyValueObservation?
    private var provisionDone: CheckedContinuation<Void, Error>?

    public init(name: String) { self.name = name }

    public var image: VMImage? { VMImage.load(named: name) }

    private func set(_ s: String, _ p: Double? = nil) {
        status = s
        progress = p
        Log.info("image \(name): \(s)\(p.map { String(format: " %.0f%%", $0 * 100) } ?? "")")
    }

    // MARK: 1. install

    public func install(diskGB: Int = 80) async throws {
        busy = true
        defer { busy = false; progress = nil }
        try Paths.ensure()
        let ipsw = try await restoreImageFile()
        set("Loading restore image")
        let restore = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let req = restore.mostFeaturefulSupportedConfiguration, req.hardwareModel.isSupported else {
            throw PlaneError("this restore image cannot run on this Mac")
        }

        let dir = VMImage.dir(named: name)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mid = VZMacMachineIdentifier()
        let meta = VMImage.Meta(name: name, stage: .installed, macOSBuild: restore.buildVersion, diskGB: diskGB,
                                macAddress: VZMACAddress.randomLocallyAdministered().string,
                                created: Date(), finalized: nil, cpus: nil, memoryGB: nil)
        var image = VMImage(dir: dir, meta: meta)
        try req.hardwareModel.dataRepresentation.write(to: image.hardwareModelFile)
        try mid.dataRepresentation.write(to: image.machineIDFile)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: image.aux, hardwareModel: req.hardwareModel, options: [])
        // Sparse file: only blocks the guest writes take space.
        FileManager.default.createFile(atPath: image.disk.path, contents: nil)
        let h = try FileHandle(forWritingTo: image.disk)
        try h.truncate(atOffset: UInt64(diskGB) << 30)
        try h.close()

        let settings = HostSettings.load()
        let config = try VMFactory.configuration(image: image, disk: image.disk, aux: image.aux,
                                                 cpus: max(settings.cpusPerVM, req.minimumSupportedCPUCount),
                                                 memoryGB: max(settings.memoryGBPerVM, Int(req.minimumSupportedMemorySize >> 30)),
                                                 purpose: .build(tools: try GuestTools.stage()))
        let vm = VZVirtualMachine(configuration: config)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
        set("Installing macOS \(restore.buildVersion)", 0)
        observation = installer.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in self?.progress = f }
        }
        defer { observation = nil }
        try await installer.install()
        if vm.canStop { try? await vm.stop() }
        try image.save()
        image.meta.stage = .installed
        try image.save()
        set("macOS installed. Next: provision.")
    }

    /// Uses an .ipsw already in the ipsw folder, else downloads the latest supported one.
    func restoreImageFile() async throws -> URL {
        let existing = (try? FileManager.default.contentsOfDirectory(at: Paths.ipsw, includingPropertiesForKeys: nil)) ?? []
        if let f = existing.filter({ $0.pathExtension == "ipsw" }).sorted(by: { $0.path > $1.path }).first {
            return f
        }
        set("Finding the latest macOS")
        let latest = try await VZMacOSRestoreImage.latestSupported
        let dest = Paths.ipsw.appendingPathComponent(latest.url.lastPathComponent)
        set("Downloading macOS \(latest.buildVersion)", 0)
        let delegate = DownloadProgress { [weak self] f in Task { @MainActor in self?.progress = f } }
        let (tmp, _) = try await URLSession.shared.download(from: latest.url, delegate: delegate)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: 2. provision

    /// Boots the image for interactive setup. Returns once the guest shuts itself down.
    public func provision() async throws {
        guard var image else { throw PlaneError("install the image first") }
        busy = true
        defer { busy = false; provisioningVM = nil }
        // Provisioning changes the disk, so any earlier snapshot is void.
        for f in [image.disk, image.aux] { chmod(f.path, 0o600) }
        chmod(image.state.path, 0o600)
        try? FileManager.default.removeItem(at: image.state)
        image.meta.stage = .installed
        try image.save()
        let settings = HostSettings.load()
        let config = try VMFactory.configuration(image: image, disk: image.disk, aux: image.aux,
                                                 cpus: settings.cpusPerVM, memoryGB: settings.memoryGBPerVM,
                                                 purpose: .build(tools: try GuestTools.stage()))
        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = self
        provisioningVM = vm
        try await vm.start()
        set("Provisioning: finish Setup Assistant, then run install.sh in the VM's Terminal, then shut it down")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in provisionDone = c }
        image.meta.stage = .provisioned
        try image.save()
        set("Provisioned. Next: finalize.")
    }

    /// Stops the provisioning VM without waiting for the guest.
    public func abortProvisioning() async {
        if let vm = provisioningVM, vm.canStop { try? await vm.stop() }
        provisionDone?.resume(throwing: PlaneError("provisioning cancelled"))
        provisionDone = nil
    }

    // MARK: 3. finalize

    public func finalize() async throws {
        guard var image else { throw PlaneError("install the image first") }
        guard image.meta.stage != .installed else { throw PlaneError("provision the image first") }
        busy = true
        defer { busy = false }
        let settings = HostSettings.load()
        try? FileManager.default.removeItem(at: image.state)
        for f in [image.disk, image.aux] { chmod(f.path, 0o600) }

        let lan = try VirtualLAN(session: "finalize")
        defer { lan.close() }
        let config = try VMFactory.configuration(image: image, disk: image.disk, aux: image.aux,
                                                 cpus: settings.cpusPerVM, memoryGB: settings.memoryGBPerVM,
                                                 purpose: .runtime(nic: lan.guestEnd))
        try config.validateSaveRestoreSupport()
        let vm = VZVirtualMachine(configuration: config)
        set("Booting the runtime configuration")
        try await vm.start()

        set("Waiting for the guest agent")
        let link = try GuestLink(vm: vm)
        var reply: ControlReply?
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            if let r = try? await link.control(.init(kind: .ping), timeout: 3) { reply = r; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let reply else {
            if vm.canStop { try? await vm.stop() }
            throw PlaneError("the guest agent never answered; check install.sh ran to the end and auto-login is on")
        }
        guard reply.accessibility else {
            if vm.canStop { try? await vm.stop() }
            throw PlaneError("the guest agent has no Accessibility permission; provision again")
        }
        if !reply.screenRecording { Log.warn("guest agent has no Screen Recording permission; screenshots will fail") }

        // Let login items and background work settle, so restored sessions start quiet.
        set("Letting the desktop settle")
        try await Task.sleep(nanoseconds: 30_000_000_000)

        set("Saving machine state")
        try await vm.pause()
        try await vm.saveMachineStateTo(url: image.state)
        // Never resume: the disk must stay exactly as it was when the state was saved.
        try await vm.stop()

        image.meta.stage = .ready
        image.meta.finalized = Date()
        image.meta.cpus = settings.cpusPerVM
        image.meta.memoryGB = settings.memoryGBPerVM
        try image.save()
        // The golden files are read-only from here on; sessions only ever get clones.
        for f in [image.disk, image.aux, image.state] { chmod(f.path, 0o400) }
        set("Ready. arc-cua \(reply.arcCUA ?? "?"), agent \(reply.agentVersion).")
    }
}

extension ImageBuilder: VZVirtualMachineDelegate {
    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            self.provisionDone?.resume()
            self.provisionDone = nil
        }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            self.provisionDone?.resume(throwing: error)
            self.provisionDone = nil
        }
    }
}

final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(_ f: @escaping @Sendable (Double) -> Void) { onProgress = f }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
