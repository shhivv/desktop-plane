import Foundation

/// Updates the guest agent inside the golden image without booting it: mounts the image's
/// disk on the host, writes the new agent files, and unmounts.
///
/// The agent core can change freely. If the launcher (the app the guest's permissions are
/// granted to) changes too, its ad-hoc code identity changes, so the existing Accessibility and
/// Screen Recording grants are re-pointed at the new identity in the guest's TCC database.
/// That is the guest's own permission store on a disk we own, edited while the guest is off.
///
/// It also pre-approves "Removable Volumes" for the agent. Otherwise the first touch of a data
/// volume raises a privacy prompt in the guest that blocks the process until someone clicks,
/// and no one is there to click.
///
/// The disk changes, so the image goes back to `provisioned` and needs a new snapshot.
public enum AgentUpdater {
    static let bundleID = "dev.desktopplane.agent"
    static let textSubstitutionKeys = [
        "NSAutomaticSpellingCorrectionEnabled", "NSAutomaticCapitalizationEnabled", "NSAutomaticPeriodSubstitutionEnabled",
        "NSAutomaticQuoteSubstitutionEnabled", "NSAutomaticDashSubstitutionEnabled", "NSAutomaticTextCompletionEnabled",
        "NSAutomaticInlinePredictionEnabled", "WebAutomaticSpellingCorrectionEnabled",
    ]

