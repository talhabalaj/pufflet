import SwiftUI

/// The sign-in sheet. Account management lives in Settings ▸ Steam (`SteamAccountSettings`).
struct SteamAccountView: View {
    @Bindable var account: SteamAccount
    var sessionActive = false
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(spacing: 18) {
            Text("Sign In to Steam").font(.headline)
            if let name = account.accountName {
                Label("Signed in as \(name)", systemImage: "checkmark.seal").font(.body.weight(.semibold))
            } else if sessionActive {
                Text("Steam is running for a download or game. End the Steam session in Settings ▸ Steam before signing in.")
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            } else if let prompt = account.guardPrompt {
                guardContent(prompt)
            } else if account.isWaiting, account.method == .password {
                ProgressView("Waiting for Steam…").padding(.vertical, 40)
            } else {
                Picker("Sign-in method", selection: $account.method) {
                    ForEach(SteamAccount.Method.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if account.method == .qr { qrContent } else { passwordContent }
            }
            if let error = account.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { account.refresh() }
        // Show the QR code straight away, the way Steam's own client does.
        .task(id: account.method) {
            account.cancel(); password = ""; code = ""
            if account.method == .qr, account.accountName == nil, !sessionActive { account.beginQR() } else { account.errorMessage = nil }
        }
        .onChange(of: account.accountName) { _, name in if name != nil { dismiss() } }
        .onDisappear { account.cancel(); password = ""; code = "" }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if account.guardPrompt != nil { Button("Start Over") { account.cancel(); code = "" } }
            Spacer()
            if account.accountName != nil {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if account.guardPrompt?.codeType != nil {
                    Button("Verify", action: submitCode).keyboardShortcut(.defaultAction)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || account.isBusy)
                } else if account.method == .password, account.guardPrompt == nil, !account.isWaiting, !sessionActive {
                    Button("Sign In", action: signIn).keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || account.isBusy)
                }
            }
        }
    }

    @ViewBuilder private var qrContent: some View {
        VStack(spacing: 10) {
            Group {
                if let image = account.image {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                        .accessibilityLabel("Steam sign-in QR code")
                } else if account.isBusy {
                    ProgressView()
                } else {
                    Button("Show New Code") { account.beginQR() }
                }
            }
            .frame(width: 168, height: 168).padding(10)
            .background(account.image == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.white), in: .rect(cornerRadius: 10))
            Text("Scan with the Steam Mobile App").font(.body.weight(.semibold))
            Text("In Steam on your phone, open Steam Guard and tap the QR code button.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if account.isWaiting {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for approval…") }
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var passwordContent: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Account name", text: $name, prompt: Text("Required"))
                    .textContentType(.username).autocorrectionDisabled()
                SecureField("Password", text: $password, prompt: Text("Required"))
                    .textContentType(.password).onSubmit(signIn)
            }
            .formStyle(.grouped).scrollDisabled(true).frame(height: 120)
            Text("Sign-in connects directly to Steam. Your password is never saved.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(account.isBusy)
    }

    private func guardContent(_ prompt: SteamGuardPrompt) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(prompt.codeType == nil ? "Approve This Sign-In" : "Enter Your Steam Guard Code").font(.body.weight(.semibold))
            Group {
                switch (prompt.codeType, prompt.canApprove) {
                case (.email?, _): Text("Enter the code Steam emailed you.")
                case (.some, true): Text("Enter the code from the Steam Mobile App, or approve this sign-in on your phone.")
                case (.some, false): Text("Enter the code from the Steam Mobile App.")
                case (nil, _): Text("Approve this sign-in in Steam on your phone.")
                }
            }
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if prompt.codeType != nil {
                TextField("Steam Guard code", text: $code)
                    .font(.title2.monospaced()).multilineTextAlignment(.center).textFieldStyle(.roundedBorder).frame(width: 160)
                    .textContentType(.oneTimeCode).onSubmit(submitCode)
            }
            if account.isBusy || prompt.codeType == nil { ProgressView().controlSize(.small) }
        }
    }

    private func signIn() {
        guard !account.isBusy, !name.isEmpty, !password.isEmpty else { return }
        let submitted = password; password = ""
        account.beginPassword(account: name, secret: submitted)
    }
    private func submitCode() {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submitted = code; code = ""; account.submitCode(submitted)
    }
}

/// Settings ▸ Steam: the signed-in account and the shared Steam session.
struct SteamAccountSettings: View {
    @Bindable var model: LibraryModel
    @State private var showsSignIn = false
    @State private var confirmsSignOut = false
    @State private var confirmsEndSession = false
    @State private var sessionError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 36)).foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.account.accountName ?? "Not Signed In").font(.headline)
                        Text(model.account.accountName == nil ? "Sign in to see the Windows games you own." : "Steam account, saved in this Mac’s Keychain")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.account.accountName == nil {
                        Button("Sign In…") { showsSignIn = true }.buttonStyle(.borderedProminent).disabled(!model.canManageAccount)
                    } else {
                        Button("Sign Out…") { confirmsSignOut = true }.disabled(!model.canManageAccount)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                if !model.canManageAccount {
                    Text(model.headless.isActive ? "Steam is running for a download or game. End the Steam session to change accounts."
                                                 : "Finish or stop your downloads to change accounts.")
                }
            }
            if model.account.accountName != nil || model.headless.isActive {
                Section {
                    LabeledContent("Steam session", value: !model.headless.isActive ? "Not running" : model.headless.hasLaunchWork ? "Running for a game" : "Running")
                    LabeledContent("") {
                        Button("End Steam Session…") { confirmsEndSession = true }
                            .disabled(!model.headless.isActive || model.headless.hasLaunchWork || model.isStoppingDownload)
                    }
                } footer: {
                    Text(model.headless.hasLaunchWork ? "Close the game before ending its Steam session."
                                                      : "Pufflet keeps one Steam session for downloads and play. Ending it keeps partial downloads for the next launch.")
                }
            }
        }
        .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Sign out of Steam?", isPresented: $confirmsSignOut) {
            Button("Sign Out", role: .destructive) { model.account.signOut() }
        } message: { Text("Your installed games stay on this Mac. Sign in again to see the rest of your library.") }
        .confirmationDialog("End the Steam session?", isPresented: $confirmsEndSession) {
            Button("End Session") {
                Task { do { try await model.shutdownSession() } catch { sessionError = error.localizedDescription } }
            }
        } message: { Text("Partial downloads are kept for the next launch.") }
        .alert("The Steam session couldn’t be ended", isPresented: Binding(get: { sessionError != nil }, set: { if !$0 { sessionError = nil } })) {
            Button("OK", role: .cancel) { sessionError = nil }
        } message: { Text(sessionError ?? "") }
        .sheet(isPresented: $showsSignIn) { SteamAccountView(account: model.account, sessionActive: !model.canManageAccount) }
    }
}
