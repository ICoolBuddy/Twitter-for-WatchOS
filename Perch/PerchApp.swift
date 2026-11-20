import SwiftUI
import XKit

@main
struct PerchApp: App {
    @StateObject private var app = AppModel.shared
    @StateObject private var sync = PhoneSync.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PerchSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environmentObject(app)
                .environmentObject(app.posts)
                .environmentObject(sync)
                .onAppear { sync.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await app.refreshBadge() } }
        }
    }
}

struct PhoneRootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var sync: PhoneSync
    @State private var showLogin = false
    @State private var path = NavigationPath()
    @State private var alert: String?
    @State private var overrideURL = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                accountSection
                watchSection
                if app.canBrowse {
                    Section("Browse on iPhone") {
                        NavigationLink("Home timeline") { PhoneTimelineView() }
                    }
                }
                endpointsSection
                Section {
                    NavigationLink("Request log (redacted)") { DebugLogView() }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Perch never logs cookie or token values. Requests are rate-limited and back off automatically on 429.")
                }
            }
            .navigationTitle("Perch")
            .overlay(alignment: .bottom) {
                if let msg = app.busyMessage {
                    Label(msg, systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .padding(10)
                        .background(.thinMaterial, in: Capsule())
                        .padding()
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginSheet { creds in await app.login(creds).message }
            }
            .alert("Perch", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alert ?? "")
            }
            .task {
                overrideURL = app.remoteOverrideURL?.absoluteString ?? ""
            }
        }
    }

    private var accountSection: some View {
        Section {
            if app.accounts.isEmpty {
                Button {
                    showLogin = true
                } label: {
                    Label("Log in with X", systemImage: "person.crop.circle.badge.plus")
                }
            } else {
                ForEach(app.accounts) { account in
                    accountRow(account)
                }
                Button {
                    showLogin = true
                } label: {
                    Label("Add account", systemImage: "person.badge.plus")
                }
            }
            NavigationLink {
                ManualLoginView { creds in await app.login(creds).message }
            } label: {
                Label("Paste cookies instead", systemImage: "doc.on.clipboard")
            }
            if !app.accounts.isEmpty {
                Button("Log out all accounts (iPhone and Watch)", role: .destructive) {
                    Task { @MainActor in await app.logout() }
                }
            }
        } header: {
            Text("Accounts")
        } footer: {
            if app.accounts.isEmpty {
                Text("Your X session cookies are stored only in the Keychain on this iPhone and on your Watch.")
            } else {
                Text("Tap an account to use it on this iPhone; swipe left to remove it. Your Watch keeps its own active account. Session cookies are stored only in the Keychain on these devices.")
            }
        }
    }

    private func accountRow(_ account: XAccount) -> some View {
        let isActive = account.id == app.activeAccountId
        // The signed-in profile is cached in the account; the viewer covers the brief
        // window right after launch or a switch while `loadViewer()` is in flight.
        let user = account.user ?? (isActive ? app.viewer : nil)
        return Button {
            guard !isActive else { return }
            Task { @MainActor in await app.switchAccount(to: account.id) }
        } label: {
            AccountRowView(user: user, isActive: isActive)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { @MainActor in await app.removeAccount(account.id) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var watchSection: some View {
        Section {
            LabeledContent("Status", value: sync.statusText)
            if let d = sync.lastSent {
                LabeledContent("Last sync", value: d.formatted(date: .omitted, time: .shortened))
            }
            if let e = sync.messageErrorText {
                LabeledContent("Live delivery", value: e)
            }
            // The free-account signature expires every 7 days; the app then stops
            // launching. Say it here, before it happens.
            if let signature = ProvisioningInfo.reminder() {
                LabeledContent("Signature") {
                    Text(signature)
                        .foregroundStyle(ProvisioningInfo.isUrgent() ? Color.orange : Color.secondary)
                }
            }
            Button("Sync to Watch now") { sync.syncNow() }
                .disabled(!app.isLoggedIn)
            Button("Reset sync") { sync.resetSync() }
                .disabled(!app.isLoggedIn)
        } header: {
            Text("Apple Watch")
        } footer: {
            Text("Reset sync resends the account, endpoints and signing key and makes the Watch accept them again — use it if the Watch shows an old account or keeps asking you to log in.")
        }
    }

    private var endpointsSection: some View {
        Section {
            LabeledContent("Query IDs from", value: app.endpointsUpdatedAt.isEmpty ? "bundled" : String(app.endpointsUpdatedAt.prefix(16)))
            LabeledContent("Signing key", value: app.materialSummary)
            Button("Refresh endpoints") {
                Task {
                    do { try await app.refreshEndpoints(); alert = "Endpoints updated and sent to Watch." }
                    catch { alert = XError.from(error).localizedDescription }
                }
            }
            Button("Refresh signing key") {
                Task {
                    do { try await app.refreshMaterial(); alert = "Signing key updated (\(app.materialSummary))." }
                    catch { alert = "Couldn't refresh: \(error.localizedDescription)" }
                }
            }
            .disabled(!app.isLoggedIn)
            TextField("Remote endpoints.json URL (optional)", text: $overrideURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await app.setRemoteOverride(overrideURL) } }
        } header: {
            Text("X endpoints")
        } footer: {
            Text("Perch reads X's current GraphQL query IDs from x.com's web app. A remote override (e.g. the raw endpoints.json in your GitHub repo) is checked first.")
        }
    }
}

/// One X login in the iPhone account picker.
private struct AccountRowView: View {
    let user: XUser?
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let user {
                    Avatar(user: user, size: 40)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(user?.name ?? "X account")
                    .font(.headline)
                    .lineLimit(1)
                Text(user.map { "@" + $0.screenName } ?? "Profile not loaded yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Active on this iPhone")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

/// Simple fallback viewer on the iPhone.
struct PhoneTimelineView: View {
    @EnvironmentObject private var app: AppModel
    @State private var kind: HomeKind = .following
    @StateObject private var list = PagedList<TimelineItem>(fetch: { _ in ([], nil, nil) })

    var body: some View {
        List {
            Picker("Timeline", selection: $kind) {
                Text("Following").tag(HomeKind.following)
                Text("For You").tag(HomeKind.forYou)
            }
            .pickerStyle(.segmented)
            if let e = list.error, list.isEmpty {
                ErrorStateView(error: e) { await list.refresh() }
            }
            ForEach(list.items) { item in
                ForEach(item.tweets) { t in
                    TweetRow(tweet: t)
                }
                .onAppear { list.loadMoreIfNeeded(current: item) }
            }
            LoadMoreRow(isLoading: list.isLoading, reachedEnd: list.reachedEnd || list.isEmpty) { list.loadMore() }
        }
        .listStyle(.plain)
        .navigationTitle("Home")
        .refreshable { await list.refresh() }
        .task(id: kind) {
            let client = app.client
            let k = kind
            list.reset()                 // drop the other timeline's rows, cursor and error
            list.fetch = { cursor in
                let p = try await client.homeTimeline(k, cursor: cursor)
                return (p.items, p.bottomCursor, p.topCursor)
            }
            list.skip = { $0.isFiller }
            await list.refresh()
        }
    }
}

extension AppModel.LoginOutcome {
    /// What the login sheet shows; nil = verified, close the sheet.
    var message: String? {
        switch self {
        case .verified: return nil
        case .rejected: return "X rejected that session. Log in again."
        case .unverified(let e):
            return "Saved, but X couldn't confirm it yet (\(e.localizedDescription)). Perch will retry; you can close this."
        }
    }
}
