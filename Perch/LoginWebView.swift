import Foundation
import SwiftUI
import WebKit
import XKit

/// Wipes the app's WKWebView website data (cookies included) so a new login never
/// picks up the previous account's x.com/twitter.com session. The app's only web
/// usage is X, so clearing the whole store is safe.
@MainActor
enum XLoginCookies {
    static func clearAll() async {
        await clear(store: WKWebsiteDataStore.default())
    }

    static func clear(store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                             modifiedSince: Date.distantPast) {
                continuation.resume(returning: ())
            }
        }
    }
}

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
                // Exact domains or their subdomains: `hasSuffix("x.com")` also matched
                // e.g. "netflix.com".
                let xCookies = cookies.filter {
                    let d = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return d == "x.com" || d.hasSuffix(".x.com") || d == "twitter.com" || d.hasSuffix(".twitter.com")
                }
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
                // Discard the web session now that the cookies are in the Keychain.
                if let store = self.webView?.configuration.websiteDataStore {
                    Task { @MainActor in await XLoginCookies.clear(store: store) }
                }
            }
        }
    }
}

struct LoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Clearing the previous session…"
    @State private var preparing = true
    @State private var verifying = false
    /// Verifies the session; returns nil when it worked (the sheet closes), else the
    /// message to show while the sheet stays open.
    let onDone: (XCredentials) async -> String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                if preparing {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Clearing the previous X session…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LoginWebView(onCredentials: { creds in
                        guard !verifying else { return }
                        verifying = true
                        status = "Checking the session with X…"
                        Task { @MainActor in
                            let problem = await onDone(creds)
                            verifying = false
                            if let problem { status = problem } else { dismiss() }
                        }
                    }, status: $status)
                }
            }
            .navigationTitle("Log in to X")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                // Required before every new web login: never reuse the previous
                // account's x.com/twitter.com session.
                await XLoginCookies.clearAll()
                status = "Loading x.com…"
                preparing = false
            }
        }
    }
}

struct ManualLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authToken = ""
    @State private var ct0 = ""
    @State private var twid = ""
    @State private var verifying = false
    @State private var problem: String?
    /// Verifies the session; nil = worked (the view closes), else the message to show.
    let onDone: (XCredentials) async -> String?

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
                Button(verifying ? "Checking with X…" : "Save") {
                    verifying = true
                    problem = nil
                    Task { @MainActor in
                        let result = await onDone(creds)
                        verifying = false
                        if let result { problem = result } else { dismiss() }
                    }
                }
                .disabled(!creds.looksValid || verifying)
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange)
                }
            } footer: {
                if !authToken.isEmpty && !creds.looksValid {
                    Text("auth_token should be ~40 hex characters, ct0 at least 32.")
                }
            }
        }
        .navigationTitle("Paste cookies")
    }
}
