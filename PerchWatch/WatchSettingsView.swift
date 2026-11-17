import SwiftUI
import XKit

struct WatchSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var sync: WatchSync
    @State private var message: String?
    @State private var working = false
    @State private var confirmLogout = false

    var body: some View {
        List {
            Section("Account") {
                if let v = app.viewer {
                    UserRow(user: v)
                } else if app.isLoggedIn {
                    Label("Logged in", systemImage: "checkmark.circle")
                } else {
                    Text("Not logged in").foregroundStyle(.secondary)
                }
                Toggle("Demo mode", isOn: $app.demoMode)
            }
            Section("iPhone") {
                Text(sync.statusText).font(.caption2)
                Button("Sync from iPhone") { sync.syncNow() }
            }
            Section {
                Text("IDs: \(app.endpointsUpdatedAt.isEmpty ? "bundled" : String(app.endpointsUpdatedAt.prefix(10)))")
                    .font(.caption2)
                Text("Key: \(app.materialSummary)").font(.caption2)
                Button(working ? "Working…" : "Refresh endpoints") {
                    run { try await app.refreshEndpoints(scrape: true) }
                }
                .disabled(working)
                Button("Refresh signing key") {
                    run { try await app.refreshMaterial() }
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
                    Button("Log out", role: .destructive) { confirmLogout = true }
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
