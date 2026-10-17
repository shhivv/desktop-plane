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
                             public-url=https://mini.tailnet.ts.net
  token                    print the admin API token
  mcp [claude|codex]       show how to add Desktop Plane to an agent (one MCP server, added once)
  mcp install claude|codex add it to that agent's config now
  session new [--open APP_OR_URL]… [--ttl SECONDS] [--allow HOST]… [--no-network] [--volume ID]
                           start a desktop on the running host and print its MCP details
  session list             list desktops
  session end ID           end a desktop
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
        case "public-url": s.publicURL = v
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
    API            http://\(s.bindAddress):\(s.port)\(s.publicURL.isEmpty ? "" : "   (clients use \(s.publicURL))")
    MCP            \(s.mcpURL)
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

case "mcp":
    switch args.dropFirst().first {
    case "install":
        guard let name = args.dropFirst(2).first, let agent = AgentSetup.Agent(rawValue: name) else {
            fail("usage: planed mcp install claude|codex")
        }
        runMain {
            let out = try await AgentSetup.install(agent, settings)
            if !out.isEmpty { print(out) }
            print("Added \(AgentSetup.serverName) to \(agent.title). Start a new \(agent.rawValue) session to use it.")
            return 0
        }
    case let name?:
        guard let agent = AgentSetup.Agent(rawValue: name) else { fail("usage: planed mcp [claude|codex]") }
        print(AgentSetup.command(agent, settings))
    case nil:
        print("""
        MCP endpoint  \(settings.mcpURL)
        Auth          Authorization: Bearer <admin token>   (planed token)

        Claude Code:
          \(AgentSetup.command(.claude, settings))

        Codex:
          \(AgentSetup.command(.codex, settings).replacingOccurrences(of: "\n", with: "\n  "))

        Or run `planed mcp install claude` / `planed mcp install codex` to add it now.
        """)
    }

case "session":
    func value(_ flag: String) -> [String] {
        var out: [String] = []
        var i = 2
        while i < args.count {
            if args[i] == flag, i + 1 < args.count { out.append(args[i + 1]); i += 2 } else { i += 1 }
        }
        return out
    }
    runMain {
        let api = HostClient(settings: settings)
        switch args.dropFirst().first ?? "list" {
        case "new":
            var body: [String: Any] = [:]
            let open = value("--open")
            if !open.isEmpty { body["open"] = open }
            if let t = value("--ttl").first { guard let n = Int(t) else { throw PlaneError("--ttl takes seconds") }; body["ttl_seconds"] = n }
            if let v = value("--volume").first { body["volume"] = v }
            var net: [String: Any] = [:]
            let allow = value("--allow")
            if !allow.isEmpty { net["allow"] = allow }
            if args.contains("--no-network") { net["enabled"] = false }
            if !net.isEmpty { body["network"] = net }
            print("Starting a desktop…")
            let s = try await api.call("POST", "/v1/sessions", body: body)
            let id = s["id"] as? String ?? "?", url = s["mcp_url"] as? String ?? "", tok = s["token"] as? String ?? ""
            print("""
            \(id) ready (\(s["boot"] as? String ?? "?") boot), expires \(s["expires_at"] as? String ?? "?")
            MCP URL  \(url)
            Token    \(tok)

            Just this desktop, in Claude Code:
              claude mcp add --transport http \(id) \(url) --header "Authorization: Bearer \(tok)"
            End it:  planed session end \(id)
            """)
        case "list":
            let r = try await api.call("GET", "/v1/sessions")
            let list = r["sessions"] as? [[String: Any]] ?? []
            if list.isEmpty { print("no desktops running") }
            for s in list {
                print("\(s["id"] as? String ?? "?")  \(s["state"] as? String ?? "?")  expires \(s["expires_at"] as? String ?? "?")  \(s["detail"] as? String ?? "")")
            }
        case "end":
            guard let id = args.dropFirst(2).first else { throw PlaneError("usage: planed session end ID") }
            _ = try await api.call("DELETE", "/v1/sessions/\(id)")
            print("ended \(id)")
        default:
            throw PlaneError("usage: planed session new|list|end")
        }
        return 0
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

/// Talks to the running host (the app or `planed serve`) over its HTTP API.
struct HostClient {
    let settings: HostSettings

    func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.port)" + path)!)
        r.httpMethod = method
        r.timeoutInterval = 600
        r.setValue("Bearer \(settings.adminToken)", forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data, res: URLResponse
        do { (data, res) = try await URLSession.shared.data(for: r) } catch {
            throw PlaneError("no Desktop Plane host on port \(settings.port); open the app or run `planed serve`")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw PlaneError(obj["error"] as? String ?? "HTTP \(status)") }
        return obj
    }
}
