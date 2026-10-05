import Foundation

/// Small blocking-I/O helpers over raw file descriptors. Both sides use one thread per
/// connection; at two VMs per host that is far simpler than an event loop and plenty fast.
public enum FD {
    public enum IOError: Error { case closed, failed(Int32) }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw IOError.failed(errno)
                }
                off += n
            }
        }
    }

    public static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var out = Data(count: count)
        var off = 0
        try out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            while off < count {
                let n = Darwin.read(fd, buf.baseAddress! + off, count - off)
                if n == 0 { throw IOError.closed }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw IOError.failed(errno)
                }
                off += n
            }
        }
        return out
    }

    /// Reads up to `max` bytes. Returns empty Data on EOF.
    public static func readSome(_ fd: Int32, max: Int = 64 * 1024) throws -> Data {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = Darwin.read(fd, &buf, max)
            if n < 0 {
                if errno == EINTR { continue }
                throw IOError.failed(errno)
            }
            return Data(buf[0..<n])
        }
    }

    /// Length-prefixed (u32 big-endian) frames.
    public static func writeFrame(_ fd: Int32, _ payload: Data) throws {
        var len = UInt32(payload.count).bigEndian
        try writeAll(fd, Data(bytes: &len, count: 4) + payload)
    }

    public static func readFrame(_ fd: Int32, limit: Int = 64 << 20) throws -> Data {
        let head = try readExactly(fd, 4)
        let len = head.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard len <= limit else { throw IOError.failed(EMSGSIZE) }
        return try readExactly(fd, len)
    }

    /// Copies bytes both ways until either side closes, then shuts both down.
    /// Blocks until both directions finish.
    public static func splice(_ a: Int32, _ b: Int32, onBytes: (@Sendable (Int) -> Void)? = nil) {
        let group = DispatchGroup()
        func pump(_ from: Int32, _ to: Int32) {
            group.enter()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = Darwin.read(from, &buf, buf.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    if (try? writeAll(to, Data(buf[0..<n]))) == nil { break }
                    onBytes?(n)
                }
                shutdown(to, SHUT_WR)
                shutdown(from, SHUT_RD)
                group.leave()
            }
        }
        pump(a, b)
        pump(b, a)
        group.wait()
    }

    /// Reads until "\r\n\r\n". Returns (head, any bytes read past the head).
    public static func readHTTPHead(_ fd: Int32, limit: Int = 64 * 1024) throws -> (head: String, rest: Data) {
        var acc = Data()
        let marker = Data("\r\n\r\n".utf8)
        while true {
            let chunk = try readSome(fd, max: 16 * 1024)
            if chunk.isEmpty { throw IOError.closed }
            acc.append(chunk)
            if let r = acc.range(of: marker) {
                let head = String(decoding: acc[acc.startIndex..<r.lowerBound], as: UTF8.self)
                return (head, Data(acc[r.upperBound...]))
            }
            if acc.count > limit { throw IOError.failed(EMSGSIZE) }
        }
    }
}
