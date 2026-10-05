import Foundation

/// Host -> guest on `VsockPort.guestControl`.
public struct ControlRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case ping, hello }
    public var kind: Kind
    public var sessionID: String?
    /// Host wall clock (seconds since 1970). Restored VMs wake with the clock of the snapshot.
    public var hostTime: Double?

    public init(kind: Kind, sessionID: String? = nil, hostTime: Double? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.hostTime = hostTime
    }
}

/// Guest -> host reply on `VsockPort.guestControl`.
public struct ControlReply: Codable, Sendable {
    public var ok: Bool
    public var agentVersion: String
    public var accessibility: Bool
    public var screenRecording: Bool
    public var arcCUA: String?
    public var error: String?

    public init(ok: Bool, agentVersion: String, accessibility: Bool, screenRecording: Bool, arcCUA: String?, error: String? = nil) {
        self.ok = ok
        self.agentVersion = agentVersion
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.arcCUA = arcCUA
        self.error = error
    }
}
