import SwiftUI

struct SteamAccountView: View {
    @Bindable var account: SteamAccount
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Steam account").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let name = account.accountName {
                ContentUnavailableView {
                    Label("Signed in as \(name)", systemImage: "checkmark.seal")
                } description: {
                    Text("Your Steam session is saved in this Mac’s Keychain.")
                } actions: {
                    Button("Sign out", role: .destructive) { account.signOut() }
                }
            } else {
                Picker("Sign-in method", selection: $account.method) {
                    ForEach(SteamAccount.Method.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if account.method == .qr { qrContent }
                else { passwordContent }
                if let error = account.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("Sign-in connects directly to Steam. Your password is never saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(28).frame(width: 440, alignment: .top).frame(minHeight: 440)
        .onChange(of: account.method) { _, _ in account.cancel(); password = ""; code = ""; account.errorMessage = nil }
        .onAppear { account.refresh() }
        .onDisappear { account.cancel(); password = ""; code = "" }
    }

    @ViewBuilder private var qrContent: some View {
        if let image = account.image {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(16).background(.white, in: .rect(cornerRadius: 12)).frame(width: 240, height: 240)
                .accessibilityLabel("Steam sign-in QR code")
            Text("Open Steam on your phone and scan this code from Steam Guard.")
                .font(.callout).multilineTextAlignment(.center)
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for approval…").foregroundStyle(.secondary)
                Button("Cancel") { account.cancel() }
            }.font(.callout)
        } else {
            Image(systemName: "qrcode").font(.system(size: 90, weight: .ultraLight)).foregroundStyle(.secondary).frame(height: 170)
            Text("Use the Steam mobile app to sign in without typing your password.")
                .multilineTextAlignment(.center)
            Button { account.beginQR() } label: {
                if account.isBusy { ProgressView().controlSize(.small).frame(width: 140) }
                else { Text("Generate QR code").frame(width: 140) }
            }.buttonStyle(.glassProminent).controlSize(.large).disabled(account.isBusy)
        }
    }

    @ViewBuilder private var passwordContent: some View {
        if let prompt = account.guardPrompt {
            VStack(alignment: .leading, spacing: 16) {
                Text("Confirm with Steam Guard").font(.headline)
                if prompt.canApprove { Text("Approve this sign-in in Steam on your phone.") }
                if let type = prompt.codeType {
                    Text(type == .email ? "Enter the code Steam emailed you." : "Enter the code from Steam Guard.")
                    TextField("Steam Guard code", text: $code).textFieldStyle(.roundedBorder)
                        .onSubmit(submitCode)
                    Button("Verify code", action: submitCode).buttonStyle(.glassProminent)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || account.isBusy)
                }
                if account.isBusy { ProgressView().controlSize(.small) }
                Button("Start again") { account.cancel(); code = "" }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else if account.isWaiting {
            ProgressView("Waiting for Steam…").padding(.vertical, 60)
            Button("Cancel") { account.cancel() }
        } else {
            Form {
                TextField("Account name", text: $name)
                    .textContentType(.username).autocorrectionDisabled()
                SecureField("Password", text: $password).textContentType(.password).onSubmit(signIn)
            }.formStyle(.grouped).frame(height: 140)
            Button(action: signIn) {
                if account.isBusy { ProgressView().controlSize(.small).frame(width: 140) }
                else { Text("Sign in").frame(width: 140) }
            }.buttonStyle(.glassProminent).controlSize(.large)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || account.isBusy)
        }
    }

    private func signIn() {
        guard !account.isBusy, !name.isEmpty, !password.isEmpty else { return }
        let submitted = password; password = ""
        account.beginPassword(account: name, secret: submitted)
    }
    private func submitCode() { let submitted = code; code = ""; account.submitCode(submitted) }
}
