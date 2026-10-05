import Foundation
import Virtualization
import PlaneCore

/// Host-side calls into a guest over its vsock device.
@MainActor
struct GuestLink {
    let device: VZVirtioSocketDevice

    init(vm: VZVirtualMachine) throws {
        guard let d = vm.socketDevices.first as? VZVirtioSocketDevice else { throw PlaneError("VM has no vsock device") }
        device = d
    }

    /// Opens a connection to a guest port. The caller owns the returned descriptor.
    func connect(port: UInt32) async throws -> Int32 {
        let conn: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { cont in
            device.connect(toPort: port) { result in cont.resume(with: result) }
        }
        // Take our own descriptor so its lifetime does not depend on the connection object.
        let fd = dup(conn.fileDescriptor)
        conn.close()
        guard fd >= 0 else { throw PlaneError("dup failed") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    func control(_ req: ControlRequest, timeout: TimeInterval = 10) async throws -> ControlReply {
        let fd = try await connect(port: VsockPort.guestControl)
        let payload = try JSONEncoder().encode(req)
        return try await Self.blocking(timeout: timeout, fd: fd) {
            defer { close(fd) }
            try FD.writeFrame(fd, payload)
            return try JSONDecoder().decode(ControlReply.self, from: FD.readFrame(fd))
        }
    }

    func screenshot() async throws -> Data {
        let fd = try await connect(port: VsockPort.guestScreenshot)
        return try await Self.blocking(timeout: 20, fd: fd) {
            defer { close(fd) }
            let data = try FD.readFrame(fd)
            guard data.starts(with: [0x89, 0x50, 0x4e, 0x47]) else {
                throw PlaneError("guest screenshot failed: \(String(decoding: data.prefix(200), as: UTF8.self))")
            }
            return data
        }
    }

    /// Runs blocking I/O off the main actor, shutting the socket down if it overruns.
    nonisolated static func blocking<T: Sendable>(timeout: TimeInterval, fd: Int32,
                                                  _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let timer = DispatchWorkItem { shutdown(fd, SHUT_RDWR) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { cont.resume(with: Result { try work() }) }
        }
    }
}
