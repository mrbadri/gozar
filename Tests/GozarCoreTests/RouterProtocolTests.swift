import Foundation
import GozarCore
import Testing

@Test func routerSOCKS5Greeting() {
    #expect(SocksWire.greeting([5]) == .need(2))
    #expect(SocksWire.greeting([5, 2, 2]) == .need(4))
    #expect(SocksWire.greeting([5, 2, 2, 0]) == .value(0))
    #expect(SocksWire.greeting([6, 1, 0]) == .reject(0xff))
    #expect(SocksWire.greeting([5, 1, 2]) == .reject(0xff))
    #expect(SocksWire.greeting([5, 0]) == .reject(0xff))
}

@Test func routerSOCKS5Connect() {
    let headers: [UInt8] = [5, 1, 0, 3]
    let domain = [UInt8]("vpn.test".utf8)
    #expect(SocksWire.request(headers) == .need(5))
    #expect(SocksWire.request(headers + [8] + domain) == .need(15))
    #expect(SocksWire.request(headers + [8] + domain + [1, 187]) == .value(.init(host: "vpn.test", port: 443)))
    #expect(SocksWire.request([5, 1, 0, 1, 192, 0, 2, 3, 0, 80]) == .value(.init(host: "192.0.2.3", port: 80)))
    let ipv6: [UInt8] = [5, 1, 0, 4, 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 187]
    #expect(SocksWire.request(ipv6) == .value(.init(host: "2001:db8::1", port: 443)))
    #expect(SocksWire.request([6, 1, 0, 1]) == .reject(1))
    #expect(SocksWire.request([5, 2, 0, 1]) == .reject(7))
    #expect(SocksWire.request([5, 3, 0, 1]) == .reject(7))
    #expect(SocksWire.request([5, 1, 0, 9]) == .reject(8))
    #expect(SocksWire.request([5, 1, 0, 3, 1, 10, 0, 80]) == .reject(8))
}

@Test func routerSOCKS4aConnect() {
    let request: [UInt8] = [4, 1, 1, 187, 0, 0, 0, 1] + [UInt8]("user".utf8) + [0] + [UInt8]("vpn.test".utf8)
    #expect(SocksWire.request4(request) == .need(request.count + 1))
    #expect(SocksWire.request4(request + [0, 1, 2]) == .value(.init(host: "vpn.test", port: 443)))
    #expect(SocksWire.request4([4, 1, 0, 80, 127, 0, 0, 1, 0]) == .value(.init(host: "127.0.0.1", port: 80)))
    #expect(SocksWire.request4([4, 2]) == .reject(0x5b))
    #expect(SocksWire.request4([4, 1, 1, 187, 0, 0, 0, 1, 0, 0]) == .reject(0x5b))
    #expect(SocksWire.request4([4, 1, 1, 187, 0, 0, 0, 1] + [UInt8](repeating: 65, count: 256)) == .reject(0x5b))
    #expect(SocksWire.reply(.four, code: 0) == Data([0, 0x5a, 0, 0, 0, 0, 0, 0]))
}

@Test func routerUpstreamUsesDomainAddress() throws {
    let ipv6 = try #require(SocksWire.upstreamRequest(.init(host: "2001:db8::1", port: 443)))
    #expect(Array(ipv6.prefix(5)) == [5, 1, 0, 3, 11])
    #expect(String(decoding: ipv6.dropFirst(5).dropLast(2), as: UTF8.self) == "2001:db8::1")
    #expect(Array(ipv6.suffix(2)) == [1, 187])
    #expect(SocksWire.upstreamReply([5, 0, 0, 3, 2, 97, 98, 0, 80]) == .value(0))
    #expect(SocksWire.upstreamReply([5, 0, 0, 4]) == .need(22))
    #expect(SocksWire.upstreamReply([5, 5, 0, 1]) == .reject(5))
}

@Test func routerHTTPRequestAndAuthorization() throws {
    func parse(_ request: String) -> RouterHTTPRequest? { RouterHTTPRequest(Data(request.utf8)) }
    let token = String(repeating: "a", count: 64)
    let request = try #require(parse("GET /v1/check?host=api%2Eexample.com&limit=1 HTTP/1.1\r\nHost: localhost\r\n"
        + "aUtHoRiZaTiOn:\t bEaReR \(token) \t\r\n\r\n"))
    #expect(request.method == "GET")
    #expect(request.path == "/v1/check")
    #expect(request.parameter("host") == "api.example.com")
    #expect(request.parameter("limit") == "1")
    #expect(request.parameter("window") == nil)
    #expect(request.isAuthorized(token: token))
    #expect(!request.isAuthorized(token: token.dropLast() + "b"))
    #expect(!request.isAuthorized(token: "a"))
    let reload = try #require(parse("POST /v1/reload HTTP/1.1\r\nContent-Length: 0\r\n\r\n"))
    #expect(reload.method == "POST")
    #expect(!reload.hasBody)
    #expect(!reload.isAuthorized(token: token))
    #expect(parse("POST /v1/reload HTTP/1.1\r\nContent-Length: 2\r\n\r\n")?.hasBody == true)
    #expect(parse("POST /v1/reload HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")?.hasBody == true)
    #expect(parse("POST /v1/reload HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == nil)
    let wrongScheme = try #require(parse("GET / HTTP/1.1\r\nAuthorization: Basic \(token)\r\n\r\n"))
    #expect(!wrongScheme.isAuthorized(token: token))
    #expect(parse("GET / HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nAuthorization: Bearer other\r\n\r\n") == nil)
    #expect(parse("GET / HTTP/1.1\r\n malformed header\r\n\r\n") == nil)
    #expect(parse("GET / HTTP/1.1\r\n") == nil)
    #expect(parse("GET http://localhost/v1/status HTTP/1.1\r\n\r\n") == nil)
    #expect(parse("GET / HTTP/1.1\r\nHost: \(String(repeating: "a", count: RouterHTTPRequest.maxHeadBytes))\r\n\r\n") == nil)
}
