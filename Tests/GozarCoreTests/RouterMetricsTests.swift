import GozarCore
import Testing

@Test(arguments: [
    ("a.b.example.com", "example.com"), ("www.bbc.co.uk", "bbc.co.uk"),
    ("www.ut.ac.ir", "ut.ac.ir"), ("a.shop.com.au", "shop.com.au"),
    ("a.example.net.nz", "example.net.nz"), ("x.foo.org.uk", "foo.org.uk"),
    ("abc.dept.gov.uk", "dept.gov.uk"), ("www.uni.edu.au", "uni.edu.au"),
    ("foo.example.ir", "example.ir"), ("api.CLAUDE.AI.", "claude.ai"),
    ("localhost", "localhost"), ("CORP-MGMT01", "corp-mgmt01"),
    ("192.0.2.1", "192.0.2.1"), ("2001:DB8::1", "2001:DB8::1"),
    ("::ffff:192.0.2.1", "::ffff:192.0.2.1"), ("co.uk", "co.uk"),
    ("foo.co.biz", "co.biz"), ("foo.example.12", "example.12"),
])
func routerRegistrableDomain(host: String, expected: String) {
    #expect(registrableDomain(host) == expected)
}

@Test func routerProbeMedianLossAndRetention() {
    var history = ProbeHistory()
    func snapshot() -> ProbeStat { history.stat(name: "tunnel", target: "1.1.1.1:443") }
    #expect(snapshot() == ProbeStat(name: "tunnel", target: "1.1.1.1:443", loss: 0, samples: 0))
    history.record(.latency(20))
    history.record(.failure("Connection refused"))
    #expect(snapshot().lastError == "Connection refused")
    #expect(snapshot().lastMs == nil)
    #expect(snapshot().medianMs == 20)
    #expect(snapshot().loss == 0.5)
    history.record(.latency(10))
    #expect(snapshot().lastMs == 10)
    #expect(snapshot().lastError == nil)
    #expect(snapshot().medianMs == 15)
    history.record(.latency(50))
    history.record(.latency(5000.01))
    #expect(snapshot().samples == 5)
    #expect(snapshot().medianMs == 20)
    #expect(snapshot().loss == 0.4)
    #expect(snapshot().lastError == "Timed out")
    for _ in 1...30 { history.record(.latency(5)) }
    #expect(snapshot().samples == 30)
    #expect(snapshot().medianMs == 5)
    #expect(snapshot().loss == 0)
}
