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
  image finalize           boot it headless and save the snapshot sessions restore from
  image status             show the image's stage
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
        var diskGB = 80
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
            try await b.finalize()
            print(b.status)
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
