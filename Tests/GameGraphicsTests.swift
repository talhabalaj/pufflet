import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SteamLibrary

struct GameGraphicsTests {
    @Test func toolkitAliasesHaveOneRendererIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-toolkit-alias-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let toolkit = root.appendingPathComponent("toolkit"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: toolkit, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: toolkit)
        let direct = try #require(D3DMetalInstallation.find(in: toolkit, fileExists: { _ in true }))
        let linked = try #require(D3DMetalInstallation.find(in: alias, fileExists: { _ in true }))
        #expect(direct == linked)
        #expect(linked.library.path == toolkit.resolvingSymlinksInPath().path)
        #expect(D3DMetalInstallation(library: alias) == direct)
        #expect(D3DMetalInstallation(library: root.appendingPathComponent("different-copy")) != direct)
    }

    @Test func backendSelection() {
        #expect(GraphicsBackend.auto.resolved(requiresD3D12: true, hasD3DMetal: true) == .d3dMetal)
        #expect(GraphicsBackend.auto.resolved(requiresD3D12: true, hasD3DMetal: false) == .dxmt)
        #expect(GraphicsBackend.auto.resolved(requiresD3D12: false, hasD3DMetal: true) == .dxmt)
        #expect(GraphicsBackend.dxmt.resolved(requiresD3D12: true, hasD3DMetal: true) == .dxmt)
        #expect(GraphicsBackend.d3dMetal.resolved(requiresD3D12: false, hasD3DMetal: false) == .d3dMetal)
    }

    @Test(arguments: [false, true]) func importsAndDelayImports(_ delay: Bool) {
        for pe64 in [false, true] {
            let data = fixture(pe64: pe64, delay: delay)
            #expect(PEImports.libraries(in: data) == ["d3d12.dll"])
            for end in [0, 1, 63, 150, 400, 535] {
                #expect(PEImports.libraries(in: Data(data.prefix(end))).isEmpty)
            }
            var broken = data
            broken[0x3c] = 0xff; broken[0x3d] = 0xff; broken[0x3e] = 0xff; broken[0x3f] = 0xff
            #expect(PEImports.libraries(in: broken).isEmpty)
        }
    }

    @Test func autoUsesD3DMetalOnlyWhenDirectX12IsTheOnlyRenderer() {
        #expect(PEImports.requiresD3D12(["d3d12.dll", "dxgi.dll", "kernel32.dll"]))
        #expect(PEImports.requiresD3D12(["d3d12core.dll"]))
        // Unity's player and many Unreal builds import both and run D3D11 by default.
        #expect(!PEImports.requiresD3D12(["d3d11.dll", "d3d12.dll", "dxgi.dll"]))
        #expect(!PEImports.requiresD3D12(["d3d10_1.dll", "d3d12.dll"]))
        #expect(!PEImports.requiresD3D12(["d3d11.dll", "dxgi.dll"]))
        #expect(!PEImports.requiresD3D12(["dxgi.dll"]))
        #expect(!PEImports.requiresD3D12([]))
    }

    @Test func rendererImportsIncludeTheLaunchersOwnEngineLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-pe-imports-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("Game.exe"), engine = root.appendingPathComponent("UnityPlayer.dll")
        // Imports are lowercase while the file on disk keeps its case, as on Windows.
        try fixture(pe64: true, delay: false, libraries: ["UnityPlayer.dll", "KERNEL32.dll"]).write(to: launcher)
        try fixture(pe64: true, delay: true, libraries: ["d3d11.dll", "D3D12.dll", "dxgi.dll"]).write(to: engine)
        #expect(PEImports.rendererLibraries(at: launcher) == ["unityplayer.dll", "kernel32.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"])
        #expect(!PEImports.requiresD3D12(at: launcher))
        try fixture(pe64: true, delay: false, libraries: ["d3d12.dll", "dxgi.dll"]).write(to: engine)
        #expect(PEImports.requiresD3D12(at: launcher))
        // A missing or unreadable sibling only leaves the launcher's own imports.
        try FileManager.default.removeItem(at: engine)
        #expect(PEImports.rendererLibraries(at: launcher) == ["unityplayer.dll", "kernel32.dll"])
    }

    private func fixture(pe64: Bool, delay: Bool, libraries: [String] = ["D3D12.DLL"]) -> Data {
        var data = Data(repeating: 0, count: 1024)
        func put(_ value: UInt32, at offset: Int, count: Int = 4) {
            for index in 0..<count { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        put(0x5a4d, at: 0, count: 2); put(0x80, at: 0x3c); put(0x4550, at: 0x80)
        put(1, at: 0x86, count: 2); put(240, at: 0x94, count: 2)
        put(pe64 ? 0x20b : 0x10b, at: 0x98, count: 2)
        let directory = 0x98 + (pe64 ? 112 : 96) + (delay ? 13 : 1) * 8
        let stride = delay ? 32 : 20
        put(0x1000, at: directory); put(UInt32((libraries.count + 1) * stride), at: directory + 4)
        let section = 0x98 + 240
        put(0x1000, at: section + 12); put(512, at: section + 16); put(512, at: section + 20)
        for (index, library) in libraries.enumerated() {
            let descriptor = 512 + index * stride, name = 640 + index * 24
            if delay { put(1, at: descriptor) }
            put(UInt32(0x1000 + name - 512), at: descriptor + (delay ? 4 : 12))
            data.replaceSubrange(name..<(name + library.utf8.count + 1), with: Data((library + "\0").utf8))
        }
        return data
    }

    @Test func requiresCompleteToolkitAndPreservesBaseEnvironment() {
        let root = URL(filePath: "/tmp/gptk-fixture")
        let installation = D3DMetalInstallation.find(in: root) { path in
            path.contains("/redist/lib/")
        }
        #expect(installation?.library == root.appendingPathComponent("redist/lib"))
        #expect(D3DMetalInstallation.find(in: root) { !$0.hasSuffix("d3d12.so") } == nil)
        let base = ["WINEDLLPATH_DXMT": "dxmt", "WINEDLLPATH_PREPEND": "dxmt", "DYLD_FALLBACK_LIBRARY_PATH": "wine", "WINEPREFIX": "fixture"]
        let env = installation?.environment(over: base)
        #expect(env?["WINEPREFIX"] == "fixture")
        #expect(env?["WINEDLLPATH_DXMT"] == nil)
        #expect(env?["WINEDLLPATH_PREPEND"] == "/tmp/gptk-fixture/redist/lib/wine")
        #expect(env?["DYLD_FALLBACK_LIBRARY_PATH"] == "/tmp/gptk-fixture/redist/lib/external:wine")
        #expect(base["WINEDLLPATH_DXMT"] == "dxmt")
    }

    @Test @MainActor func preferencesArePerGameAndSkipDoesNotChooseBackend() throws {
        let name = "GameGraphicsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let support = GraphicsSupport(defaults: defaults)
        support.setBackend(.d3dMetal, for: "10"); support.skip()
        let restored = GraphicsSupport(defaults: defaults)
        #expect(restored.backend(for: "10") == .d3dMetal)
        #expect(restored.backend(for: "20") == .auto)
        #expect(restored.skipped)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PUFFLET_D3DMETAL_SAMPLE"] != nil))
    @MainActor func offlineD3D12Sample() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(filePath: try #require(env["PUFFLET_D3DMETAL_OUTPUT"]))
        guard root.path.hasPrefix("/tmp/pufflet-d3dmetal-") || root.path.hasPrefix("/private/tmp/pufflet-d3dmetal-") else { throw SteamError.invalidMessage }
        let sample = URL(filePath: try #require(env["PUFFLET_D3DMETAL_SAMPLE"]))
        let toolkitPath = try #require(env["PUFFLET_D3DMETAL_TOOLKIT"])
        let toolkit = try #require(D3DMetalInstallation.find(in: URL(filePath: toolkitPath)))
        #expect(PEImports.requiresD3D12(at: sample))
        let paths = SteamClientPaths(support: root)
        try FileManager.default.createDirectory(at: paths.prefix, withIntermediateDirectories: true)
        var runtime = SteamRuntime(installation: SteamInstallation(prefix: paths.prefix,
            runtime: URL(filePath: try #require(env["PUFFLET_D3DMETAL_RUNTIME"]))),
            dockBridge: try #require(Bundle.main.url(forResource: "libSteamLibraryDock", withExtension: "dylib")),
            logDirectory: root.appendingPathComponent("Logs"))
        let capture = root.appendingPathComponent("frame.bmp")
        func cleanup() async throws {
            // Use the same bounded graceful/soft stop and exact-prefix client
            // cleanup as the app, including on sample failure or cancellation.
            try await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix)
        }
        do {
            try await runtime.runWindows(["cmd", "/c", "ver"])
            runtime.d3dMetal = toolkit
            let process = try runtime.startWindows([sample.path, SteamHeadlessSession.windowsHandoffPath(capture), "capture-only"],
                extraEnvironment: ["DYLD_PRINT_LIBRARIES": "1", "WINEDEBUG": "+loaddll"])
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard !process.isRunning else {
                process.terminate()
                throw SteamRuntime.RuntimeError.launchFailed("The offline D3D12 sample timed out.")
            }
            #expect(process.terminationStatus == 0)
            #expect(FileManager.default.fileExists(atPath: capture.path))
            let log = try String(contentsOf: root.appendingPathComponent("Logs/wine.log"), encoding: .utf8)
            #expect(log.contains("GPU fence + pixel readback=success"))
            #expect(log.contains("D3DMetal.framework/Versions/A/D3DMetal"))
            // Prove that the actual mapped PE image matches the user-provided
            // Apple DLL, rather than relying on framework load alone.
            let apple = try Data(contentsOf: toolkit.library.appendingPathComponent("wine/x86_64-windows/d3d12.dll"))
            func u32(_ offset: Int) -> UInt32 {
                apple.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            }
            let pe = Int(u32(0x3c))
            #expect(log.contains("d3d12 image size=\(u32(pe + 24 + 56)) timestamp=\(u32(pe + 8))"))
            try await cleanup()
        } catch {
            try? await cleanup()
            throw error
        }
    }

    /// Opt-in native screenshots and live detection check; no account or real prefix.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PUFFLET_GRAPHICS_UI_ROOT"] != nil))
    @MainActor func nativeSetupScreenshots() async throws {
        let root = URL(filePath: try #require(ProcessInfo.processInfo.environment["PUFFLET_GRAPHICS_UI_ROOT"]))
        guard root.path.hasPrefix("/tmp/pufflet-graphics-ui-") || root.path.hasPrefix("/private/tmp/pufflet-graphics-ui-") else { throw SteamError.invalidMessage }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "GraphicsUI." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // A configured path that appears later exercises the same poll as a user
        // mounting/copying GPTK while the setup UI is visible.
        let toolkit = root.appendingPathComponent("toolkit/lib")
        defaults.set(toolkit.path, forKey: "gptkLibraryPath")
        let support = GraphicsSupport(defaults: defaults)
        let paths = SteamClientPaths(support: root)
        let settings = LibrarySettings(defaults: defaults, support: root, home: root)
        let model = LibraryModel(settings: settings, headless: SteamHeadlessSession(paths: paths),
            ownedLibrary: SteamOwnedLibrary(cache: root.appendingPathComponent("Owned")),
            downloads: SteamDownloadQueue(root: root.appendingPathComponent("Queue")), paths: paths, graphics: support)
        func capture<V: View>(_ view: V, name: String) async throws {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            // Swift owns this fixture window through the deferred close.
            window.isReleasedWhenClosed = false
            window.title = "Pufflet — Graphics setup"; window.contentView = host
            window.center(); window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try Data(name.utf8).write(to: root.appendingPathComponent("stage.txt"), options: .atomic)
            if ProcessInfo.processInfo.environment["PUFFLET_GRAPHICS_UI_HOLD"] == "1" {
                try await Task.sleep(for: .seconds(30))
            }
            try await Task.sleep(for: .milliseconds(700))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
        }
        try await capture(RuntimeOnboardingView(model: model), name: "onboarding")
        try await capture(GamePortingToolkitSetup(support: support), name: "toolkit-missing")
        #expect(support.installation == nil)
        // Directory validation fixtures contain no executable code.
        for relative in ["wine/x86_64-windows/d3d12.dll", "wine/x86_64-windows/d3d11.dll", "wine/x86_64-windows/dxgi.dll",
                         "wine/x86_64-unix/d3d12.so", "wine/x86_64-unix/d3d11.so", "wine/x86_64-unix/dxgi.so",
                         "external/libd3dshared.dylib", "external/D3DMetal.framework/D3DMetal"] {
            let file = toolkit.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        try await capture(GamePortingToolkitSetup(support: support), name: "toolkit-detected")
        #expect(support.installation?.library.path == toolkit.path)
        support.skip()
        #expect(support.backend(for: "10") == .auto)
    }
}
