// Desktop Plane guest agent. Runs inside the macOS guest in the logged-in session, which is
// where Accessibility and Screen Recording are granted. Children it spawns (arc-cua) inherit
// those grants.
//
// It runs as a child of DesktopPlaneAgent.app (AgentLauncher), which holds the permissions,
// so this binary can be updated without granting them again.
//
// vsock ports (guest side), see PlaneCore.VsockPort:
//   52000 control     ping / hello (clock sync)
//   52001 mcp         one `arc-cua mcp` process per connection, stdio = the socket
//   52002 screenshot  one PNG per connection
// TCP 127.0.0.1:3128  forwards to the host egress proxy at vsock 2:52100

import ApplicationServices
import CoreGraphics
import Foundation
import PlaneCore

let version = "0.1.0"
let home = FileManager.default.homeDirectoryForCurrentUser
let statusFile = home.appendingPathComponent("Library/Application Support/DesktopPlaneAgent/status.json")

func log(_ s: String) {
    FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".utf8))
}

// MARK: vsock

let AF_VSOCK: Int32 = 40

func vsockAddress(cid: UInt32, port: UInt32) -> sockaddr_vm {
    var a = sockaddr_vm()
    a.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
    a.svm_family = sa_family_t(AF_VSOCK)
    a.svm_port = port
    a.svm_cid = cid
    return a
}

func listenVsock(port: UInt32, handler: @escaping @Sendable (Int32) -> Void) {
    Thread.detachNewThread {
        while true {
            let s = socket(AF_VSOCK, SOCK_STREAM, 0)
            var addr = vsockAddress(cid: UInt32(bitPattern: -1), port: port)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_vm>.size)) == 0
                }
            } && listen(s, 16) == 0
            guard ok else {
                log("vsock listen \(port) failed: \(String(cString: strerror(errno))); retrying")
                close(s)
                sleep(2)
                continue
            }
            log("listening on vsock port \(port)")
            while true {
                let c = accept(s, nil, nil)
                if c < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    log("vsock accept \(port): \(String(cString: strerror(errno)))")
                    break
                }
                var on: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { handler(c) }
            }
            close(s)
            sleep(1)
        }
    }
}

func connectHostVsock(port: UInt32) -> Int32? {
    let s = socket(AF_VSOCK, SOCK_STREAM, 0)
    guard s >= 0 else { return nil }
    var addr = vsockAddress(cid: 2, port: port) // VMADDR_CID_HOST
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_vm>.size)) }
    }
    if r != 0 { close(s); return nil }
    var on: Int32 = 1
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return s
}

// MARK: status

struct Status: Codable {
    var accessibility: Bool
    var screenRecording: Bool
    var arcCUA: String?
    var agentVersion: String
}

func arcCUAVersion() -> String? {
    let tools = home.appendingPathComponent(".local/share/uv/tools/arc-cua")
    guard let libs = try? FileManager.default.contentsOfDirectory(atPath: tools.appendingPathComponent("lib").path) else {
        return FileManager.default.isExecutableFile(atPath: home.appendingPathComponent(".local/bin/arc-cua").path) ? "installed" : nil
    }
    for py in libs {
        let sp = tools.appendingPathComponent("lib/\(py)/site-packages")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: sp.path)) ?? []
        if let d = items.first(where: { $0.hasPrefix("arc_cua-") && $0.hasSuffix(".dist-info") }) {
            return String(d.dropFirst("arc_cua-".count).dropLast(".dist-info".count))
        }
    }
    return "installed"
}

func currentStatus() -> Status {
    Status(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess(),
           arcCUA: arcCUAVersion(), agentVersion: version)
}

func writeStatus() {
    let s = currentStatus()
    try? FileManager.default.createDirectory(at: statusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(s).write(to: statusFile, options: .atomic)
}

// MARK: handlers

func handleControl(_ fd: Int32) {
    defer { close(fd) }
    guard let data = try? FD.readFrame(fd, limit: 1 << 20),
          let req = try? JSONDecoder().decode(ControlRequest.self, from: data) else { return }
    var error: String?
    if req.kind == .hello, let t = req.hostTime {
        error = setClock(t)
        if let id = req.sessionID { log("session \(id) attached") }
    }
    if req.kind == .eject, let name = req.volume {
        error = eject(name)
    }
    let s = currentStatus()
    let reply = ControlReply(ok: error == nil, agentVersion: version, accessibility: s.accessibility,
                             screenRecording: s.screenRecording, arcCUA: s.arcCUA, error: error,
                             volumes: mountedVolumes())
    try? FD.writeFrame(fd, JSONEncoder().encode(reply))
}

/// Restored VMs wake with the snapshot's clock; TLS needs the real time.
func setClock(_ t: Double) -> String? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "MMddHHmmyyyy.ss"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = ["-n", "/bin/date", "-u", f.string(from: Date(timeIntervalSince1970: t))]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "clock: \(error)" }
    p.waitUntilExit()
    return p.terminationStatus == 0 ? nil : "clock: sudo date failed (\(p.terminationStatus))"
}

