// planed: headless Desktop Plane host, plus image building and a self-test.

import AppKit
import Foundation
import PlaneHost

let usage = """
usage: planed <command>

  serve                    run the host and API (default)
  image install [--disk-gb N]
                           download macOS and install it into the golden image
  image provision          open the image in a window to finish setup inside the guest
  image finalize [--show]  boot it locked down and save the snapshot sessions restore from
  image update-agent       write the current guest agent into the image (offline)
  image status             show the image's stage
  config                   show settings
  config set KEY=VALUE…    change settings (a running host picks them up within 2s)
                             cpus=4 memory=8 disk=80 slots=2 port=7480 bind=127.0.0.1
                             ttl=3600 max-ttl=86400 idle=900 mcp-command="arc-cua mcp"
  token                    print the admin API token
  selftest                 start the host, then check isolation end to end (needs a ready image)
"""

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
let args = Array(CommandLine.arguments.dropFirst())
let settings = HostSettings.load()

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

/// Runs async work on the main actor (Virtualization wants the main queue) and exits.
func runMain(_ work: @escaping @MainActor () async throws -> Int32) -> Never {
    Task { @MainActor in
        do { exit(try await work()) } catch { fail(error.localizedDescription) }
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
    exit(0)
}

func onSignals(_ handler: @escaping @MainActor () async -> Void) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { Task { @MainActor in await handler(); exit(0) } }
        src.resume()
        retained.append(src)
    }
}
nonisolated(unsafe) var retained: [Any] = []

switch args.first ?? "serve" {
case "serve":
    runMain {
        let service = try PlaneService()
        try service.start()
        print("Desktop Plane host on \(service.baseURL)")
        print("Admin token: planed token")
        onSignals { await service.shutdown() }
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }

case "image":
    let builder = { @MainActor in ImageBuilder(name: settings.image) }
    switch args.dropFirst().first ?? "status" {
    case "install":
        var diskGB: Int?
        if let i = args.firstIndex(of: "--disk-gb"), i + 1 < args.count, let n = Int(args[i + 1]) { diskGB = n }
        runMain {
            let b = builder()
            var last = -1
            let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let pct = Int((b.progress ?? 0) * 100)
                    if pct != last { last = pct; print("  \(b.status) \(pct)%") }
                }
            }
            try await b.install(diskGB: diskGB)
            timer.invalidate()
            print("Installed. Next: planed image provision")
            return 0
        }
    case "provision":
        runMain {
            let b = builder()
            NSApplication.shared.setActivationPolicy(.regular)
            var window: VMWindow?
            let watcher = b.$provisioningVM.sink { vm in
                guard let vm else { window?.window.close(); return }
                window = VMWindow(vm: vm, title: "Desktop Plane: provisioning \(b.name)", interactive: true)
                window?.onClose = { Task { await b.abortProvisioning() } }
                window?.show()
            }
            print("""
            In the VM window:
              1. Finish Setup Assistant (local account, skip Apple ID).
              2. In Terminal: bash "/Volumes/My Shared Files/install.sh"
              3. Shut the VM down from the Apple menu.
            """)
            try await b.provision()
            _ = watcher
            print("Provisioned. Next: planed image finalize")
            return 0
        }
    case "finalize":
        runMain {
            let b = builder()
            var window: VMWindow?
            let show = args.contains("--show")
            let watcher = b.$provisioningVM.sink { vm in
                guard show else { return }
                guard let vm else { window?.window.close(); return }
                NSApplication.shared.setActivationPolicy(.regular)
                window = VMWindow(vm: vm, title: "Desktop Plane: snapshot boot (watch only)", interactive: false)
                window?.show()
            }
            defer { _ = watcher }
            try await b.finalize()
            print(b.status)
            return 0
        }
    case "update-agent":
        runMain {
            guard let img = VMImage.load(named: settings.image) else { throw PlaneError("no image yet") }
            print(try AgentUpdater.update(image: img))
            print("Next: planed image finalize")
            return 0
        }
    case "status":
        if let img = VMImage.load(named: settings.image) {
            print("\(img.meta.name): \(img.meta.stage.rawValue), macOS \(img.meta.macOSBuild), \(img.dir.path)")
        } else {
            print("no image yet: planed image install")
        }
    default:
        fail(usage)
    }

case "token":
    print(settings.adminToken)

case "config":
    var s = settings
    let pairs = args.dropFirst().first == "set" ? Array(args.dropFirst(2)) : []
    if args.dropFirst().first == "set" && pairs.isEmpty { fail("usage: planed config set KEY=VALUE…") }
    for pair in pairs {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard kv.count == 2 else { fail("expected KEY=VALUE, got \(pair)") }
        let (k, v) = (kv[0], kv[1])
        func int() -> Int {
            guard let n = Int(v) else { fail("\(k) must be a number") }
            return n
        }
        switch k {
        case "cpus": s.cpusPerVM = int()
        case "memory", "memory-gb": s.memoryGBPerVM = int()
        case "disk", "disk-gb": s.diskGB = int()
        case "slots", "max-vms": s.maxVMs = int()
        case "port":
            guard let p = UInt16(exactly: int()) else { fail("bad port") }
            s.port = p
        case "bind": s.bindAddress = v
        case "ttl": s.defaultTTLSeconds = int()
        case "max-ttl": s.maxTTLSeconds = int()
        case "idle": s.defaultIdleTimeoutSeconds = int()
        case "mcp-command": s.guestMCPCommand = v
        default: fail("unknown setting \(k)")
        }
    }
    if !pairs.isEmpty {
        if let e = s.errors().first { fail(e) }
        do { try s.save() } catch { fail(error.localizedDescription) }
    }
    let image = VMImage.load(named: s.image)
    print("""
    VM size        \(s.cpusPerVM) CPUs, \(s.memoryGBPerVM) GB memory   (this Mac: \(HostSettings.hostCPUs) cores, \(HostSettings.hostMemoryGB) GB)
    image disk     \(s.diskGB) GB (used when the image is installed)
    running VMs    \(s.maxVMs) at a time
    API            http://\(s.bindAddress):\(s.port)
    sessions       ttl \(s.defaultTTLSeconds)s (max \(s.maxTTLSeconds)s), idle \(s.defaultIdleTimeoutSeconds)s
    MCP command    \(s.guestMCPCommand.isEmpty ? "arc-cua mcp" : s.guestMCPCommand)
    """)
    for w in s.warnings() { print("warning: \(w)") }
    if s.needsResnapshot(image) {
        print("note: the image snapshot uses \(image?.meta.cpus ?? 0) CPUs / \(image?.meta.memoryGB ?? 0) GB; run `planed image finalize` to apply the new size")
    }
    if let image, image.meta.diskGB != s.diskGB {
        print("note: the image disk is \(image.meta.diskGB) GB; a new disk size applies when the image is reinstalled")
    }

case "selftest":
    runMain {
        let service = try PlaneService()
        try service.start()
        let ok = await SelfTest.run(service: service)
        await service.shutdown()
        return ok ? 0 : 1
    }

case "-h", "--help", "help":
    print(usage)

default:
    fail(usage)
}
