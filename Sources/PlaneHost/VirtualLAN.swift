import Foundation
import PlaneCore

/// A VM's private network segment: one datagram socket pair, one end handed to the VM's NIC,
/// the other answered by `DeadEndLAN`. Each VM gets its own pair, so there is no medium two
/// VMs could share, and nothing read here is ever forwarded.
final class VirtualLAN: @unchecked Sendable {
    let guestEnd: FileHandle
    private let hostFD: Int32
    private var running = true
    private let session: String

    init(session: String) throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else { throw PlaneError("socketpair: \(errno)") }
        for fd in fds {
            var snd: Int32 = 1 << 20, rcv: Int32 = 4 << 20
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        }
        guestEnd = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        hostFD = fds[1]
        self.session = session
        let t = Thread { [self] in self.loop() }
        t.name = "lan-\(session)"
        t.start()
    }

    private func loop() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var dropped = 0
        while running {
            let n = recv(hostFD, &buf, buf.count, 0)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { continue }
            let replies = DeadEndLAN.respond(to: Array(buf[0..<n]))
            if replies.isEmpty {
                dropped += 1
                continue
            }
            for r in replies { _ = r.withUnsafeBytes { send(hostFD, $0.baseAddress, $0.count, 0) } }
        }
        if dropped > 0 { Log.info("virtual LAN closed (\(dropped) frames dropped)", session: session) }
    }

    func close() {
        running = false
        shutdown(hostFD, SHUT_RDWR)
        Darwin.close(hostFD)
    }
}
