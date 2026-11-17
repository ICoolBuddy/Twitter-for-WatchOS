import SwiftUI
import WebKit
import XKit

/// Loads x.com/login in a non-persistent WKWebView. When the session cookies
/// (`auth_token`, `ct0`) appear, they are handed back and the web data is discarded,
/// so the only copy of the session lives in the Keychain.
struct LoginWebView: UIViewRepresentable {
    let onCredentials: (XCredentials) -> Void
    @Binding var status: String

    static let mobileSafariUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = Self.mobileSafariUA
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.webView = web
        web.load(URLRequest(url: URL(string: "https://x.com/i/flow/login")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
        uiView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let parent: LoginWebView
        weak var webView: WKWebView?
        private var finished = false
        private var pendingCheck: DispatchWorkItem?

        init(_ parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            scheduleCheck()
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            scheduleCheck()
        }

        /// Debounced: X sets ct0 again right after login, so wait for cookies to settle.
        private func scheduleCheck() {
            pendingCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.check() }
            pendingCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }

        private func check() {
            guard !finished, let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.finished else { return }
                let xCookies = cookies.filter { $0.domain.hasSuffix("x.com") || $0.domain.hasSuffix("twitter.com") }
                func value(_ name: String) -> String? { xCookies.first { $0.name == name }?.value }
                guard let auth = value("auth_token"), let ct0 = value("ct0") else {
                    self.parent.status = "Log in to X normally (2FA works). Perch picks up the session automatically."
                    return
                }
                let creds = XCredentials(authToken: auth, ct0: ct0, twid: value("twid"))
                guard creds.looksValid else { return }
                let path = self.webView?.url?.path ?? ""
                // Wait until X has left the login flow, so ct0 is the post-login value.
                if path.contains("/flow/") || path.contains("/login") || path.contains("/account/") {
                    self.parent.status = "Finishing login…"
                    return
                }
                self.finished = true
                self.parent.status = "Logged in."
                self.parent.onCredentials(creds)
            }
        }
    }
}

struct LoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Loading x.com…"
    let onDone: (XCredentials) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                LoginWebView(onCredentials: { creds in
                    onDone(creds)
                    dismiss()
                }, status: $status)
            }
            .navigationTitle("Log in to X")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct ManualLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authToken = ""
    @State private var ct0 = ""
    @State private var twid = ""
    let onDone: (XCredentials) -> Void

    var creds: XCredentials { XCredentials(authToken: authToken, ct0: ct0, twid: twid.isEmpty ? nil : twid) }

    var body: some View {
        Form {
            Section {
                SecureField("auth_token", text: $authToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("ct0", text: $ct0)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("twid (optional, e.g. u%3D12345)", text: $twid)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("On a computer: open x.com while logged in → DevTools → Application/Storage → Cookies → https://x.com. Copy the values of auth_token and ct0. They are stored only in this device's Keychain and sent to your Watch.")
            }
            Section {
                Button("Save") {
                    onDone(creds)
                    dismiss()
                }
                .disabled(!creds.looksValid)
            } footer: {
                if !authToken.isEmpty && !creds.looksValid {
                    Text("auth_token should be ~40 hex characters, ct0 at least 32.")
                }
            }
        }
        .navigationTitle("Paste cookies")
    }
}
