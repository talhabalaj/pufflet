import os
import SwiftUI
import WebKit

nonisolated enum EpicSignIn {
    /// Accepts the redirect page's JSON, text containing it, or the bare code.
    static func authorizationCode(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 * 1024 else { return nil }
        if trimmed.utf8.count == 32, trimmed.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { return trimmed }
        guard let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed[open...close].utf8)) as? [String: Any],
              let code = object["authorizationCode"] as? String, EpicAPI.isIdentifier(code) else { return nil }
        return code
    }

    static func isRedirect(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "www.epicgames.com" && url.path == "/id/api/redirect"
    }
}

/// Epic's own login page in a private web view. After login Epic shows a JSON
/// page with a one-time authorization code, which is read here directly so the
/// user never copies it. Nothing from the web view is persisted.
struct EpicLoginWebView: NSViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Reports login API statuses and script errors (paths only, never bodies,
        // query strings or form values) so a stuck sign-in can be diagnosed.
        configuration.userContentController.add(context.coordinator, name: "pufflet")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.diagnostics, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Epic's login checks stall on WebKit's bare embedded user agent; present as Safari.
        view.customUserAgent = Self.safariUserAgent
        #if DEBUG
        view.isInspectable = true
        #endif
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.log("start")
        view.load(URLRequest(url: EpicAPI.loginURL))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "pufflet")
    }

    static let safariUserAgent: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version.majorVersion).0 Safari/605.1.15"
    }()

    private static let diagnostics = """
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.pufflet.postMessage(String(m).slice(0, 300)); } catch (e) {} };
      const where = (u) => { try { const x = new URL(u, location.href); return x.host + x.pathname; } catch (e) { return '?'; } };
      const frame = window === window.top ? 'top' : 'frame ' + location.host;
      window.addEventListener('error', (e) => post(frame + ' error: ' + e.message));
      window.addEventListener('unhandledrejection', (e) => post(frame + ' rejection: ' + (e.reason && e.reason.message || e.reason)));
      const error = console.error; console.error = (...a) => { post(frame + ' console: ' + a.map(String).join(' ')); error(...a); };
      const fetch0 = window.fetch;
      window.fetch = (input, init) => fetch0(input, init).then(
        (r) => { post(frame + ' fetch ' + r.status + ' ' + where(r.url || input.url || input)); return r; },
        (e) => { post(frame + ' fetch failed ' + where(input.url || input) + ': ' + e); throw e; });
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.addEventListener('loadend', () => post(frame + ' xhr ' + this.status + ' ' + method + ' ' + where(url)));
        return open.apply(this, arguments);
      };
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let onCode: (String) -> Void
        private var delivered = false
        private let file = AppIdentity.logs.appendingPathComponent("epic-login.log")
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func log(_ line: String) {
            let text = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if line == "start" { try? Data(text.utf8).write(to: file); return }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(text.utf8))
        }
        private func describe(_ url: URL?) -> String { (url?.host ?? "?") + (url?.path ?? "") }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let text = message.body as? String { log("page " + text) }
        }

        /// Pop-ups (captcha, verification, social sign-in) open in the same view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            log("popup " + describe(navigationAction.request.url))
            if navigationAction.request.url?.scheme == "https" { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.targetFrame?.isMainFrame != false { log("navigate " + describe(navigationAction.request.url)) }
            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
                log("response \(http.statusCode) " + describe(http.url))
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log("failed: " + error.localizedDescription)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log("failed to load: " + error.localizedDescription)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            log("web content process ended; reloading"); webView.reload()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log("finished " + describe(webView.url))
            guard !delivered, let url = webView.url, EpicSignIn.isRedirect(url) else { return }
            webView.evaluateJavaScript("document.body.innerText") { [weak self] value, _ in
                guard let self, !self.delivered, let text = value as? String, let code = EpicSignIn.authorizationCode(in: text) else {
                    self?.log("redirect page had no authorization code")
                    return
                }
                self.delivered = true
                self.log("authorization code received")
                self.onCode(code)
            }
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
