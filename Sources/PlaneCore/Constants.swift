import Foundation

/// vsock ports. Guest listens on the `guest*` ports; the host listens on the `host*` ports.
/// Ports below 1024 are privileged in the guest, and the agent does not run as root.
public enum VsockPort {
    /// Control channel: hello/time sync/ping. One request per connection.
    public static let guestControl: UInt32 = 52000
    /// Each connection spawns a fresh `arc-cua mcp` process and pipes its stdio.
    public static let guestMCP: UInt32 = 52001
    /// Each connection returns one PNG screenshot.
    public static let guestScreenshot: UInt32 = 52002
    /// Egress proxy. The guest's 127.0.0.1:3128 forwarder connects here.
    public static let hostProxy: UInt32 = 52100
}

/// Static addressing used on every VM's private, dead-end LAN.
/// Every VM uses the same addresses: each one sits on its own isolated segment, so they never meet.
public enum GuestLAN {
    public static let guestIP: [UInt8] = [10, 0, 2, 15]
    public static let gatewayIP: [UInt8] = [10, 0, 2, 2]
    public static let gatewayMAC: [UInt8] = [0x52, 0x54, 0x00, 0x12, 0x35, 0x02]
    public static let proxyPort: UInt16 = 3128
}
