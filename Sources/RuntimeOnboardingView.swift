import AppKit
import SwiftUI

struct RuntimeOnboardingView: View {
    @Bindable var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var locationError: String?
    @State private var showsAccount = false

    private var steps: [Bool] {
        [model.settings.libraryURL != nil, model.runtimeSetup.isReady, model.account.accountName != nil, model.readyToPlay]
    }
    private var currentStep: Int? { steps.firstIndex(of: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up Pufflet").font(.title2.bold())
                Text("Connect your games and prepare Windows support. You can come back to this from the Steam menu.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                step(0, "Game Library") {
                    if let location = model.settings.libraryURL {
                        Text("Games install to \(FileManager.default.displayName(atPath: location.path)).").help(location.path)
                    } else {
                        Text("Pufflet creates a library automatically. You can also use an existing Steam library.")
                    }
                    if let locationError { Text(locationError).foregroundStyle(.red) }
                } accessory: {
                    Button("Change…", action: chooseLibrary).disabled(!model.canChangeLibrary)
                }
                Divider().padding(.leading, 38)
                step(1, "Windows Support") {
                    if model.runtimeSetup.isReady {
                        Text("Wine and DXMT are installed in Pufflet’s private app data.")
                    } else if let progress = model.runtimeSetup.progress {
                        Text(progress.message)
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction).controlSize(.small)
                            Text("\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                                .font(.caption).monospacedDigit()
                        } else { ProgressView().controlSize(.small) }
                    } else if model.runtimeSetup.isPaused || model.runtimeSetup.savedBytes > 0 {
                        Text(model.runtimeSetup.savedBytes > 0
                            ? "Paused — \(ByteCountFormatter.string(fromByteCount: model.runtimeSetup.savedBytes, countStyle: .file)) saved. Resume when you’re ready."
                            : "Download paused. This download will restart when you retry.")
                    } else {
                        Text("A one-time, verified download. Your prefix, games, and saves stay separate.")
                    }
                    if let error = model.runtimeSetup.errorMessage { Text(error).foregroundStyle(.red) }
                } accessory: {
                    if model.runtimeSetup.isBusy {
                        Button(model.runtimeSetup.progress?.phase == .downloading ? "Pause" : "Cancel") { model.runtimeSetup.cancel() }
                    } else if !model.runtimeSetup.isReady {
                        Button(model.runtimeSetup.savedBytes > 0 ? "Resume" : model.runtimeSetup.errorMessage == nil && !model.runtimeSetup.isPaused ? "Download" : "Retry") {
                            model.runtimeSetup.start()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.settings.libraryURL == nil || !model.runtimeSetup.hasChecked || model.headless.isActive)
                    }
                }
                Divider().padding(.leading, 38)
                step(2, "Steam Account") {
                    Text(model.account.accountName.map { "Signed in as \($0)." } ?? "Sign in to see the Windows games you own.")
                } accessory: {
                    if model.account.accountName == nil {
                        Button("Sign In…") { showsAccount = true }.buttonStyle(.borderedProminent)
                    }
                }
                Divider().padding(.leading, 38)
                step(3, "Steam Support") {
                    Text(model.steamSupportReady ? "Steam support is prepared. Choose a game and press Play."
                         : model.headless.isActive ? model.headless.status : "Prepare Valve’s verified Steam components and your private Windows prefix.")
                    if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                } accessory: {
                    if model.headless.isActive {
                        ProgressView().controlSize(.small)
                    } else if !model.steamSupportReady {
                        Button("Prepare") { Task { await model.prepareSteamSupport() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.runtimeSetup.isReady || model.settings.libraryURL == nil)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
            HStack {
                Spacer()
                Button("Continue Later") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open Library") { dismiss() }.keyboardShortcut(.defaultAction).disabled(!model.readyToPlay)
            }
        }
        .padding(22).frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showsAccount, onDismiss: { model.account.refresh() }) { SteamAccountView(account: model.account, sessionActive: !model.canManageAccount) }
        .interactiveDismissDisabled(model.runtimeSetup.isBusy)
    }

    private func step<Detail: View, Accessory: View>(_ index: Int, _ title: String, @ViewBuilder detail: () -> Detail,
                                                     @ViewBuilder accessory: () -> Accessory) -> some View {
        let done = steps[index], current = currentStep == index
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : current ? "circle.circle" : "circle.dashed")
                .font(.title2).frame(width: 26)
                .foregroundStyle(done ? AnyShapeStyle(.green) : current ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(done ? "Complete" : current ? "Current step" : "Not started")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(done || current ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 4) { detail() }
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
        }
        .padding(.vertical, 12)
    }

    private func chooseLibrary() {
        do {
            guard try model.chooseLibraryFolder() else { return }
            locationError = nil
            model.runtimeSetup.start()
        } catch { locationError = error.localizedDescription }
    }
}
