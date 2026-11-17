import SwiftUI
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
    @State private var replyTarget: XTweet?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let u = user {
                    banner(u)
                    profileHeader(u)
                    if !u.bio.isEmpty {
                        Text(u.bio)
                            .font(.system(size: 15))
                            .fixedSize(horizontal: false, vertical: true)
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
        .background(Color.black)
        .task { await start(force: false) }
        .postPresentation(profile: $otherProfile, media: $mediaTarget, reply: $replyTarget)
    }

    // MARK: Header

    @ViewBuilder
    private func banner(_ u: XUser) -> some View {
        if let b = u.bannerURL {
            RemoteImage(url: b, maxPixel: 300)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .clipped()
        } else {
            Color.white.opacity(0.06)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
        }
    }

    private func profileHeader(_ u: XUser) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Avatar(user: u, size: 56)
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
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private func countsRow(_ u: XUser) -> some View {
        HStack(alignment: .top, spacing: 4) {
            metric(u.postsCount, "Posts")
            metric(u.followingCount, "Following")
            metric(followers, "Followers")
        }
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
            .disabled(followBusy)
            .tint(following ? Color.gray : Color.accentColor)
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
                             onMedia: { mediaTarget = $0 },
                             onReply: { replyTarget = $0 })
                .onAppear { list.loadMoreIfNeeded(current: item) }
            PostSeparator()
        }
        if list.isLoading && !list.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
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
            if let fresh { apply(fresh) }
            if let u = user {
                configurePosts(u.id)
                await list.loadIfNeeded()
            } else if fresh == nil {
                self.error = .network("No profile to load")
            }
        } catch {
            self.error = XError.from(error)
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
