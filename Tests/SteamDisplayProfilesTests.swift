import AppKit
import SwiftUI
import Foundation
import Testing
@testable import SteamLibrary

struct SteamDisplayProfilesTests {
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["PUFFLET_DISPLAY_UI_PREVIEW"] != nil))
    func displayPickerPreview() async throws {
        let content = Form { GameDisplaySettings(selection: .constant(.highResolution)) }
            .formStyle(.grouped).frame(width: 360, height: 280)
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 280), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Isolated display settings preview"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: URL(filePath: "/tmp/pufflet-display-profile-ui.png"))
    }

    private func fixture() -> SteamDisplayProfiles {
        .init(paths: .init(support: FileManager.default.temporaryDirectory.appendingPathComponent("display-profiles-" + UUID().uuidString)))
    }
    @Test func choicesAreDurablePerGameAndDoNotProvisionAPrefix() throws {
        let profiles = fixture(); defer { try? FileManager.default.removeItem(at: profiles.paths.support) }
        #expect(try profiles.preference(for: "1") == .automatic)
        #expect(!FileManager.default.fileExists(atPath: profiles.preferencesURL.path))
        try profiles.set(.highResolution, for: "1")
        try profiles.set(.standard192, for: "2")
        #expect(!FileManager.default.fileExists(atPath: profiles.paths.prefix.path))
        let relaunched = SteamDisplayProfiles(paths: profiles.paths)
        #expect(try relaunched.preference(for: "1") == .highResolution)
        #expect(try relaunched.preference(for: "2") == .standard192)
        try profiles.set(.inherit, for: "1")
        #expect(try relaunched.preference(for: "1") == .inherit)
        #expect(try relaunched.preference(for: "2") == .standard192)
        try profiles.set(.automatic, for: "1")
        #expect(try relaunched.preference(for: "1") == .automatic)
        #expect(throws: (any Error).self) { try profiles.set(.standard, for: "../game") }
    }
    @Test func inheritancePreservesUnusualValuesAcrossSwitchesAndRelaunch() throws {
        let profiles = fixture(); defer { try? FileManager.default.removeItem(at: profiles.paths.support) }
        try FileManager.default.createDirectory(at: profiles.paths.prefix, withIntermediateDirectories: true)
        let legacy = SteamDisplayConfiguration(retinaValue: "custom value", dpi: 144)
        #expect(try profiles.target(for: .inherit, observed: legacy) == nil)
        #expect(!FileManager.default.fileExists(atPath: profiles.baselineURL.path))
        #expect(try profiles.target(for: .standard, observed: legacy) == .init(retinaValue: "n", dpi: 96))
        let relaunched = SteamDisplayProfiles(paths: profiles.paths)
        _ = try relaunched.target(for: .highResolution, observed: .init(retinaValue: "n", dpi: 96))
        #expect(try relaunched.target(for: .inherit, observed: .init(retinaValue: "y", dpi: 96)) == legacy)
    }
    @Test func absentAndEmptyRegistryValuesRemainDistinct() throws {
        let profiles = fixture(); defer { try? FileManager.default.removeItem(at: profiles.paths.support) }
        try FileManager.default.createDirectory(at: profiles.paths.prefix, withIntermediateDirectories: true)
        let missing = SteamDisplayConfiguration(retinaValue: nil, dpi: nil)
        _ = try profiles.target(for: .standard, observed: missing)
        #expect(try profiles.target(for: .inherit, observed: .init(retinaValue: "y", dpi: 192)) == missing)
        let empty = SteamDisplayConfiguration(retinaQuery: "RetinaMode    REG_SZ    ", dpiQuery: "")
        #expect(empty.retinaValue == "")
        #expect(empty != missing)
        #expect(SteamDisplayConfiguration(retinaQuery: "    RetinaMode    REG_SZ      custom  ", dpiQuery: "").retinaValue == "  custom  ")
    }
    @Test func corruptBaselineAndUnwritablePreferencesFailClosed() throws {
        let profiles = fixture(); defer { try? FileManager.default.removeItem(at: profiles.paths.support) }
        try FileManager.default.createDirectory(at: profiles.paths.prefix, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: profiles.baselineURL)
        #expect(throws: (any Error).self) { try profiles.target(for: .standard, observed: .init(retinaValue: "y", dpi: 96)) }
        try Data().write(to: profiles.preferencesURL.deletingLastPathComponent())
        #expect(throws: (any Error).self) { try profiles.set(.standard, for: "1") }
        #expect(try profiles.preference(for: "1") == .automatic)
    }
    @Test func fallbackRejectsEveryExplicitChoice() throws {
        let profiles = fixture(); defer { try? FileManager.default.removeItem(at: profiles.paths.support) }
        try profiles.requireFallbackSupport(for: "1")
        try profiles.set(.inherit, for: "1")
        try profiles.requireFallbackSupport(for: "1")
        for choice in SteamDisplayPreference.allCases where ![.automatic, .inherit].contains(choice) {
            try profiles.set(choice, for: "1")
            #expect(throws: SteamDisplayProfiles.Failure.self) { try profiles.requireFallbackSupport(for: "1") }
        }
        try Data("broken".utf8).write(to: profiles.preferencesURL)
        #expect(throws: (any Error).self) { try profiles.requireFallbackSupport(for: "1") }
    }

    @Test func automaticFollowsTheExecutablesDPIAwareness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-auto-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func game(_ name: String, _ settings: String?) throws -> URL {
            let url = root.appendingPathComponent(name)
            try PEFixture.executable(settings.map { [PEFixture.manifest($0)] } ?? []).write(to: url)
            return url
        }
        let aware = try game("aware.exe", #"<dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">True/PM</dpiAware>"#)
        let unaware = try game("unaware.exe", nil)
        #expect(SteamDisplayPreference.automatic.resolved(for: aware) == .highResolution192)
        #expect(SteamDisplayPreference.automatic.resolved(for: unaware) == .standard)
        #expect(SteamDisplayPreference.automatic.resolved(for: nil) == .inherit)
        #expect(SteamDisplayPreference.standard.resolved(for: aware) == .standard)
        #expect(SteamDisplayPreference.inherit.resolved(for: aware) == .inherit)
    }

    @Test func manifestDPIAwarenessFollowsWindowsRules() {
        func aware(_ settings: String) -> Bool { PEManifest.isDPIAware(PEFixture.executable([PEFixture.manifest(settings)])) }
        #expect(aware("<dpiAware>true</dpiAware>"))
        #expect(aware("<dpiAware>True/PM</dpiAware>"))
        #expect(aware("<dpiAware>per monitor</dpiAware>"))
        #expect(aware("<ws2:dpiAwareness>PerMonitorV2, PerMonitor</ws2:dpiAwareness>"))
        #expect(aware("<dpiAwareness>system</dpiAwareness>"))
        #expect(!aware("<dpiAware>false</dpiAware>"))
        #expect(!aware("<gdiScaling>true</gdiScaling>"))
        // dpiAwareness overrides dpiAware, as on Windows 10.
        #expect(!aware("<dpiAware>true</dpiAware><dpiAwareness>unaware</dpiAwareness>"))
        #expect(!PEManifest.isDPIAware(PEFixture.executable([])))
        #expect(!PEManifest.isDPIAware(Data("not a PE file".utf8)))
    }
}
