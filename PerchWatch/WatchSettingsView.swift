import SwiftUI
import XKit

struct WatchSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var sync: WatchSync
    @AppStorage(PerchSettings.autoRefreshOnOpen) private var autoRefreshOnOpen = true
    @AppStorage(PerchSettings.textSize) private var textSizeRaw = PerchTextSize.medium.rawValue
    @AppStorage(PerchSettings.backgroundVideo) private var backgroundVideo = true

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
                    .buttonStyle(.swipeSafeRow)
                } else if app.isLoggedIn {
                    Label("Logged in", systemImage: "checkmark.circle")
                } else {
                    Text("Not logged in").foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Refresh when opening", isOn: $autoRefreshOnOpen)
                Picker("Text size", selection: $textSizeRaw) {
                    ForEach(PerchTextSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
            } header: {
                Text("Feed")
            } footer: {
                Text("When off, the feed shows cached posts until you pull to refresh.")
            }

            Section {
                Toggle("Background playback", isOn: $backgroundVideo)
            } header: {
                Text("Videos")
            } footer: {
                Text("Videos keep playing when you lower your wrist or leave Perch, with controls in Now Playing. watchOS plays background audio only through Bluetooth headphones or speakers.")
            }

            Section("iPhone") {
                Text(sync.statusText).font(.caption2)
                // Diagnostics: is the complication's shared container available on this
                // (sideloaded) build, and how big was the last sync.
                Text("App Group: \(AppGroup.identifier ?? "none (complication off)")")
                    .font(.caption2).foregroundStyle(.secondary)
                if sync.lastPayloadBytes > 0 {
                    Text("Last payload: \(ByteCountFormatter.string(fromByteCount: Int64(sync.lastPayloadBytes), countStyle: .file))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button(action: SwipeGuard.run {
                    sync.syncNow()
                }) {
                    Text("Sync from iPhone").frame(maxWidth: .infinity)
                }
            }

            Section {
                Text("IDs: \(app.endpointsUpdatedAt.isEmpty ? "bundled" : String(app.endpointsUpdatedAt.prefix(10)))")
                    .font(.caption2)
                Text("Key: \(app.materialSummary)").font(.caption2)
                Button(action: SwipeGuard.run {
                    run { try await app.refreshEndpoints(scrape: true) }
                }) {
                    Text(working ? "Working…" : "Refresh endpoints")
                        .frame(maxWidth: .infinity)
                }
                .disabled(working)
                Button(action: SwipeGuard.run {
                    run { try await app.refreshMaterial() }
                }) {
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
                    .buttonStyle(.swipeSafeRow)
                if app.isLoggedIn {
                    Button(role: .destructive, action: SwipeGuard.run {
                        confirmLogout = true
                    }) {
                        Text("Log out").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .swipeBack()
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
