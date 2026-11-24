import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import GozarCore

@Test func appDecodesExitAndSubscriptionLists() throws {
    let payload = Data("""
    {
      "active": "x7f3a9c",
      "exits": [
        {"id":"relay","name":"سرور اصلی","kind":"ssh","protocol":"ssh",
         "address":"relay.example.net","port":47853,"subscription":null,"stale":false},
        {"id":"x7f3a9c","name":"Frankfurt","kind":"xray","protocol":"vless",
         "address":"2001:db8::a","port":443,"subscription":"s1a2b3c","stale":true}
      ],
      "subscriptions": [
        {"id":"s1a2b3c","name":"Europe","host":"feed.example.net","count":1,
         "updated_at":"2026-11-24T06:00:00Z","error":null},
        {"id":"s000001","name":"Backup","host":"backup.example.net","count":0,
         "updated_at":null,"error":"Timed out"}
      ]
    }
    """.utf8)
    let decoder = JSONDecoder()
    let listing = try decoder.decode(ExitListing.self, from: payload)
    #expect(listing.exits.first?.transport == .ssh)
    #expect(listing.exits.first?.subscription == nil)
    #expect(listing.activeExit?.transport == .vless)
    #expect(listing.activeExit?.endpoint == "[2001:db8::a]:443")
    #expect(listing.activeExit?.stale == true)
    #expect(listing.activeExit?.subscription == listing.subscriptions.first?.id)
    #expect(listing.subscriptions.first?.host == "feed.example.net")
    #expect(listing.subscriptions.first?.updatedAt == "2026-11-24T06:00:00Z")
    #expect(listing.subscriptions.first?.count == 1)
    #expect(listing.subscriptions.last?.updatedAt == nil)
    #expect(listing.subscriptions.last?.error == "Timed out")

    let empty = try decoder.decode(ExitListing.self, from: Data(#"{"active":null,"exits":[],"subscriptions":[]}"#.utf8))
    #expect(empty == ExitListing())
}

@Test func appDecodesAndRanksExitTests() throws {
    let results = try JSONDecoder().decode([ExitTestResult].self, from: Data("""
    [
      {"id":"x000001","ok":true,"connect_ms":70,"mbps":21.4,"error":null},
      {"id":"x000002","ok":true,"connect_ms":45,"mbps":21.4,"error":null},
      {"id":"x000003","ok":false,"connect_ms":null,"mbps":null,"error":"Timed out"}
    ]
    """.utf8))
    #expect(ExitTestResult.best(in: results) == "x000002")
    #expect(results.last?.error == "Timed out")
    #expect(results.last?.connectMs == nil)
    #expect(ExitTestResult.best(in: results.filter { !$0.ok }) == nil)
}

@Test func appDecodesQRCodeFromGeneratedPNG() throws {
    let message = "vless://00000000-0000-4000-8000-000000000000@edge.example.net:443#Demo"
    let generator = CIFilter.qrCodeGenerator()
    generator.message = Data(message.utf8)
    generator.correctionLevel = "M"
    let code = try #require(generator.outputImage)
    let enlarged = code.transformed(by: .init(scaleX: 8, y: 8))
    let paper = CIImage(color: .white).cropped(to: enlarged.extent.insetBy(dx: -32, dy: -32))
    let padded = enlarged.composited(over: paper)
    let png = try #require(CIContext().pngRepresentation(of: padded, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
    let fixture = try #require(CIImage(data: png))
    #expect(QRCode.messages(in: fixture) == [message])
    #expect(QRCode.messages(in: paper).isEmpty)
}

@Test func appBuildsAddSiteCommands() throws {
    let url = "https://www.example.com/watch?t=90&mode=full"
    #expect(try AddSiteCommand(site: "  \(url)\n", route: .vpn) == .vpn(["set", "example.com", "vpn"]))
    #expect(try AddSiteCommand(site: "*.example.com", route: .direct) == .vpn(["set", "*.example.com", "direct"]))
    #expect(try AddSiteCommand(site: url, route: .cisco, rule: "Claude Team") ==
            .configuration(["add-to", "--", "Claude Team", "cisco", "example.com"]))
    #expect(try AddSiteCommand.address("https://www.example.com#chapter") == "example.com")
    #expect(throws: ConfigError.self) { try AddSiteCommand(site: "", route: .direct) }
    #expect(throws: ConfigError.self) { try AddSiteCommand(site: "--json", route: .direct) }
    #expect(throws: ConfigError.self) { try AddSiteCommand(site: "example.net example.com", route: .direct) }
}