    @MainActor
    public static func update(image: VMImage) throws -> String {
        var image = image
        for f in [image.disk, image.aux] { chmod(f.path, 0o600) }
        let (devices, mounts) = try attach(image.disk)
        defer { detach(devices) }
        guard let data = mounts.first(where: isDataVolume) else {
            throw PlaneError("could not find the guest's Data volume in \(mounts.map(\.path))")
        }
        var notes: [String] = []
        let fm = FileManager.default

        // 1. Agent core.
        let coreDst = data.appendingPathComponent(String(GuestTools.guestCorePath.dropFirst()))
        try fm.createDirectory(at: coreDst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: coreDst)
        try fm.copyItem(at: try GuestTools.agentCore(), to: coreDst)
        chmod(coreDst.path, 0o755)
        notes.append("agent core updated")

        // 2. Launcher, only if it differs.
        let staged = fm.temporaryDirectory.appendingPathComponent("dp-\(UUID().uuidString)/\(GuestTools.agentBundleName)")
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staged.deletingLastPathComponent()) }
        try GuestTools.buildAgentBundle(at: staged)
        let appDst = data.appendingPathComponent("Applications/\(GuestTools.agentBundleName)")
        let exe = "Contents/MacOS/\(GuestTools.launcherExecutable)"
        let same = fm.contentsEqual(atPath: staged.appendingPathComponent(exe).path, andPath: appDst.appendingPathComponent(exe).path)
        if !same {
            try? fm.removeItem(at: appDst)
            try fm.copyItem(at: staged, to: appDst)
            let n = try repointGrants(tccDB: data.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
                                      requirement: try requirementHex(app: staged))
            notes.append(n == 0 ? "launcher replaced; no existing grants found, grant permissions while provisioning"
                                : "launcher replaced; \(n) permission grants moved to it")
        }

        // 3. LaunchAgents point at the launcher; removable volumes are pre-approved for it.
        // Real home folders only (not Shared, .localized and the like).
        let users = ((try? fm.contentsOfDirectory(at: data.appendingPathComponent("Users"), includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "Shared" }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("Library/Preferences").path) }
        if fm.fileExists(atPath: appDst.path) {
            let req = try requirementHex(app: appDst)
            for home in users {
                let db = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
                guard fm.fileExists(atPath: db.path) else { continue }
                try run("/usr/bin/sqlite3", [db.path, """
                    INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version,
                        csreq, indirect_object_identifier, flags)
                    VALUES ('kTCCServiceSystemPolicyRemovableVolumes', '\(bundleID)', 0, 2, 4, 1, X'\(req)', 'UNUSED', 0);
                    """])
                notes.append("removable volumes allowed for \(home.lastPathComponent)")
            }
        }
        // The agent may set the clock (after restores) and shut the VM down (image builds).
        // Rewritten in place: sudo only trusts the file while it stays root-owned and 0440.
        let sudoers = data.appendingPathComponent("private/etc/sudoers.d/desktopplane")
        if let user = users.first?.lastPathComponent, fm.fileExists(atPath: sudoers.path) {
            chmod(sudoers.path, 0o640)
            defer { chmod(sudoers.path, 0o440) }
            let h = try FileHandle(forWritingTo: sudoers)
            try h.truncate(atOffset: 0)
            try h.write(contentsOf: Data("\(user) ALL=(root) NOPASSWD: /bin/date, /sbin/shutdown\n".utf8))
            try h.close()
            notes.append("sudo rule updated")
        }

        // Agents type exact text: no autocorrect, auto-capitalisation or smart punctuation.
        for home in users {
            // `defaults` takes a plist path without its extension.
            let prefs = home.appendingPathComponent("Library/Preferences/.GlobalPreferences")
            for key in textSubstitutionKeys {
                try run("/usr/bin/defaults", ["write", prefs.path, key, "-bool", "false"])
            }
            notes.append("text substitutions off for \(home.lastPathComponent)")
        }
        for home in users {
            let plistURL = home.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
            guard let d = try? Data(contentsOf: plistURL),
                  var plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { continue }
            plist["ProgramArguments"] = ["/Applications/\(GuestTools.agentBundleName)/\(exe)"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
            notes.append("launch agent updated for \(home.lastPathComponent)")
        }

        try? fm.removeItem(at: image.state)
        for f in [image.coldDisk, image.coldAux] { try? fm.removeItem(at: f) }
        image.meta.stage = .provisioned
        try image.save()
        notes.append("image needs a new snapshot")
        return notes.joined(separator: "; ")
    }

    /// Points the guest's existing grants for the agent's bundle id at the new launcher's code
    /// requirement. Returns how many grants were updated.
    static func repointGrants(tccDB: URL, requirement hex: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: tccDB.path) else { return 0 }
        let out = try run("/usr/bin/sqlite3", [tccDB.path,
            "UPDATE access SET csreq = X'\(hex)' WHERE client = '\(bundleID)' AND client_type = 0; SELECT changes();"])
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The app's designated requirement, compiled, as hex: what TCC stores to recognise it.
    static func requirementHex(app: URL) throws -> String {
        // e.g. "designated => cdhash H\"…\"" for an ad-hoc signature.
        let req = try run("/usr/bin/codesign", ["-d", "-r-", app.path])
        guard let line = req.split(separator: "\n").first(where: { $0.contains("designated =>") }),
              let range = line.range(of: "designated => ") else { throw PlaneError("no designated requirement for \(app.path)") }
        let requirement = String(line[range.upperBound...])
        let blob = FileManager.default.temporaryDirectory.appendingPathComponent("dp-req-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blob) }
        _ = try run("/usr/bin/csreq", ["-r=" + requirement, "-b", blob.path])
        return try Data(contentsOf: blob).map { String(format: "%02X", $0) }.joined()
    }

    /// The guest's Data volume: it has the home folders and, unlike the system volume (which
    /// shows the same folders through firmlinks), it is not sealed. Never write to the sealed
    /// system volume.
    static func isDataVolume(_ mount: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: mount.appendingPathComponent("Users").path),
              let out = try? run("/usr/sbin/diskutil", ["info", "-plist", mount.path]),
              let info = try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as? [String: Any]
        else { return false }
        return (info["Sealed"] as? String) != "Yes" && (info["SystemImage"] as? Bool) != true
    }

    static func attach(_ disk: URL) throws -> ([String], [URL]) {
        let out = try run("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", "-noverify",
                                               "-imagekey", "diskimage-class=CRawDiskImage", disk.path])
        guard let plist = try PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { throw PlaneError("unexpected hdiutil output") }
        let devices = entities.compactMap { $0["dev-entry"] as? String }
        let mounts = entities.compactMap { $0["mount-point"] as? String }.map { URL(fileURLWithPath: $0) }
        return (devices, mounts)
    }

    static func detach(_ devices: [String]) {
        // Whole disks detach their partitions and containers with them.
        let whole = devices.filter { $0.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil }
        for d in whole.reversed() {
            _ = try? run("/usr/bin/hdiutil", ["detach", d, "-force"])
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw PlaneError("\(tool) \(args.first ?? "") failed: \(text)") }
        return text
    }
}
