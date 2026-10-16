import AppKit
import Observation
import SwiftUI

nonisolated enum GraphicsBackend: String, CaseIterable, Sendable {
    case auto, dxmt, d3dMetal

    var title: String {
        switch self { case .auto: "Auto"; case .dxmt: "DXMT"; case .d3dMetal: "D3DMetal" }
    }

    func resolved(importsD3D12: Bool, hasD3DMetal: Bool) -> Self {
        self == .auto ? (importsD3D12 && hasD3DMetal ? .d3dMetal : .dxmt) : self
    }
}

/// Reads PE import tables, never executes the game or scans its strings for API names.
/// Launchers and games that call LoadLibrary at runtime can require a manual choice.
nonisolated enum PEImports {
    static func usesD3D12(at url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 128 * 1024 * 1024,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return libraries(in: data).contains { ["d3d12.dll", "d3d12core.dll"].contains($0) }
    }

    static func libraries(in data: Data) -> Set<String> {
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= data.count - 2 else { return nil }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        guard u16(0) == 0x5a4d, let pe = u32(0x3c), u32(pe) == 0x4550,
              let sections = u16(pe + 6), sections <= 96,
              let optionalSize = u16(pe + 20), let magic = u16(pe + 24),
              [0x10b, 0x20b].contains(magic) else { return [] }
        let optional = pe + 24, table = optional + optionalSize
        let directory = optional + (magic == 0x20b ? 112 : 96)
        guard optionalSize >= directory - optional, table <= data.count,
              sections <= (data.count - table) / 40 else { return [] }
        func offset(_ rva: Int) -> Int? {
            for index in 0..<sections {
                let section = table + index * 40
                guard let address = u32(section + 12), let size = u32(section + 16),
                      let raw = u32(section + 20) else { continue }
                if rva >= address, rva - address < size {
                    let result = raw + rva - address
                    if result < data.count { return result }
                }
            }
            return nil
        }
        var result = Set<String>()
        // Normal imports and RVA-based delay imports (PE32/PE32+).
        for (index, stride, nameField) in [(1, 20, 12), (13, 32, 4)] {
            guard directory + (index + 1) * 8 <= table,
                  let rva = u32(directory + index * 8), rva != 0,
                  let size = u32(directory + index * 8 + 4), let start = offset(rva) else { continue }
            let count = min(size / stride, 4096, (data.count - start) / stride)
            for entry in 0..<count {
                let descriptor = start + entry * stride
                guard let nameRVA = u32(descriptor + nameField), nameRVA != 0 else { break }
                if index == 13, u32(descriptor).map({ $0 & 1 }) != 1 { continue }
                guard let name = offset(nameRVA) else { continue }
                let end = min(name + 260, data.count)
                guard let zero = data[name..<end].firstIndex(of: 0),
                      let library = String(data: data[name..<zero], encoding: .ascii) else { continue }
                result.insert(library.lowercased())
            }
        }
        return result
    }
}

nonisolated struct D3DMetalInstallation: Equatable, Sendable {
    let library: URL

    static func find(in selection: URL, fileExists: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) -> Self? {
        for relative in ["", "redist/lib", "lib", "Contents/Resources/redist/lib", "lib64/apple_gptk"] {
            let lib = selection.appendingPathComponent(relative).standardizedFileURL
            let required = ["wine/x86_64-windows/d3d12.dll", "wine/x86_64-windows/d3d11.dll", "wine/x86_64-windows/dxgi.dll",
                "wine/x86_64-unix/d3d12.so", "wine/x86_64-unix/d3d11.so", "wine/x86_64-unix/dxgi.so",
                "external/libd3dshared.dylib", "external/D3DMetal.framework/D3DMetal"]
            if required.allSatisfy({ fileExists(lib.appendingPathComponent($0).path) }) { return Self(library: lib) }
        }
        return nil
    }

    func environment(over base: [String: String]) -> [String: String] {
        var env = base
        env.removeValue(forKey: "WINEDLLPATH_DXMT")
        env.removeValue(forKey: "DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN")
        let modules = library.appendingPathComponent("wine").path
        env["WINEDLLPATH_D3DMETAL"] = modules
        env["WINEDLLPATH_PREPEND"] = modules
        env["WINEDLLOVERRIDES"] = "d3d10,d3d11,d3d12,dxgi=b"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = library.appendingPathComponent("external").path + ":" + (base["DYLD_FALLBACK_LIBRARY_PATH"] ?? "/usr/lib")
        return env
    }
}

