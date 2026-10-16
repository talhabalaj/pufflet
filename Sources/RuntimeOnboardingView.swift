import AppKit
import SwiftUI

struct RuntimeOnboardingView: View {
    @Bindable var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var locationError: String?
    @State private var showsAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Pufflet").font(.largeTitle.bold())
                Text("Connect your games and prepare Windows support to start playing.")
                    .foregroundStyle(.secondary)
            }
            row("1", title: "Your Steam library", ready: model.settings.libraryURL != nil) {
                Text(model.settings.libraryURL?.path ?? "Pufflet creates a library automatically. You can also use an existing Steam library.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Button("Change library…", action: chooseLibrary)
                    .disabled(!model.canChangeLibrary)
                if let locationError { Text(locationError).foregroundStyle(.red).font(.callout) }
            }
            Divider()
            row("2", title: "Windows support", ready: model.runtimeSetup.isReady) {
                if let progress = model.runtimeSetup.progress {
                    Text(progress.message).font(.callout).foregroundStyle(.secondary)
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                        Text("\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else { ProgressView().controlSize(.small) }
                } else if model.runtimeSetup.isPaused || model.runtimeSetup.savedBytes > 0 {
                    Text(model.runtimeSetup.savedBytes > 0
                        ? "Paused — \(ByteCountFormatter.string(fromByteCount: model.runtimeSetup.savedBytes, countStyle: .file)) saved. Resume when you’re ready."
                        : "Download paused. This download will restart when you retry.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(model.runtimeSetup.isReady ? "Wine and DXMT are installed in Pufflet’s private app data." : "A one-time, verified download. Your prefix, games, and saves stay separate.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.runtimeSetup.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
                if model.runtimeSetup.isBusy {
                    Button(model.runtimeSetup.progress?.phase == .downloading ? "Pause download" : "Cancel installation") { model.runtimeSetup.cancel() }
                } else if !model.runtimeSetup.isReady {
                    Button(model.runtimeSetup.savedBytes > 0 ? "Resume download" : model.runtimeSetup.errorMessage == nil && !model.runtimeSetup.isPaused ? "Download Windows support" : "Retry download") { model.runtimeSetup.start() }
                        .disabled(model.settings.libraryURL == nil || !model.runtimeSetup.hasChecked || model.headless.isActive)
                }
            }
            Divider()
            row("3", title: "Your Steam account", ready: model.account.accountName != nil) {
                Text(model.account.accountName.map { "Signed in as \($0)" } ?? "Sign in securely with QR code, password, or Steam Guard.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(model.account.accountName == nil ? "Sign in to Steam…" : "Manage account…") { showsAccount = true }
            }
            Divider()
            row("4", title: "Ready to play", ready: model.readyToPlay) {
                Text(model.steamSupportReady ? "Steam support is prepared. Choose a game and press Play." : model.headless.isActive ? model.headless.status : "Prepare Valve’s verified Steam components and your private Windows prefix.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.headless.isActive { ProgressView().controlSize(.small) }
                Button("Prepare Steam support") { Task { await model.prepareSteamSupport() } }
                    .disabled(!model.runtimeSetup.isReady || model.settings.libraryURL == nil || model.headless.isActive)
                if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            }
            HStack {
                Text(model.readyToPlay ? "You’re ready to play." : "You can return to setup from the Steam menu.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.readyToPlay ? "Open library" : "Continue later") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(30).frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showsAccount, onDismiss: { model.account.refresh() }) { SteamAccountView(account: model.account, sessionActive: !model.canManageAccount) }
        .interactiveDismissDisabled(model.runtimeSetup.isBusy)
    }

    private func row<Content: View>(_ number: String, title: String, ready: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: ready ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2).foregroundStyle(ready ? Color.green : Color.secondary)
                .accessibilityLabel(ready ? "Complete" : "Step \(number)")
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.headline)
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Choose your Steam library"; panel.prompt = "Choose library"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = model.settings.libraryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.settings.createLibrary(at: url)
            model.refreshLibrary(); locationError = nil; model.steamSupportReady = false
            model.runtimeSetup.start()
        } catch { locationError = error.localizedDescription }
    }
}
