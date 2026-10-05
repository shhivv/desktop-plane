import Foundation
import PlaneCore

/// One MCP session: a vsock connection to the guest agent, which runs a dedicated
/// `arc-cua mcp` process and pipes its stdio (newline-delimited JSON-RPC) to us.
///
/// The HTTP side speaks MCP Streamable HTTP in its simplest form: every POSTed request gets
/// its matching response back as `application/json`. Server-initiated messages
/// (notifications, progress) are dropped; arc-cua's driver does not need them.
final class MCPBridge: @unchecked Sendable {
    let id = Token.random(bytes: 16)
    private let fd: Int32
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var closed = false
    private let session: String
    var onClose: (@Sendable () -> Void)?

    init(fd: Int32, session: String) {
        self.fd = fd
        self.session = session
        Thread.detachNewThread { [self] in self.readLoop() }
    }

    /// Sends one JSON-RPC message. For requests, waits for the response with the same id.
    func send(_ message: Data, timeout: TimeInterval = 300) async throws -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else {
            throw PlaneError("expected a single JSON-RPC object")
        }
        let line = try JSONSerialization.data(withJSONObject: obj) + Data([0x0a])
        guard obj["method"] != nil, let rawID = obj["id"], !(rawID is NSNull) else {
            // Notification, or a response to a server request: fire and forget.
            try write(line)
            return nil
        }
        let key = Self.key(rawID)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if closed { lock.unlock(); cont.resume(throwing: PlaneError("MCP connection closed")); return }
            pending[key] = cont
            lock.unlock()
            do { try write(line) } catch { finish(key, .failure(error)); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(key, .failure(PlaneError("guest did not answer within \(Int(timeout))s")))
            }
        }
    }

    private func write(_ data: Data) throws {
        try lock.withLock {
            if closed { throw PlaneError("MCP connection closed") }
            try FD.writeAll(fd, data)
        }
    }

    private func finish(_ key: String, _ r: Result<Data, Error>) {
        let c = lock.withLock { pending.removeValue(forKey: key) }
        c?.resume(with: r)
    }

    private func readLoop() {
        var buf = Data()
        while true {
            guard let chunk = try? FD.readSome(fd), !chunk.isEmpty else { break }
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 0x0a) {
                let line = buf[buf.startIndex..<nl]
                buf = Data(buf[buf.index(after: nl)...])
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                // A response has an id and no method.
                if obj["method"] == nil, let rawID = obj["id"] {
                    finish(Self.key(rawID), .success(Data(line)))
                }
            }
        }
        close()
        // Only the reader closes the descriptor, so it can never read a reused fd number.
        Darwin.close(fd)
    }

    func close() {
        let waiting: [CheckedContinuation<Data, Error>]? = lock.withLock {
            if closed { return nil }
            closed = true
            shutdown(fd, SHUT_RDWR)
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        guard let waiting else { return }
        for c in waiting { c.resume(throwing: PlaneError("MCP connection closed")) }
        onClose?()
    }

    static func key(_ id: Any) -> String {
        if let s = id as? String { return "s:" + s }
        if let n = id as? NSNumber { return "n:" + n.stringValue }
        return "x:\(id)"
    }
}
