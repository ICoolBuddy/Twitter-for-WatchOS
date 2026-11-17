import SwiftUI
import XKit

struct WatchSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var sync: WatchSync
    @AppStorage(PerchSettings.autoRefreshOnOpen) private var autoRefreshOnOpen = true

    @State private var message: String?
    @State private var working = false
    @State private var confirmLogout = false

    var body: some View {
        List {
            Section("Account") {
                if let u = app.activeAccount?.user ?? app.viewer {
                    NavigationLink(value: Route.profileMe) {
                        UserRow(user: u)
                    }
                } else if app.isLoggedIn {
                    Label("Logged in", systemImage: "checkmark.circle")
                } else {
                    Text("Not logged in").foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Refresh when opening", isOn: $autoRefreshOnOpen)
            } footer: {
                Text("When off, the feed shows cached posts until you pull to refresh.")
            }

            Section("iPhone") {
                Text(sync.statusText).font(.caption2)
                Button {
                    sync.syncNow()
                } label: {
                    Text("Sync from iPhone").frame(maxWidth: .infinity)
                }
            }

            Section {
                Text("IDs: \(app.endpointsUpdatedAt.isEmpty ? "bundled" : String(app.endpointsUpdatedAt.prefix(10)))")
                    .font(.caption2)
                Text("Key: \(app.materialSummary)").font(.caption2)
                Button {
                    run { try await app.refreshEndpoints(scrape: true) }
                } label: {
                    Text(working ? "Working…" : "Refresh endpoints")
                        .frame(maxWidth: .infinity)
                }
                .disabled(working)
                Button {
                    run { try await app.refreshMaterial() }
                } label: {
                    Text("Refresh signing key")
                        .frame(maxWidth: .infinity)
                }
                .disabled(working || !app.isLoggedIn)
            } header: {
                Text("X endpoints")
            } footer: {
                Text("Refreshing on the iPhone is faster; the Watch can do it on its own if needed.")
            }
            if let message {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("Request log", value: Route.debugLog)
                if app.isLoggedIn {
                    Button(role: .destructive) {
                        confirmLogout = true
                    } label: {
                        Text("Log out").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .task { await app.loadViewer() }
        .confirmationDialog("Log out of Perch on Watch and iPhone?", isPresented: $confirmLogout) {
            Button("Log out", role: .destructive) { Task { await app.logout() } }
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            working = true
            message = nil
            defer { working = false }
            do {
                try await op()
                message = "Done."
                Haptics.success()
            } catch {
                message = XError.from(error).localizedDescription
                Haptics.failure()
            }
        }
    }
}