func mountedVolumes() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
    return names.filter { name in
        // The boot volume shows up as a symlink to /.
        let path = "/Volumes/" + name
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil
    }.sorted()
}

/// Flushes and ejects a volume so the host can unplug it without damage.
func eject(_ name: String) -> String? {
    guard !name.contains("/"), mountedVolumes().contains(name) else { return nil } // already gone
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    p.arguments = ["eject", "/Volumes/" + name]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "eject: \(error)" }
    p.waitUntilExit()
    if p.terminationStatus == 0 { return nil }
    // Something holds files open (an app writing to it). Force it: the session is ending.
    let f = Process()
    f.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    f.arguments = ["unmount", "force", "/Volumes/" + name]
    f.standardOutput = FileHandle.nullDevice
    f.standardError = FileHandle.nullDevice
    try? f.run()
    f.waitUntilExit()
    log("volume \(name) was busy; force-unmounted")
    return f.terminationStatus == 0 ? nil : "could not unmount \(name)"
}

/// Reads the one-line header the host sends before MCP traffic, byte by byte so nothing past
/// it is consumed.
func readHeaderLine(_ fd: Int32) -> String? {
    var bytes: [UInt8] = []
    var b: UInt8 = 0
    while bytes.count < 4096 {
        let n = read(fd, &b, 1)
        if n <= 0 { return nil }
        if b == 0x0a { return String(decoding: bytes, as: UTF8.self) }
        bytes.append(b)
    }
    return nil
}

func handleMCP(_ fd: Int32) {
    defer { close(fd) }
    guard let header = readHeaderLine(fd) else { return }
    let p = Process()
    if header.hasPrefix("#!cmd ") {
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", String(header.dropFirst(6))]
    } else {
        p.executableURL = home.appendingPathComponent(".local/bin/arc-cua")
        p.arguments = ["mcp"]
    }
    // The socket is the process's stdin and stdout: no copying through this process.
    let sock = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    p.standardInput = sock
    p.standardOutput = sock
    p.standardError = FileHandle.standardError
    do {
        try p.run()
    } catch {
        log("could not start MCP server: \(error)")
        let msg = #"{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"error","data":"guest could not start arc-cua"}}"# + "\n"
        try? FD.writeAll(fd, Data(msg.utf8))
        return
    }
    log("MCP server started (pid \(p.processIdentifier))")
    p.waitUntilExit()
    log("MCP server exited (\(p.terminationStatus))")
}

func handleScreenshot(_ fd: Int32) {
    defer { close(fd) }
    let path = NSTemporaryDirectory() + "dp-shot-\(UUID().uuidString).png"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-t", "png", path]
    do { try p.run(); p.waitUntilExit() } catch {}
    if let data = FileManager.default.contents(atPath: path) {
        try? FD.writeFrame(fd, data)
    } else {
        try? FD.writeFrame(fd, Data("screencapture failed; is Screen Recording granted?".utf8))
    }
}

/// 127.0.0.1:3128 -> host egress proxy. Loopback only: nothing else in the guest network
/// can reach it, and it is the only path out.
func runProxyForwarder() {
    Thread.detachNewThread {
        while true {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var on: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = GuestLAN.proxyPort.bigEndian
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            } && listen(s, 128) == 0
            guard ok else {
                log("proxy listen failed: \(String(cString: strerror(errno)))")
                close(s); sleep(2); continue
            }
            log("proxy forwarder on 127.0.0.1:\(GuestLAN.proxyPort)")
            while true {
                let c = accept(s, nil, nil)
                if c < 0 { if errno == EINTR || errno == ECONNABORTED { continue }; break }
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread {
                    defer { close(c) }
                    guard let h = connectHostVsock(port: VsockPort.hostProxy) else {
                        let r = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        try? FD.writeAll(c, Data(r.utf8))
                        return
                    }
                    defer { close(h) }
                    FD.splice(c, h)
                }
            }
            close(s)
        }
    }
}

// MARK: main

signal(SIGPIPE, SIG_IGN)
if !AXIsProcessTrusted() {
    // Puts the agent in the Accessibility list so the person only has to flip the switch.
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
}
if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
writeStatus()
log("agent \(version) up: \(currentStatus())")

listenVsock(port: VsockPort.guestControl, handler: handleControl)
listenVsock(port: VsockPort.guestMCP, handler: handleMCP)
listenVsock(port: VsockPort.guestScreenshot, handler: handleScreenshot)
runProxyForwarder()

Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in writeStatus() }
RunLoop.main.run()
