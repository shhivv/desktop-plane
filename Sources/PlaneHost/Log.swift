import Foundation

/// Logs to stderr, to planed.log, and to an in-memory tail the UI shows.
public final class Log: @unchecked Sendable {
    public static let shared = Log()
    private let lock = NSLock()
    private var handle: FileHandle?
    private(set) var tail: [String] = []
    public var onLine: (@Sendable (String) -> Void)?

    private init() {
        try? Paths.ensure()
        if !FileManager.default.fileExists(atPath: Paths.log.path) {
            FileManager.default.createFile(atPath: Paths.log.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: Paths.log)
        _ = try? handle?.seekToEnd()
    }

    public func lines() -> [String] { lock.withLock { tail } }

    public static func info(_ msg: String, session: String? = nil) {
        shared.write("INFO", msg, session)
    }

    public static func warn(_ msg: String, session: String? = nil) {
        shared.write("WARN", msg, session)
    }

    public static func error(_ msg: String, session: String? = nil) {
        shared.write("ERROR", msg, session)
    }

    private func write(_ level: String, _ msg: String, _ session: String?) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(level) \(session.map { "[\($0)] " } ?? "")\(msg)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        lock.withLock {
            handle?.write(Data((line + "\n").utf8))
            tail.append(line)
            if tail.count > 500 { tail.removeFirst(tail.count - 500) }
        }
        onLine?(line)
    }
}
