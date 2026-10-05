import Foundation
import PlaneCore

/// HTTP proxy serving one VM's vsock egress port. The guest's 127.0.0.1:3128 forwarder
/// connects here; this is the VM's only way out.
///
/// - Names are resolved here, on the host, and the proxy connects to the exact address it
///   checked, so DNS rebinding cannot turn an allowed name into a private address.
/// - The session is known from which VM's vsock device the connection came in on; nothing the
///   guest sends can claim another identity.
enum EgressProxy {
    static func serve(fd: Int32, policy: EgressPolicy, session: String) {
        defer { close(fd) }
        guard let (head, rest) = try? FD.readHTTPHead(fd) else { return }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard requestLine.count == 3 else { return reply(fd, 400, "bad request") }
        let method = requestLine[0], target = requestLine[1], version = requestLine[2]

        if method.uppercased() == "CONNECT" {
            guard let (host, port) = splitHostPort(target, defaultPort: 443) else { return reply(fd, 400, "bad target") }
            guard let upstream = open(host: host, port: port, policy: policy, session: session, fd: fd, label: "CONNECT") else { return }
            defer { close(upstream) }
            guard (try? FD.writeAll(fd, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))) != nil else { return }
            if !rest.isEmpty { try? FD.writeAll(upstream, rest) }
            FD.splice(fd, upstream)
            return
        }

        // Plain HTTP in absolute form: GET http://host[:port]/path HTTP/1.1
        guard let url = URL(string: target), url.scheme?.lowercased() == "http", let host = url.host else {
            return reply(fd, 400, "only absolute http:// URLs and CONNECT are supported")
        }
        let port = url.port ?? 80
        guard let upstream = open(host: host, port: port, policy: policy, session: session, fd: fd, label: method) else { return }
        defer { close(upstream) }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        // One request per connection: a kept-alive proxy connection must not carry a second
        // request to the upstream this one was checked for.
        var out = ["\(method) \(path) \(version)"]
        for l in lines where !l.isEmpty {
            let name = l.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            if ["proxy-connection", "proxy-authorization", "connection", "keep-alive"].contains(name) { continue }
            out.append(l)
        }
        out.append("Connection: close")
        let req = Data((out.joined(separator: "\r\n") + "\r\n\r\n").utf8) + rest
        guard (try? FD.writeAll(upstream, req)) != nil else { return }
        FD.splice(fd, upstream)
    }

    /// Checks policy, resolves, connects. Replies with an error and returns nil on failure.
    private static func open(host: String, port: Int, policy: EgressPolicy, session: String, fd: Int32, label: String) -> Int32? {
        if case .denied(let why) = policy.check(host: host, port: port) {
            Log.info("egress denied \(label) \(host):\(port): \(why)", session: session)
            reply(fd, 403, "blocked by desktop-plane: \(why)")
            return nil
        }
        let addrs = resolve(host: host, port: port).filter { IPAddress.isPublic($0.bytes) }
        guard !addrs.isEmpty else {
            Log.info("egress denied \(label) \(host):\(port): no public address", session: session)
            reply(fd, 403, "blocked by desktop-plane: \(host) has no public address")
            return nil
        }
        for a in addrs {
            if let s = connect(a, timeout: 10) {
                Log.info("egress \(label) \(host):\(port) -> \(a.text)", session: session)
                return s
            }
        }
        reply(fd, 502, "could not connect to \(host):\(port)")
        return nil
    }

    private static func reply(_ fd: Int32, _ code: Int, _ msg: String) {
        let reason = [400: "Bad Request", 403: "Forbidden", 502: "Bad Gateway"][code] ?? "Error"
        let body = msg + "\n"
        let r = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        try? FD.writeAll(fd, Data(r.utf8))
    }

    static func splitHostPort(_ s: String, defaultPort: Int) -> (String, Int)? {
        if s.hasPrefix("[") {
            guard let end = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<end])
            let after = s[s.index(after: end)...]
            if after.hasPrefix(":"), let p = Int(after.dropFirst()) { return (host, p) }
            return after.isEmpty ? (host, defaultPort) : nil
        }
        let parts = s.split(separator: ":")
        if parts.count == 2, let p = Int(parts[1]) { return (String(parts[0]), p) }
        if parts.count == 1 { return (String(parts[0]), defaultPort) }
        return nil
    }

    struct Addr {
        var storage: sockaddr_storage
        var len: socklen_t
        var bytes: [UInt8]
        var text: String
    }

    static func resolve(host: String, port: Int) -> [Addr] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [Addr] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            var ss = sockaddr_storage()
            memcpy(&ss, ai.pointee.ai_addr, Int(ai.pointee.ai_addrlen))
            var bytes: [UInt8] = []
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if ai.pointee.ai_family == AF_INET {
                var sin = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                bytes = withUnsafeBytes(of: &sin.sin_addr) { Array($0) }
                inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(text.count))
            } else if ai.pointee.ai_family == AF_INET6 {
                var sin6 = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                bytes = withUnsafeBytes(of: &sin6.sin6_addr) { Array($0) }
                inet_ntop(AF_INET6, &sin6.sin6_addr, &text, socklen_t(text.count))
            }
            if !bytes.isEmpty {
                out.append(Addr(storage: ss, len: ai.pointee.ai_addrlen, bytes: bytes,
                                text: String(cString: text)))
            }
            p = ai.pointee.ai_next
        }
        return out
    }

    static func connect(_ a: Addr, timeout: Int32) -> Int32? {
        let s = socket(Int32(a.storage.ss_family), SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        var ss = a.storage
        let r = withUnsafePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, a.len) }
        }
        if r != 0 && errno != EINPROGRESS { close(s); return nil }
        if r != 0 {
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, timeout * 1000) == 1 else { close(s); return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { close(s); return nil }
        }
        _ = fcntl(s, F_SETFL, flags)
        return s
    }
}
