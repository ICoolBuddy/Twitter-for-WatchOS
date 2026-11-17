import SwiftUI
import XKit

/// The hamburger menu. Owns its own navigation stack so Settings, Likes,
/// Bookmarks and Notifications open inside the menu, and closes on selection of
/// a timeline so the feed is immediately visible again.
struct MenuView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PerchSettings.homeKind) private var kindRaw = HomeKind.following.rawValue

    @State private var path = NavigationPath()
    @State private var showAccounts = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    accountRow
                }

                Section("Timeline") {
                    kindRow(.following)
                    kindRow(.forYou)
                }

                Section {
                    NavigationLink(value: Route.notifications) {
                        HStack {
                            Label("Notifications", systemImage: "bell")
                            Spacer(minLength: 2)
                            if app.badge.notifications > 0 {
                                Text(app.badge.notifications > 99 ? "99+" : "\(app.badge.notifications)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.blue, in: Capsule())
                            }
                        }
                    }

                    NavigationLink(value: Route.likes) {
                        Label("Likes", systemImage: "heart")
                    }

                    NavigationLink(value: Route.bookmarks) {
                        Label("Bookmarks", systemImage: "bookmark")
                    }
                }

                Section {
                    NavigationLink(value: Route.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Menu")
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showAccounts) {
            AccountPicker()
        }
        .task {
            await app.loadViewer()
            await app.refreshBadge()
        }
    }

    @ViewBuilder
    private var accountRow: some View {
        if let account = app.activeAccount {
            Button {
                showAccounts = true
            } label: {
                HStack(spacing: 6) {
                    if let u = account.user {
                        Avatar(user: u, size: 30)
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.user?.name ?? "Account")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text("@" + (account.user?.screenName ?? String(account.id.prefix(8))))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "person.2.circle")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if let viewer = app.viewer {
            Button {
                showAccounts = true
            } label: {
                HStack(spacing: 6) {
                    Avatar(user: viewer, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(viewer.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text("@" + viewer.screenName)
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "person.2.circle").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Text("No account").foregroundStyle(.secondary)
        }
    }

    private func kindRow(_ kind: HomeKind) -> some View {
        Button {
            kindRaw = kind.rawValue
            dismiss()
        } label: {
            HStack {
                Text(kind == .forYou ? "For You" : "Following")
                Spacer()
                if kindRaw == kind.rawValue {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// All accounts known on the Watch. Tapping one makes it active on this device.
struct AccountPicker: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var switching: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.accounts) { account in
                    Button {
                        select(account)
                    } label: {
                        HStack(spacing: 6) {
                            if let u = account.user {
                                Avatar(user: u, size: 30)
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(account.user?.name ?? "Account")
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                Text("@" + (account.user?.screenName ?? String(account.id.prefix(8))))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 2)
                            if switching == account.id {
                                ProgressView()
                            } else if account.id == app.activeAccountId {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(switching != nil)
                }

                if app.accounts.isEmpty {
                    Text("No accounts yet.")
                        .foregroundStyle(.secondary)
                }

                Text("Add or remove accounts on your iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func select(_ account: XAccount) {
        guard switching == nil else { return }
        if account.id == app.activeAccountId {
            dismiss()
            return
        }
        switching = account.id
        Task {
            await app.switchAccount(to: account.id)
            switching = nil
            dismiss()
        }
    }
}
