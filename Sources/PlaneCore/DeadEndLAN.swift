import Foundation

/// The other end of a VM's virtual network card.
///
/// The guest needs an Ethernet interface with a route, or macOS reports it as offline and
/// browsers refuse to use the proxy. But no packet may leave the host from it. This gives the
/// guest just enough to look connected and to fail fast:
/// - ARP: every address on the segment resolves to the gateway's MAC.
/// - TCP: every segment is answered with a reset, so direct connections fail at once instead of
///   hanging until a timeout.
/// - UDP: answered with ICMP port unreachable (DNS lookups fail at once).
/// Everything else is dropped. Nothing is ever forwarded anywhere.
public enum DeadEndLAN {
    /// Returns the frames to send back to the guest for one frame received from it.
    public static func respond(to frame: [UInt8]) -> [[UInt8]] {
        guard frame.count >= 14 else { return [] }
        let srcMAC = Array(frame[6..<12])
        let etherType = UInt16(frame[12]) << 8 | UInt16(frame[13])
        let payload = Array(frame[14...])
        switch etherType {
        case 0x0806:
            return arpReply(payload, srcMAC: srcMAC).map { [$0] } ?? []
        case 0x0800:
            return ipv4Reply(payload, srcMAC: srcMAC).map { [$0] } ?? []
        default:
            return []
        }
    }

    static func ethernet(dst: [UInt8], type: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var f: [UInt8] = dst
        f.append(contentsOf: GuestLAN.gatewayMAC)
        f.append(UInt8(type >> 8))
        f.append(UInt8(type & 0xff))
        f.append(contentsOf: payload)
        return f
    }

    static func arpReply(_ p: [UInt8], srcMAC: [UInt8]) -> [UInt8]? {
        // Ethernet/IPv4 ARP request only.
        guard p.count >= 28, p[0] == 0, p[1] == 1, p[2] == 0x08, p[3] == 0, p[4] == 6, p[5] == 4,
              p[6] == 0, p[7] == 1 else { return nil }
        let senderMAC = Array(p[8..<14])
        let senderIP = Array(p[14..<18])
        let targetIP = Array(p[24..<28])
        // Gratuitous ARP / probes for the guest's own address: stay silent so it keeps it.
        if targetIP == senderIP || senderIP == [0, 0, 0, 0] { return nil }
        var r: [UInt8] = [0, 1, 0x08, 0, 6, 4, 0, 2]
        r += GuestLAN.gatewayMAC + targetIP + senderMAC + senderIP
        return ethernet(dst: srcMAC, type: 0x0806, r)
    }

    static func ipv4Reply(_ p: [UInt8], srcMAC: [UInt8]) -> [UInt8]? {
        guard p.count >= 20, p[0] >> 4 == 4 else { return nil }
        let ihl = Int(p[0] & 0x0f) * 4
        let total = Int(p[2]) << 8 | Int(p[3])
        guard ihl >= 20, total >= ihl, p.count >= total else { return nil }
        // Ignore fragments after the first: only the first one carries the transport header.
        let fragOffset = (Int(p[6] & 0x1f) << 8) | Int(p[7])
        guard fragOffset == 0 else { return nil }
        let proto = p[9]
        let src = Array(p[12..<16])
        let dst = Array(p[16..<20])
        // Never answer broadcast or multicast (DHCP, mDNS, SSDP...).
        if dst == [255, 255, 255, 255] || dst[0] >= 224 || dst[3] == 255 { return nil }
        let l4 = Array(p[ihl..<total])
        switch proto {
        case 6:
            guard let seg = tcpReset(l4, src: src, dst: dst) else { return nil }
            return ethernet(dst: srcMAC, type: 0x0800, ipv4(src: dst, dst: src, proto: 6, seg))
        case 17:
            // ICMP port unreachable quoting the offending header + 8 bytes.
            let quote = Array(p[0..<min(total, ihl + 8)])
            var icmp: [UInt8] = [3, 3, 0, 0, 0, 0, 0, 0] + quote
            let c = checksum(icmp)
            icmp[2] = UInt8(c >> 8); icmp[3] = UInt8(c & 0xff)
            return ethernet(dst: srcMAC, type: 0x0800, ipv4(src: GuestLAN.gatewayIP, dst: src, proto: 1, icmp))
        default:
            return nil
        }
    }

    static func tcpReset(_ t: [UInt8], src: [UInt8], dst: [UInt8]) -> [UInt8]? {
        guard t.count >= 20 else { return nil }
        let flags = t[13]
        let rst: UInt8 = 0x04, syn: UInt8 = 0x02, fin: UInt8 = 0x01, ack: UInt8 = 0x10
        if flags & rst != 0 { return nil } // never answer a reset
        let dataOffset = Int(t[12] >> 4) * 4
        guard dataOffset >= 20, dataOffset <= t.count else { return nil }
        let seq = be32(t, 4)
        let ackNum = be32(t, 8)
        var segLen = UInt32(t.count - dataOffset)
        if flags & syn != 0 { segLen &+= 1 }
        if flags & fin != 0 { segLen &+= 1 }

        var r = [UInt8](repeating: 0, count: 20)
        r[0] = t[2]; r[1] = t[3]   // our source port = their destination port
        r[2] = t[0]; r[3] = t[1]
        let rSeq: UInt32
        let rAck: UInt32
        let rFlags: UInt8
        if flags & ack != 0 {
            // RFC 793: if the incoming segment has ACK, reset carries seq = their ack.
            rSeq = ackNum; rAck = 0; rFlags = rst
        } else {
            rSeq = 0; rAck = seq &+ segLen; rFlags = rst | ack
        }
        put32(&r, 4, rSeq)
        put32(&r, 8, rAck)
        r[12] = 5 << 4
        r[13] = rFlags
        // window 0, urgent 0
        let pseudo = dst + src + [0, 6, 0, 20]
        let c = checksum(pseudo + r)
        r[16] = UInt8(c >> 8); r[17] = UInt8(c & 0xff)
        return r
    }

    static func ipv4(src: [UInt8], dst: [UInt8], proto: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let len = 20 + payload.count
        var h: [UInt8] = [0x45, 0, UInt8(len >> 8), UInt8(len & 0xff), 0, 0, 0x40, 0, 64, proto, 0, 0]
        h += src + dst
        let c = checksum(h)
        h[10] = UInt8(c >> 8); h[11] = UInt8(c & 0xff)
        return h + payload
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum &+= UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum &+= UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) &+ (sum >> 16) }
        return ~UInt16(sum)
    }

    static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    static func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o] = UInt8(v >> 24); b[o + 1] = UInt8((v >> 16) & 0xff)
        b[o + 2] = UInt8((v >> 8) & 0xff); b[o + 3] = UInt8(v & 0xff)
    }
}
