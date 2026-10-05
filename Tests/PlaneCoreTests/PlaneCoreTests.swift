import XCTest
@testable import PlaneCore

final class EgressPolicyTests: XCTestCase {
    func testNonPublicAddressesAlwaysDenied() {
        let p = EgressPolicy(allow: ["*"], ports: [])
        for host in ["127.0.0.1", "10.1.2.3", "172.20.0.1", "192.168.1.10", "169.254.169.254",
                     "100.100.100.100", "0.0.0.0", "224.0.0.251", "255.255.255.255",
                     "::1", "[::1]", "fe80::1", "fd00::1", "::ffff:10.0.0.1", "::ffff:127.0.0.1",
                     "64:ff9b::a00:1", "2002:a00:1::1", "::",
                     "localhost", "foo.localhost", "printer.local", "metadata.google.internal"] {
            XCTAssertNotEqual(p.check(host: host, port: 443), .allowed, host)
        }
    }

    func testPublicAllowedByDefault() {
        let p = EgressPolicy()
        XCTAssertEqual(p.check(host: "example.com", port: 443), .allowed)
        XCTAssertEqual(p.check(host: "93.184.216.34", port: 80), .allowed)
        XCTAssertEqual(p.check(host: "2606:2800:220:1::1", port: 443), .allowed)
        XCTAssertNotEqual(p.check(host: "example.com", port: 22), .allowed)
    }

    func testAllowDenyPatterns() {
        let p = EgressPolicy(allow: ["github.com", "*.apple.com"], deny: ["gist.github.com"])
        XCTAssertEqual(p.check(host: "github.com", port: 443), .allowed)
        XCTAssertEqual(p.check(host: "api.github.com", port: 443), .allowed)
        XCTAssertEqual(p.check(host: "www.apple.com.", port: 443), .allowed)
        XCTAssertNotEqual(p.check(host: "gist.github.com", port: 443), .allowed)
        XCTAssertNotEqual(p.check(host: "evilgithub.com", port: 443), .allowed)
        XCTAssertNotEqual(p.check(host: "example.com", port: 443), .allowed)
        XCTAssertNotEqual(EgressPolicy(enabled: false).check(host: "example.com", port: 443), .allowed)
    }
}

final class EgressPolicyDecodingTests: XCTestCase {
    func testPartialJSONUsesDefaults() throws {
        let p = try JSONDecoder().decode(EgressPolicy.self, from: Data(#"{"enabled": false}"#.utf8))
        XCTAssertFalse(p.enabled)
        XCTAssertEqual(p.ports, [80, 443])
        let q = try JSONDecoder().decode(EgressPolicy.self, from: Data(#"{"allow": ["github.com"]}"#.utf8))
        XCTAssertTrue(q.enabled)
        XCTAssertEqual(q.allow, ["github.com"])
    }
}

final class DeadEndLANTests: XCTestCase {
    let guestMAC: [UInt8] = [0x02, 0, 0, 0, 0, 1]

    func frame(_ type: UInt16, _ payload: [UInt8]) -> [UInt8] {
        [0xff, 0xff, 0xff, 0xff, 0xff, 0xff] + guestMAC + [UInt8(type >> 8), UInt8(type & 0xff)] + payload
    }

    func testARPRequestForGatewayIsAnswered() {
        let req: [UInt8] = [0, 1, 8, 0, 6, 4, 0, 1] + guestMAC + GuestLAN.guestIP + [0, 0, 0, 0, 0, 0] + GuestLAN.gatewayIP
        let out = DeadEndLAN.respond(to: frame(0x0806, req))
        XCTAssertEqual(out.count, 1)
        let r = out[0]
        XCTAssertEqual(Array(r[0..<6]), guestMAC)
        XCTAssertEqual(r[21], 2) // ARP reply
        XCTAssertEqual(Array(r[22..<28]), GuestLAN.gatewayMAC)
        XCTAssertEqual(Array(r[28..<32]), GuestLAN.gatewayIP)
    }

    func testGratuitousARPIgnored() {
        let req: [UInt8] = [0, 1, 8, 0, 6, 4, 0, 1] + guestMAC + GuestLAN.guestIP + [0, 0, 0, 0, 0, 0] + GuestLAN.guestIP
        XCTAssertTrue(DeadEndLAN.respond(to: frame(0x0806, req)).isEmpty)
    }

    func testTCPSynGetsValidReset() {
        var tcp = [UInt8](repeating: 0, count: 20)
        tcp[0] = 0xc0; tcp[1] = 0x00      // src port 49152
        tcp[2] = 0x01; tcp[3] = 0xbb      // dst port 443
        DeadEndLAN.put32(&tcp, 4, 1000)
        tcp[12] = 5 << 4
        tcp[13] = 0x02                    // SYN
        let dst: [UInt8] = [1, 1, 1, 1]
        let ip = DeadEndLAN.ipv4(src: GuestLAN.guestIP, dst: dst, proto: 6, tcp)
        let out = DeadEndLAN.respond(to: frame(0x0800, ip))
        XCTAssertEqual(out.count, 1)
        let r = Array(out[0][14...])
        XCTAssertEqual(DeadEndLAN.checksum(Array(r[0..<20])), 0) // IP header checksum valid
        XCTAssertEqual(Array(r[12..<16]), dst)
        XCTAssertEqual(Array(r[16..<20]), GuestLAN.guestIP)
        let t = Array(r[20...])
        XCTAssertEqual(t[13], 0x14)                       // RST|ACK
        XCTAssertEqual(DeadEndLAN.be32(t, 8), 1001)       // acks the SYN
        XCTAssertEqual(Array(t[0..<4]), [0x01, 0xbb, 0xc0, 0x00])
        let pseudo = dst + GuestLAN.guestIP + [0, 6, 0, 20]
        XCTAssertEqual(DeadEndLAN.checksum(pseudo + t), 0) // TCP checksum valid
    }

    func testResetIsNeverAnswered() {
        var tcp = [UInt8](repeating: 0, count: 20)
        tcp[12] = 5 << 4; tcp[13] = 0x04
        let ip = DeadEndLAN.ipv4(src: GuestLAN.guestIP, dst: [1, 1, 1, 1], proto: 6, tcp)
        XCTAssertTrue(DeadEndLAN.respond(to: frame(0x0800, ip)).isEmpty)
    }

    func testUDPGetsPortUnreachableButBroadcastIsIgnored() {
        let udp: [UInt8] = [0xc0, 0, 0, 53, 0, 8, 0, 0]
        let unicast = DeadEndLAN.ipv4(src: GuestLAN.guestIP, dst: [8, 8, 8, 8], proto: 17, udp)
        let out = DeadEndLAN.respond(to: frame(0x0800, unicast))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0][14 + 9], 1)  // ICMP
        XCTAssertEqual(out[0][14 + 20], 3) // destination unreachable
        let bcast = DeadEndLAN.ipv4(src: [0, 0, 0, 0], dst: [255, 255, 255, 255], proto: 17, udp)
        XCTAssertTrue(DeadEndLAN.respond(to: frame(0x0800, bcast)).isEmpty)
    }
}
