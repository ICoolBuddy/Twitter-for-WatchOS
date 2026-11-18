import SwiftUI
import XKit

/// Notifications list with infinite scroll. The first page clears the unread
/// badge (`app.clearNotificationBadge(topCursor:)`).
struct NotificationsView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var list = PagedList<XNotification>(maxItems: 300, fetch: { _ in ([], nil, nil) })
    @State private var configuredKey: String?
    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PagedListStatus(list: list, emptyText: "No notifications yet.")

                ForEach(list.items) { n in
                    NotificationRow(notification: n,
                                    onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                                    onMedia: { mediaTarget = $0 })
                        .paginates(list, with: n)
                    PostSeparator()
                }

                PagingFooter(list: list)
            }
            .padding(.horizontal, Metrics.horizontalPadding)
        }
        .pagedListChrome(list, onRefresh: { await list.refresh() },
                         profile: $profileTarget, media: $mediaTarget)
        .navigationTitle("Notifications")
        // crown-lab measurement hook (DEBUG only): `probe.notifications`.
        .crownProbe("notifications")
        .task(id: taskKey) {
            configure()
            await list.loadIfNeeded()
        }
        .swipeBack()
    }

    private var taskKey: String {
        "\(app.isLoggedIn)-\(app.activeAccountId ?? "none")"
    }

    private func configure() {
        guard configuredKey != taskKey else { return }
        configuredKey = taskKey
        list.reset()
        let client = app.client
        list.fetch = { cursor in
            let p = try await client.notifications(.all, cursor: cursor)
            return (p.notifications, p.bottomCursor, p.topCursor)
        }
        list.onFirstPage = { _, top in
            guard let top else { return }
            Task { await app.clearNotificationBadge(topCursor: top) }
        }
    }
}

/// One notification: icon, the users' avatars, the text and a snippet of the
/// tweet it refers to.
struct NotificationRow: View {
    let notification: XNotification
    var onOpenProfile: ((XUser) -> Void)? = nil
    var onMedia: ((MediaTarget) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                if notification.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Unread")
                }
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                ForEach(Array(notification.users.prefix(3))) { u in
                    Button { onOpenProfile?(u) } label: { Avatar(user: u, size: 24) }
                        .buttonStyle(.swipeSafe)
                        .accessibilityLabel("Open @\(u.screenName) profile")
                }
                if notification.users.count > 3 {
                    Text("+\(notification.users.count - 3)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let d = notification.date {
                    Text(RelativeTime.short(d))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let t = notification.tweet {
                // Tapping the notification (text or snippet) opens the post page.
                NavigationLink(value: Route.post(IdentifiedRoute(t))) {
                    VStack(alignment: .leading, spacing: 4) {
                        textLabel
                        tweetSnippet(t)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.swipeSafe)

                if !t.media.isEmpty, let onMedia {
                    Button {
                        onMedia(MediaTarget(media: t.media, startIndex: 0,
                                            title: t.author.name, caption: t.text))
                    } label: {
                        MediaThumb(media: t.media[0], extraCount: t.media.count - 1, maxHeight: 90)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.swipeSafe)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Open media")
                }
            } else {
                // Digest notifications ("new post notifications from @user") have
                // no tweet: open that account's posts as a feed instead.
                if let user = notification.users.first {
                    NavigationLink(value: Route.userFeed(IdentifiedRoute(user))) {
                        textLabel
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.swipeSafe)
                } else {
                    textLabel
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var textLabel: some View {
        Text(notification.text)
            .font(.system(size: 15))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tweetSnippet(_ t: XTweet) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(t.author.name) @\(t.author.screenName)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(t.text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var symbol: String {
        let icon = (notification.icon ?? "").lowercased()
        if icon.contains("heart") || icon.contains("like") { return "heart.fill" }
        if icon.contains("reply") || icon.contains("mention") { return "bubble.left.fill" }
        if icon.contains("retweet") || icon.contains("repost") { return "arrow.2.squarepath" }
        if icon.contains("follow") || icon.contains("person") || icon.contains("user") { return "person.badge.plus" }
        if icon.contains("star") { return "star.fill" }
        return "bell.fill"
    }

    private var color: Color {
        let icon = (notification.icon ?? "").lowercased()
        if icon.contains("heart") || icon.contains("like") { return .pink }
        if icon.contains("reply") || icon.contains("mention") { return .blue }
        if icon.contains("retweet") || icon.contains("repost") { return .green }
        if icon.contains("follow") || icon.contains("person") { return .blue }
        return Color.secondary
    }
}
