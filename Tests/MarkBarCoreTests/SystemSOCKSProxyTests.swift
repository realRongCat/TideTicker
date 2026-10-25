import Darwin
import Foundation
import XCTest
@testable import MarkBarCore

@MainActor
final class SystemSOCKSProxyTests: XCTestCase {
    func testSystemTransportUsesConfiguredSOCKSAndSurfacesProxyRejection() async throws {
        let proxy = try LocalSOCKSFixture.start()
        let configuration = URLSessionConfiguration.ephemeral
        // Session-local injection only. Production leaves this dictionary nil,
        // allowing macOS to select the user's configured proxy policy.
        configuration.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": proxy.port,
        ]
        configuration.waitsForConnectivity = false
        let client = SystemHTTPClient(configuration: configuration, deadline: 3)
        var transportRejected = false
        do {
            _ = try await client.get(hostname: "openapi.okx.com", path: "/api/v5/public/time")
            XCTFail("A rejected SOCKS CONNECT must not succeed via another route")
        } catch let error as SystemNetworkError {
            if case .transport = error {
                transportRejected = true
            } else {
                XCTFail("Expected the SOCKS rejection, received \(error)")
            }
        } catch {
            XCTFail("Unexpected proxy failure: \(error)")
        }
        await client.cancelAll()

        let connect = try await proxy.result.value
        XCTAssertTrue(transportRejected)
        XCTAssertEqual(connect.port, 443)
        if connect.addressType == 3 {
            XCTAssertEqual(connect.destination, "openapi.okx.com")
        }
        // This is a real localhost SOCKS handshake, not an HTTP URLProtocol
        // mock. The fixture rejects CONNECT and never opens an upstream socket;
        // it does not establish remote TLS or verify a user's actual proxy.
    }
}

private struct SOCKSConnect: Sendable {
    let addressType: UInt8
    let destination: String
    let port: UInt16
}

private enum SOCKSFixtureError: Error {
    case systemCall(String, Int32)
    case deadline
    case peerClosed
    case invalidProtocol(String)
}

private enum LocalSOCKSFixture {
    static func start() throws -> (port: Int, result: Task<SOCKSConnect, Error>) {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SOCKSFixtureError.systemCall("socket", errno) }
        do {
            try setNonblocking(listener)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw SOCKSFixtureError.systemCall("bind", errno) }
            guard Darwin.listen(listener, 1) == 0 else {
                throw SOCKSFixtureError.systemCall("listen", errno)
            }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(listener, $0, &size)
                }
            }
            guard named == 0 else { throw SOCKSFixtureError.systemCall("getsockname", errno) }
            let port = Int(UInt16(bigEndian: address.sin_port))
            let result = Task.detached { () throws -> SOCKSConnect in
                defer { Darwin.close(listener) }
                // All accept/read/write operations share this deadline. A
                // stalled or absent client cannot leave the test server alive.
                let deadline = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
                try wait(listener, for: Int16(POLLIN), until: deadline)
                let peer = Darwin.accept(listener, nil, nil)
                guard peer >= 0 else { throw SOCKSFixtureError.systemCall("accept", errno) }
                defer { Darwin.close(peer) }
                try setNonblocking(peer)
                var noSignal: Int32 = 1
                guard setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                                 socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw SOCKSFixtureError.systemCall("setsockopt", errno)
                }

                let greeting = try read(peer, count: 2, until: deadline)
                guard greeting[0] == 5, greeting[1] > 0 else {
                    throw SOCKSFixtureError.invalidProtocol("SOCKS5 greeting")
                }
                let methods = try read(peer, count: Int(greeting[1]), until: deadline)
                guard methods.contains(0) else {
                    throw SOCKSFixtureError.invalidProtocol("SOCKS no-auth method")
                }
                try write(peer, bytes: [5, 0], until: deadline)
                let header = try read(peer, count: 4, until: deadline)
                guard header[0] == 5, header[1] == 1, header[2] == 0 else {
                    throw SOCKSFixtureError.invalidProtocol("SOCKS5 CONNECT")
                }
                let destination: String
                switch header[3] {
                case 1:
                    destination = try read(peer, count: 4, until: deadline).map(String.init).joined(separator: ".")
                case 3:
                    let length = try read(peer, count: 1, until: deadline)[0]
                    guard length > 0 else { throw SOCKSFixtureError.invalidProtocol("empty destination") }
                    destination = String(decoding: try read(peer, count: Int(length), until: deadline), as: UTF8.self)
                case 4:
                    destination = try read(peer, count: 16, until: deadline).map { String($0, radix: 16) }.joined(separator: ":")
                default:
                    throw SOCKSFixtureError.invalidProtocol("destination address type")
                }
                let portBytes = try read(peer, count: 2, until: deadline)
                let target = SOCKSConnect(addressType: header[3], destination: destination,
                                          port: UInt16(portBytes[0]) << 8 | UInt16(portBytes[1]))
                // REP 2: connection not allowed. No upstream connection is made.
                try write(peer, bytes: [5, 2, 0, 1, 0, 0, 0, 0, 0, 0], until: deadline)
                return target
            }
            return (port, result)
        } catch {
            Darwin.close(listener)
            throw error
        }
    }

    private static func setNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SOCKSFixtureError.systemCall("fcntl", errno)
        }
    }

    private static func wait(_ descriptor: Int32, for events: Int16, until deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw SOCKSFixtureError.deadline }
            let milliseconds = Int32((deadline - now + 999_999) / 1_000_000)
            var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&descriptorState, 1, milliseconds)
            if result > 0 { return }
            if result == 0 { throw SOCKSFixtureError.deadline }
            if errno != EINTR { throw SOCKSFixtureError.systemCall("poll", errno) }
        }
    }

    private static func read(_ descriptor: Int32, count: Int, until deadline: UInt64) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try wait(descriptor, for: Int16(POLLIN), until: deadline)
            let received = bytes.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received > 0 { offset += received }
            else if received == 0 { throw SOCKSFixtureError.peerClosed }
            else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw SOCKSFixtureError.systemCall("recv", errno)
            }
        }
        return bytes
    }

    private static func write(_ descriptor: Int32, bytes: [UInt8], until deadline: UInt64) throws {
        var offset = 0
        while offset < bytes.count {
            try wait(descriptor, for: Int16(POLLOUT), until: deadline)
            let sent = bytes.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent > 0 { offset += sent }
            else if sent == 0 { throw SOCKSFixtureError.peerClosed }
            else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw SOCKSFixtureError.systemCall("send", errno)
            }
        }
    }
}
