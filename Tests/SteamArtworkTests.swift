import AppKit
import SwiftUI
import Foundation
import Testing
@testable import SteamLibrary

struct SteamArtworkTests {
    @MainActor @Test(arguments: [CGSize(width: 460, height: 215), CGSize(width: 600, height: 900), CGSize(width: 300, height: 300)])
    func coverLayoutStaysPortraitRegardlessOfSourceSize(_ size: CGSize) throws {
        let artwork = NSImage(size: size, flipped: false) { bounds in
            NSColor.red.setFill()
            bounds.fill()
            return true
        }
        let renderer = ImageRenderer(content: GameCoverArtwork(artwork: artwork))
        renderer.proposedSize = ProposedViewSize(width: 140, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == 140)
        #expect(image.size.height == 210)
    }

    @Test func resolvesHashedPortraitArtForRequestedApp() throws {
        let json = #"""
        {"response":{"store_items":[
          {"appid":10,"assets":{"asset_url_format":"steam/apps/10/${FILENAME}?t=123","library_capsule":"hash-a/library_600x900.jpg","library_capsule_2x":"hash-b/library_600x900_2x.jpg","library_hero":"hash-c/library_hero.jpg","last_modified":123}},
          {"appid":20,"assets":{"asset_url_format":"steam/apps/20/${FILENAME}","library_capsule":"other.jpg"}}
        ]}}
        """#
        let response = try JSONDecoder().decode(SteamAssetsResponse.self, from: Data(json.utf8))
        #expect(response.assetURL(for: "10", kind: .cover)?.absoluteString == "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/10/hash-b/library_600x900_2x.jpg?t=123")
        #expect(response.assetURL(for: "10", kind: .hero)?.lastPathComponent == "library_hero.jpg")
        #expect(response.assetURL(for: "30", kind: .cover) == nil)
    }

    @Test func coverFallsBackToHeaderForOnlyTheRequestedApp() throws {
        let json = #"""
        {"response":{"store_items":[
          {"appid":10,"assets":{"asset_url_format":"steam/apps/10/${FILENAME}","library_capsule":"portrait.jpg"}},
          {"appid":20,"assets":{"asset_url_format":"steam/apps/20/${FILENAME}","header":"header.jpg","header_2x":"header_2x.jpg"}}
        ]}}
        """#
        let response = try JSONDecoder().decode(SteamAssetsResponse.self, from: Data(json.utf8))
        #expect(response.assetURL(for: "20", kind: .cover)?.absoluteString == "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/20/header_2x.jpg")
        #expect(response.assetURL(for: "30", kind: .cover) == nil)
    }

    @Test func refusesUnrelatedArtworkHost() throws {
        let json = #"{"response":{"store_items":[{"appid":10,"assets":{"asset_url_format":"https://example.org/${FILENAME}","library_capsule":"cover.jpg"}}]}}"#
        let response = try JSONDecoder().decode(SteamAssetsResponse.self, from: Data(json.utf8))
        #expect(response.assetURL(for: "10", kind: .cover) == nil)
    }

    @Test func onlyNumericHostReportFieldsReachUI() {
        let data = Data("[steam-host] ml1830 session-authenticated-online=1\n[steam-host] ml1830 account=private\n[steam-host] ml1830 probe-result=35\n[steam-host] ml1830 launch-client-error=unfinished".utf8)
        let report = SteamHostReport.parse(data)
        #expect(report.fields == ["session-authenticated-online":1, "probe-result":35])
        #expect(report.failure(for: 35).contains("owns"))
    }

    @Test(arguments: ["../escape", "C:/escape", "folder/../escape", "folder//file", "folder/file."])
    func rejectsInvalidClientArchivePaths(_ path: String) {
        #expect(!SteamClientPackages.validPath(path))
    }
}
