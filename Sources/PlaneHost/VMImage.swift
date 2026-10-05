import Foundation
import Virtualization

/// A golden image on disk:
///
///     images/<name>/
///       image.json            metadata and build stage
///       disk.img              boot disk (raw, sparse)
///       aux.img               Mac auxiliary storage (NVRAM)
///       hardware-model.bin
///       machine-id.bin
///       state.vzvmsave        saved RAM + device state, written by finalize
///       cold-disk.img         the disk as provisioning left it (cleanly shut down)
///       cold-aux.img
///
/// Sessions never touch these files: they get APFS clones and boot from those.
///
/// Only one VM restored from a snapshot can run per machine identity at a time
/// (Virtualization fails a second restore with "invalid argument"). A second identity is
/// no way out: macOS sees a different Mac and greets it with Setup Assistant. So the first
/// running session restores the snapshot, and any session started while it runs cold boots
/// from the clean copy instead: same identity, a few seconds slower.
public struct VMImage: Sendable {
    public enum Stage: String, Codable, Sendable {
        /// macOS installed, Setup Assistant not done yet.
        case installed
        /// Guest tools installed and permissions granted; not yet snapshotted.
        case provisioned
        /// Snapshot saved. Sessions can be spawned.
        case ready
    }

    public struct Meta: Codable, Sendable {
        public var name: String
        public var stage: Stage
        public var macOSBuild: String
        public var diskGB: Int
        public var macAddress: String
        public var created: Date
        public var finalized: Date?
        /// CPU and memory the snapshot was taken with. Restores must use the same.
        public var cpus: Int?
        public var memoryGB: Int?
    }

    public let dir: URL
    public var meta: Meta

    public var disk: URL { dir.appendingPathComponent("disk.img") }
    public var aux: URL { dir.appendingPathComponent("aux.img") }
    public var hardwareModelFile: URL { dir.appendingPathComponent("hardware-model.bin") }
    public var machineIDFile: URL { dir.appendingPathComponent("machine-id.bin") }
    public var state: URL { dir.appendingPathComponent("state.vzvmsave") }
    var metaFile: URL { dir.appendingPathComponent("image.json") }
    var coldDisk: URL { dir.appendingPathComponent("cold-disk.img") }
    var coldAux: URL { dir.appendingPathComponent("cold-aux.img") }

    static func load(from dir: URL) -> VMImage? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("image.json")),
              let meta = try? dec.decode(Meta.self, from: data) else { return nil }
        return VMImage(dir: dir, meta: meta)
    }

    public static func dir(named name: String) -> URL { Paths.images.appendingPathComponent(name) }

    public static func load(named name: String) -> VMImage? { load(from: dir(named: name)) }

    public func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: metaFile, options: .atomic)
    }

    public func hardwareModel() throws -> VZMacHardwareModel {
        guard let m = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: hardwareModelFile)),
              m.isSupported else { throw PlaneError("image hardware model is not supported on this host") }
        return m
    }

    public func machineIdentifier() throws -> VZMacMachineIdentifier {
        guard let m = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: machineIDFile)) else {
            throw PlaneError("image machine identifier is unreadable")
        }
        return m
    }
}

public struct PlaneError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ d: String) { description = d }
    public var errorDescription: String? { description }
}
