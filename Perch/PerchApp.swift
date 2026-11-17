import SwiftUI
import XKit

@main
struct PerchApp: App {
    @StateObject private var app = AppModel.shared
    @StateObject private var sync = PhoneSync.shared
    @Environment(\.scenePhase) private var scenePhase

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
                LoginSheet { creds in Task { await app.login(creds) } }
            }
            .alert("Perch", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alert ?? "")
            }
            .task {
                overrideURL = app.remoteOverrideURL?.absoluteString ?? ""
                await app.loadViewer()
            }
            .onChange(of: app.isLoggedIn) { _, _ in Task { await app.loadViewer() } }
        }
    }

    private var accountSection: some View {
        Section {
            if app.isLoggedIn {
                if let v = app.viewer {
                    HStack {
                        Avatar(user: v, size: 40)
                        VStack(alignment: .leading) {
                            Text(v.name).font(.headline)
                            Text("@" + v.screenName).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Label("Logged in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button("Log out (iPhone and Watch)", role: .destructive) {
                    Task { await app.logout() }
                }
            } else {
                Button {
                    showLogin = true
                } label: {
                    Label("Log in with X", systemImage: "person.crop.circle.badge.plus")
                }
                NavigationLink {
                    ManualLoginView { creds in Task { await app.login(creds) } }
                } label: {
                    Label("Paste cookies instead", systemImage: "doc.on.clipboard")
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Your X session cookies are stored only in the Keychain on this iPhone and on your Watch.")
        }
    }

    private var watchSection: some View {
        Section("Apple Watch") {
            LabeledContent("Status", value: sync.statusText)
            if let d = sync.lastSent {
                LabeledContent("Last sync", value: d.formatted(date: .omitted, time: .shortened))
            }
            Button("Sync to Watch now") { sync.syncNow() }
                .disabled(!app.isLoggedIn)
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
            list.fetch = { cursor in
                let p = try await client.homeTimeline(k, cursor: cursor)
                return (p.items, p.bottomCursor, p.topCursor)
            }
            await list.refresh()
        }
    }
}
