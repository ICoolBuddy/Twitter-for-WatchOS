import SwiftUI
import XKit

/// The menu page, left of the feeds in the root `TabView`; the hamburger button
/// switches to it and swiping right on a feed reveals it. It uses the root
/// `NavigationStack`, so Settings, Likes, Bookmarks and Notifications push over
/// the menu. Choosing a timeline (or switching account) swipes back to its feed.
struct MenuView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var posts = AppModel.shared.posts

    /// This page is the one the root pager shows (crown focus follows it).
    /// Switches the root pager to the feed page for that timeline.
    var onPick: (HomeKind) -> Void = { _ in }

    @State private var showAccounts = false
    @State private var posting = false
    @State private var postStatus: String?
    /// A post that failed to send, kept so it can be retried without dictating again.
    @State private var failedPost: String?
    /// A draft over the limit: retrying cannot succeed, so it is shown as "not sent"
    /// with a Discard action instead of a button that can never work.
    @State private var tooLongMessage: String?

    var body: some View {
        List {
            Section {
                accountRow
            }

            Section {
                composeRow
                NavigationLink(value: Route.search) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.swipeSafeRow)
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
                .buttonStyle(.swipeSafeRow)
                // crown-lab: a stable handle for the pushed-list tests.
                .accessibilityIdentifier("menu.notifications")

                NavigationLink(value: Route.likes) {
                    Label("Likes", systemImage: "heart")
                }
                .buttonStyle(.swipeSafeRow)
                .accessibilityIdentifier("menu.likes")

                NavigationLink(value: Route.bookmarks) {
                    Label("Bookmarks", systemImage: "bookmark")
                }
                .buttonStyle(.swipeSafeRow)
                .accessibilityIdentifier("menu.bookmarks")

                NavigationLink(value: Route.saved) {
                    Label("Saved", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.swipeSafeRow)
            }

            if posts.pendingCount > 0 {
                Section {
                    Text("\(posts.pendingCount) action\(posts.pendingCount == 1 ? "" : "s") will send when you are online")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink(value: Route.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.swipeSafeRow)
            }
        }
        // No navigationTitle: the root navigation bar only carries the pager's
        // back/hamburger button, and the menu is recognisable by its content.
        // crown-lab measurement hook (DEBUG only): `probe.menu`.
        .crownProbe("menu")
        .sheet(isPresented: $showAccounts) {
            // Switching opens the new account on For You; leaving the picker without
            // switching (Done, the current account, swipe back) stays on the menu.
            AccountPicker(onSwitched: {
                showAccounts = false
                onPick(.forYou)
            }, onClosed: {
                showAccounts = false
            })
        }
        .task {
            if failedPost == nil, DraftStore.failed(replyTo: nil) != nil {
                if DraftStore.isTooLong(nil) {
                    tooLongMessage = "Draft is too long — not sent"
                } else {
                    failedPost = DraftStore.failed(replyTo: nil)
                }
            }
            await app.refreshBadge()
        }
    }

    /// "New post": the system text input opens directly; the post is sent as
    /// soon as it is submitted. A failure keeps the text for a retry.
    @ViewBuilder
    private var composeRow: some View {
        TextFieldLink(prompt: Text("What's happening?")) {
            Label(posting ? "Posting…" : (postStatus ?? "New post"), systemImage: "square.and.pencil")
        } onSubmit: { text in
            publish(text)
        }
        .buttonStyle(.swipeSafeRow)
        .disabled(posting)
        if let failedPost, !posting {
            Button {
                publish(failedPost)
            } label: {
                Label("Post failed. Tap to retry", systemImage: "arrow.clockwise")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.swipeSafeRow)
        }
        if let tooLongMessage, !posting {
            // The system text input cannot be pre-filled and nothing on the iPhone reads
            // this draft, so the honest actions are "know it failed" or "throw it away".
            Text(tooLongMessage)
                .font(.caption2)
                .foregroundStyle(.orange)
            Button {
                DraftStore.clear(replyTo: nil)
                self.tooLongMessage = nil
                postStatus = nil
            } label: {
                Label("Discard draft", systemImage: "trash")
                    .font(.caption2)
            }
            .buttonStyle(.swipeSafeRow)
        }
    }

    private func publish(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !posting else { return }
        if let why = TweetText.tooLong(body) {
            postStatus = nil
            failedPost = nil
            tooLongMessage = why
            DraftStore.saveFailed(body, replyTo: nil, tooLong: true)
            return
        }
        tooLongMessage = nil
        DraftStore.saveFailed(body, replyTo: nil)   // until it lands
        posting = true
        Task {
            do {
                _ = try await app.client.createTweet(text: body, replyTo: nil)
                Haptics.success()
                failedPost = nil
                DraftStore.clear(replyTo: nil)
                posting = false
                postStatus = "Posted"
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                postStatus = nil
            } catch {
                Haptics.failure()
                posting = false
                failedPost = body
                DraftStore.saveFailed(body, replyTo: nil)
            }
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
            .buttonStyle(.swipeSafe)
            .frame(maxWidth: .infinity)
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
            .buttonStyle(.swipeSafe)
            .frame(maxWidth: .infinity)
        } else {
            Text("No account").foregroundStyle(.secondary)
        }
    }

}

/// All accounts known on the Watch. Tapping one makes it active on this device,
/// closes the picker and returns to the feed.
struct AccountPicker: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Called after a switch to another account (the menu returns to For You).
    var onSwitched: (() -> Void)? = nil
    /// Called when the picker closes without a switch (stay on the menu).
    var onClosed: (() -> Void)? = nil

    @State private var switching: String?
    /// `finish` already reported how the picker closed (swipe-back reports in onDisappear).
    @State private var didFinish = false
    /// `switchAccount` cannot throw; if the active account did not change, say so.
    @State private var switchError: String?

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
                    .buttonStyle(.swipeSafe)
                    .frame(maxWidth: .infinity)
                    .disabled(switching != nil)
                }

                if app.accounts.isEmpty {
                    Text("No accounts yet.")
                        .foregroundStyle(.secondary)
                }

                if let switchError {
                    Text(switchError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Text("Add or remove accounts on your iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Accounts")
            // Swiping right closes the picker, like the other screens (same as Done).
            .swipeBack()
            .onDisappear { if switching == nil, !didFinish { onClosed?() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { finish() }
                }
            }
        }
    }

    private func select(_ account: XAccount) {
        guard switching == nil else { return }
        if account.id == app.activeAccountId {
            finish()
            return
        }
        switching = account.id
        switchError = nil
        Task {
            await app.switchAccount(to: account.id)
            switching = nil
            if app.activeAccountId == account.id {
                finish(switched: true)
            } else {
                switchError = "Couldn't switch account. Try again."
            }
        }
    }

    private func finish(switched: Bool = false) {
        didFinish = true
        dismiss()
        if switched { onSwitched?() } else { onClosed?() }
    }
}
