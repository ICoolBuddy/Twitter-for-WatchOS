import SwiftUI
import WatchKit
import XKit

/// Identifies a profile to show, either from a cached `XUser` or by id/handle.
struct ProfileTarget: Identifiable, Hashable {
    var userId: String? = nil
    var screenName: String? = nil
    var user: XUser? = nil

    var id: String {
        if let userId { return "id:" + userId }
        if let screenName { return "sn:" + screenName }
        if let user { return "u:" + user.id }
        return "unknown"
    }
}

/// The profile popup: banner, avatar, bio, counts, Follow button and recent
/// posts with infinite scroll. It owns a navigation stack so posts open inside it.
struct ProfileSheet: View {
    let target: ProfileTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProfileContent(target: target)
                .navigationTitle("Profile")
                // Swiping right on the profile itself closes the sheet. This sits
                // on the stack's root view, not on the whole stack: there it also
                // fired on a post pushed inside the sheet, so one swipe popped the
                // post *and* dismissed the sheet.
                .swipeBack()
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }
}

/// Same profile, pushed as a route (`.user`, `.userId`, `.profileMe`).
struct ProfileScreen: View {
    let target: ProfileTarget

    var body: some View {
        ProfileContent(target: target)
            .navigationTitle("Profile")
            .swipeBack()
    }
}

struct ProfileContent: View {
    let target: ProfileTarget

    @EnvironmentObject private var app: AppModel
    @StateObject private var list = PagedList<TimelineItem>(maxItems: 100, fetch: { _ in ([], nil, nil) })

    @State private var user: XUser?
    @State private var error: XError?
    @State private var loadingProfile = false
    @State private var started = false
    @State private var configuredFor: String?
    @State private var following = false
    @State private var followers = 0
    @State private var followBusy = false
    @State private var otherProfile: ProfileTarget?
    @State private var mediaTarget: MediaTarget?

    /// Full display width, so the banner is a true 3:1 strip edge to edge.
    private var bannerHeight: CGFloat {
        max(56, WKInterfaceDevice.current().screenBounds.width / 3)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let u = user {
                    banner(u)
                    nameBlock(u)
                    if !u.bio.isEmpty {
                        Text(u.bio)
                            .font(.system(size: 15))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    countsRow(u)
                    followButton
                    PostSeparator().padding(.vertical, 6)
                } else if loadingProfile {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }

                if let error, user == nil {
                    ErrorStateView(error: error) { await start(force: true) }
                        .padding(.vertical, 8)
                } else if let error, user != nil {
                    Text(error.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.vertical, 4)
                }

                if user != nil { postsSection }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
        }
        .crownScrollFocus()
        .background(Color.black)
        .task { await start(force: false) }
        .postPresentation(profile: $otherProfile, media: $mediaTarget)
    }

    // MARK: Header

    /// Black 3:1 strip (black when the user has no banner) with the avatar
    /// overlapping its bottom edge.
    private func banner(_ u: XUser) -> some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                Color.black
                if let b = u.bannerURL {
                    RemoteImage(url: b, maxPixel: 450, contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: bannerHeight)
            .clipped()

            Avatar(user: u, size: 58)
                .overlay(Circle().stroke(Color.black, lineWidth: 2))
                .offset(x: 2, y: 29)
        }
        .padding(.horizontal, -Metrics.horizontalPadding)
    }

    private func nameBlock(_ u: XUser) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(u.name)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                if u.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Verified")
                }
            }
            Text("@" + u.screenName)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Room for the lower half of the avatar that overlaps the banner.
        .padding(.top, 31)
    }

    private func countsRow(_ u: XUser) -> some View {
        HStack(alignment: .top, spacing: 4) {
            metric(u.postsCount, "Posts")
            metric(u.followingCount, "Following")
            metric(followers, "Followers")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private func metric(_ n: Int, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(n.compact)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var followButton: some View {
        if let u = user, !isSelf {
            Button {
                toggleFollow(u)
            } label: {
                HStack(spacing: 4) {
                    if followBusy { ProgressView() }
                    Text(following ? "Following" : "Follow")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(followBusy)
            .tint(following ? Color.gray : Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
    }

    private var isSelf: Bool {
        guard let u = user else { return false }
        return u.id == app.viewer?.id || u.id == app.activeAccount?.user?.id
    }

    // MARK: Posts

    @ViewBuilder
    private var postsSection: some View {
        if list.isEmpty && list.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        } else if list.isEmpty && !list.isLoading {
            Text("No posts yet.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        ForEach(list.items) { item in
            TimelineItemRows(item: item,
                             onOpenProfile: { otherProfile = ProfileTarget(user: $0) },
                             onMedia: { mediaTarget = $0 })
                .onAppear { list.loadMoreIfNeeded(current: item) }
            PostSeparator()
        }
        PagingFooter(isLoading: list.isLoading && !list.isEmpty && !list.isRefreshing,
                     error: list.isEmpty ? nil : list.error, retry: { list.retryMore() })
    }

    // MARK: Loading

    private func start(force: Bool) async {
        if started && !force { return }
        started = true
        if user == nil, let cached = target.user { apply(cached) }
        await loadProfile()
    }

    private func loadProfile() async {
        guard !loadingProfile else { return }
        loadingProfile = true
        error = nil
        defer { loadingProfile = false }
        if user == nil, let cached = OfflineCache.user(id: target.userId) ?? OfflineCache.user(screenName: target.screenName) {
            apply(cached)
            configurePosts(cached.id)
            await list.loadIfNeeded()
        }
        do {
            let client = app.client
            let fresh: XUser?
            if let id = target.userId {
                fresh = try await client.user(id: id)
            } else if let sn = target.screenName {
                fresh = try await client.user(screenName: sn)
            } else {
                fresh = nil
            }
            if let fresh {
                apply(fresh)
                OfflineCache.save(fresh)
            }
            if let u = user {
                configurePosts(u.id)
                await list.loadIfNeeded()
            } else if fresh == nil {
                self.error = .network("No profile to load")
            }
        } catch {
            // A cached profile + cached posts still make the page usable.
            if user == nil { self.error = XError.from(error) }
            if let u = user {
                configurePosts(u.id)
                await list.loadIfNeeded()
            }
        }
    }

    private func apply(_ u: XUser) {
        user = u
        following = u.following
        followers = u.followersCount
    }

    private func configurePosts(_ userId: String) {
        guard configuredFor != userId else { return }
        configuredFor = userId
        list.reset()
        let client = app.client
        list.fetch = { cursor in
            let p = try await client.userTweets(userId: userId, includeReplies: false, cursor: cursor)
            return (p.items, p.bottomCursor, p.topCursor)
        }
        list.onPage = { items in
            ImageLoader.shared.prefetchFeed(items.displayTweets)
        }
        list.onFirstPage = { items, _ in
            TimelineDiskCache.save(items, name: "profile-\(userId)")
        }
        list.skip = { $0.isFiller }
        list.seed(TimelineDiskCache.load(name: "profile-\(userId)"))
    }

    private func toggleFollow(_ u: XUser) {
        guard !followBusy else { return }
        let newValue = !following
        following = newValue
        followers = max(0, followers + (newValue ? 1 : -1))
        followBusy = true
        Task {
            do {
                try await app.client.setFollowing(newValue, userId: u.id)
                Haptics.click()
            } catch {
                following = !newValue
                followers = max(0, followers + (newValue ? -1 : 1))
                self.error = XError.from(error)
                Haptics.failure()
            }
            followBusy = false
        }
    }
}