@Observable final class GraphicsSupport {
    static let guide = URL(string: "https://pufflet.apps.balaj.me/guides/game-porting-toolkit")!
    private let defaults: UserDefaults
    private(set) var installation: D3DMetalInstallation?
    private(set) var skipped: Bool
    private(set) var choices: [String: String]
    var selectionError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        skipped = defaults.bool(forKey: "gptkOnboardingSkipped")
        choices = defaults.dictionary(forKey: "gameGraphicsBackends") as? [String: String] ?? [:]
    }

    func backend(for id: String) -> GraphicsBackend { choices[id].flatMap(GraphicsBackend.init(rawValue:)) ?? .auto }
    func setBackend(_ backend: GraphicsBackend, for id: String) {
        choices[id] = backend.rawValue
        defaults.set(choices, forKey: "gameGraphicsBackends")
    }
    func skip() { skipped = true; defaults.set(true, forKey: "gptkOnboardingSkipped") }

    func refresh() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = defaults.string(forKey: "gptkLibraryPath").map { [URL(filePath: $0)] } ?? []
        roots += [home.appendingPathComponent("Library/Application Support/Game Porting Toolkit"),
                  URL(filePath: "/usr/local/opt/game-porting-toolkit"), URL(filePath: "/opt/homebrew/opt/game-porting-toolkit")]
        let volumes = (try? FileManager.default.contentsOfDirectory(at: URL(filePath: "/Volumes"), includingPropertiesForKeys: nil)) ?? []
        roots += volumes.filter { $0.lastPathComponent.lowercased().contains("evaluation environment for windows games") }
        installation = roots.lazy.compactMap { D3DMetalInstallation.find(in: $0) }.first
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add Game Porting Toolkit"
        panel.message = "Choose the evaluation environment folder containing redist, or its redist/lib folder. Keep the complete folder on your Mac."
        panel.prompt = "Add Toolkit"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }

    func add(_ url: URL) {
        guard let found = D3DMetalInstallation.find(in: url) else {
            selectionError = "This folder does not contain the complete D3DMetal installation. Open the evaluation environment included in Apple’s Game Porting Toolkit and choose its redist/lib folder."
            return
        }
        defaults.set(found.library.path, forKey: "gptkLibraryPath")
        installation = found; selectionError = nil
    }
}

struct GamePortingToolkitSetup: View {
    @Bindable var support: GraphicsSupport
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.tint)
            Text("DirectX 12 games need Apple’s Game Porting Toolkit.").font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("It’s an optional download from Apple. Pufflet already includes DXMT for DirectX 10 and 11 games.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ToolkitControls(support: support)
            HStack {
                Button("Skip") { support.skip(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(support.installation == nil)
            }
        }
        .padding(24).frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ToolkitControls: View {
    @Bindable var support: GraphicsSupport
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(support.installation == nil ? "Game Porting Toolkit not detected" : "Game Porting Toolkit detected",
                  systemImage: support.installation == nil ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(support.installation == nil ? Color.secondary : Color.green)
            if let error = support.selectionError { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Link("Installation Guide", destination: GraphicsSupport.guide)
                Spacer()
                Button("Add Toolkit…") { support.chooseFolder() }
            }
        }
        .task {
            while !Task.isCancelled {
                support.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}
