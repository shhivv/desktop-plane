import Foundation
import Virtualization

/// A data disk that outlives sessions. The VM stays throwaway; the volume is plugged into a
/// fresh session as a USB drive after it boots, and mounts in the guest at `/Volumes/Data`.
///
///     volumes/<id>/
///       volume.json
///       volume.img      raw, sparse, APFS
///
/// The host formats a volume once, when it creates it, while the file holds nothing but
/// what the host wrote. After that only guests mount it: a guest can write a malformed
/// filesystem, and the host kernel must never parse it.
public struct Volume: Sendable {
    public struct Meta: Codable, Sendable {
        public var id: String
        public var name: String
        public var sizeGB: Int
        public var created: Date
        public var lastAttached: Date?
    }

    public static let label = "Data"
    public static var guestMountPoint: String { "/Volumes/\(label)" }

    public let dir: URL
    public var meta: Meta
    public var id: String { meta.id }
    var disk: URL { dir.appendingPathComponent("volume.img") }
    var metaFile: URL { dir.appendingPathComponent("volume.json") }

    /// Bytes actually stored (the file is sparse).
    public var allocatedBytes: Int64 {
        Int64((try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }

    static func create(name: String?, sizeGB: Int) throws -> Volume {
        let id = "vol_" + Token.random(bytes: 8)
        let dir = Paths.volumes.appendingPathComponent(id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        let v = Volume(dir: dir, meta: Meta(id: id, name: name ?? id, sizeGB: sizeGB, created: Date(), lastAttached: nil))
        do {
            fm.createFile(atPath: v.disk.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let h = try FileHandle(forWritingTo: v.disk)
            try h.truncate(atOffset: UInt64(sizeGB) << 30)
            try h.close()
            try format(v.disk)
            try v.save()
            return v
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// GPT + APFS volume named "Data", so the guest mounts it without an "unreadable disk" prompt.
    private static func format(_ disk: URL) throws {
        let out = try AgentUpdater.run("/usr/bin/hdiutil", ["attach", "-nomount", "-noverify", "-nobrowse",
                                                            "-imagekey", "diskimage-class=CRawDiskImage", disk.path])
        guard let dev = out.split(whereSeparator: \.isWhitespace).first.map(String.init), dev.hasPrefix("/dev/disk") else {
            throw PlaneError("could not attach new volume: \(out)")
        }
        defer { _ = try? AgentUpdater.run("/usr/bin/hdiutil", ["detach", dev, "-force"]) }
        try AgentUpdater.run("/usr/sbin/diskutil", ["eraseDisk", "APFS", label, "GPT", dev])
    }

    static func loadAll() -> [Volume] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.volumes, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("volume.json")),
                  let meta = try? dec.decode(Meta.self, from: data) else { return nil }
            return Volume(dir: d, meta: meta)
        }.sorted { $0.meta.created < $1.meta.created }
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: metaFile, options: .atomic)
    }

    /// Deletes the volume. Freed blocks are not overwritten (APFS on SSD gives no such
    /// guarantee); FileVault on the host is what protects deleted data at rest.
    func remove() throws {
        try FileManager.default.removeItem(at: dir)
    }
}
