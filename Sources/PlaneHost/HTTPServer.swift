import Foundation
import PlaneCore

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    var bearer: String? {
        guard let h = header("authorization"), h.lowercased().hasPrefix("bearer ") else { return nil }
        return String(h.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String] = [:]
    public var body = Data()

    public static func json(_ status: Int, _ obj: Any, headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        var h = headers
        h["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: h, body: data)
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, ["error": message])
    }
}

/// Minimal HTTP/1.1 server: one thread per connection, Content-Length bodies, keep-alive.
/// Small and dependency-free; the API it serves is tiny.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    private let handler: Handler
    private var listenFD: Int32 = -1

    init(handler: @escaping Handler) { self.handler = handler }

    func start(address: String, port: UInt16) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { throw PlaneError("bad bind address \(address)") }
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0, listen(s, 64) == 0 else {
            let e = errno
            close(s)
            throw PlaneError("cannot listen on \(address):\(port): \(String(cString: strerror(e)))")
        }
        listenFD = s
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(s, nil, nil)
                if c < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    break
                }
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { self.serve(c) }
            }
        }
    }

    func stop() {
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var carry = Data()
        while true {
            guard let (req, rest) = readRequest(fd, carry: carry) else { return }
            carry = rest
            let res = runBlocking { await self.handler(req) }
            let keepAlive = req.header("connection")?.lowercased() != "close"
            write(fd, res, keepAlive: keepAlive)
            if !keepAlive { return }
        }
    }

    private func readRequest(_ fd: Int32, carry: Data) -> (HTTPRequest, Data)? {
        var acc = carry
        let marker = Data("\r\n\r\n".utf8)
        var headEnd = acc.range(of: marker)
        while headEnd == nil {
            guard acc.count < 64 * 1024, let chunk = try? FD.readSome(fd), !chunk.isEmpty else { return nil }
            acc.append(chunk)
            headEnd = acc.range(of: marker)
        }
        let head = String(decoding: acc[acc.startIndex..<headEnd!.lowerBound], as: UTF8.self)
        var body = Data(acc[headEnd!.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ").map(String.init)
        guard parts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return nil }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= 16 << 20 else { return nil }
        while body.count < length {
            guard let chunk = try? FD.readSome(fd), !chunk.isEmpty else { return nil }
            body.append(chunk)
        }
        let rest = Data(body[(body.startIndex + length)...])
        body = Data(body.prefix(length))
        let comps = URLComponents(string: parts[1])
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        let req = HTTPRequest(method: parts[0].uppercased(), path: comps?.path ?? parts[1],
                              query: query, headers: headers, body: body)
        return (req, rest)
    }

    private func write(_ fd: Int32, _ res: HTTPResponse, keepAlive: Bool) {
        let reasons = [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 400: "Bad Request",
                       401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                       409: "Conflict", 429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway",
                       503: "Service Unavailable"]
        var head = "HTTP/1.1 \(res.status) \(reasons[res.status] ?? "Status")\r\n"
        var headers = res.headers
        headers["Content-Length"] = String(res.body.count)
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        headers["Cache-Control"] = "no-store"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        try? FD.writeAll(fd, Data(head.utf8) + res.body)
    }

    private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached {
            box.value = await work()
            sem.signal()
        }
        sem.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }
}
