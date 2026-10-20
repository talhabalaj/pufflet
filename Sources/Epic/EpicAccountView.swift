import SwiftUI
import WebKit

/// Epic's own login page in a private web view. After login Epic shows a JSON
/// page with a one-time authorization code, which is read here directly so the
/// user never copies it. Nothing from the web view is persisted.
struct EpicLoginWebView: NSViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: EpicAPI.loginURL))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCode: (String) -> Void
        private var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !delivered, let url = webView.url, Self.isRedirect(url) else { return }
            webView.evaluateJavaScript("document.body.innerText") { [weak self] value, _ in
                guard let self, !self.delivered, let text = value as? String, let code = Self.authorizationCode(in: text) else { return }
                self.delivered = true
                self.onCode(code)
            }
        }

        static func isRedirect(_ url: URL) -> Bool {
            url.scheme == "https" && url.host?.lowercased() == "www.epicgames.com" && url.path == "/id/api/redirect"
        }

        static func authorizationCode(in text: String) -> String? {
            guard text.utf8.count <= 64 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let code = object["authorizationCode"] as? String, EpicAPI.isIdentifier(code) else { return nil }
            return code
        }
    }
}

struct EpicSignInSheet: View {
    let account: EpicAccount
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            EpicLoginWebView { code in
                dismiss()
                Task { await account.signIn(authorizationCode: code) }
            }
            Divider()
            HStack {
                Text("Pufflet isn’t affiliated with Epic Games. Your password goes only to Epic.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 560, height: 680)
    }
}

struct EpicAccountSettings: View {
    let account: EpicAccount
    @State private var showsSignIn = false
    @State private var confirmsSignOut = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 36)).foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName ?? "Not Signed In").font(.headline)
                        Text(account.isSignedIn ? "Epic Games account, saved in this Mac’s Keychain" : "Sign in to see the Windows games you own on Epic.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if account.isSignedIn {
                        Button("Sign Out…") { confirmsSignOut = true }
                    } else {
                        Button("Sign In…") { showsSignIn = true }.buttonStyle(.borderedProminent).disabled(account.isBusy)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                if let error = account.errorMessage { Text(error).foregroundStyle(.red) }
            }
            if account.isSignedIn {
                Section {
                    LabeledContent("Windows games", value: account.isBusy && account.games.isEmpty ? "Loading…" : "\(account.games.count)")
                    LabeledContent("") {
                        Button("Refresh Library") { Task { await account.refreshLibrary() } }.disabled(account.isBusy)
                    }
                } footer: {
                    Text("Epic games appear in your library and can be installed. Playing them in Pufflet is coming soon.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if !AppIdentity.isRunningTests { account.refresh() } }
        .sheet(isPresented: $showsSignIn) { EpicSignInSheet(account: account) }
        .confirmationDialog("Sign out of Epic Games?", isPresented: $confirmsSignOut) {
            Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
        } message: {
            Text("Pufflet forgets this account and its library on this Mac.")
        }
    }
}
