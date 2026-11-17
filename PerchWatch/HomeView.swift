import Foundation
import SwiftUI
import XKit

/// One home timeline, Parrot style: pure black, no platters, big 19 pt text,
/// full-width media. Infinite scroll, pull- or crown-to-refresh, opens instantly
/// from the on-disk cache. `RootPager` shows one of these per timeline (For You,
/// Following) so swiping between them never reloads anything.
struct HomeView: View {
    let kind: HomeKind

    @EnvironmentObject private var app: AppModel
    @AppStorage(PerchSettings.autoRefreshOnOpen) private var autoRefreshOnOpen = true

    @StateObject private var list = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    @State private var configuredFor: String?
    @State private var startedFor: String?
    /// 0…1: how far a pull/crown turn is towards a refresh (drives the edge glow).
    @State private var pullProgress: CGFloat = 0
    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?

    private var taskKey: String {
        "\(kind.rawValue)-\(app.isLoggedIn)-\(app.activeAccountId ?? "none")"
    }

    var body: some View {
        // `ScrollViewReader` instead of `.scrollPosition(id:)`: that binding is
        // rewritten by the system on every scroll and re-applied on every list
        // update, so the feed jumped back to a stale post after refreshes and
        // while pages loaded. We only scroll explicitly, once, when the reader
        // asks for a refresh.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    timelineLabel
                    content
                }
                .padding(.horizontal, Metrics.horizontalPadding)
            }
            .background(Color.black)
            // Loading look: a soft glow around the screen edge (Pigeon-style)
            // instead of a bar with numbers inside the feed.
            .overlay {
                EdgeGlow(progress: pullProgress,
                         loading: (list.isRefreshing || list.isLoading) && !list.isEmpty)
                    .allowsHitTesting(false)
            }
            .pullToRefresh(isRefreshing: list.isRefreshing, progress: $pullProgress) {
                await refresh(proxy, merge: false)
            }
            .task(id: taskKey) {
                configure()
                await start(proxy)
            }
            .postPresentation(profile: $profileTarget, media: $mediaTarget)
            .onDisappear { list.cancel() }
        }
    }

    /// Which timeline this page is (the menu no longer lists them; the pager's
    /// swipes decide, so the label says where you are).
    private var timelineLabel: some View {
        Text(kind == .forYou ? "FOR YOU" : "FOLLOWING")
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
            .padding(.bottom, 6)
            .accessibilityLabel(kind == .forYou ? "For You timeline" : "Following timeline")
    }

    @ViewBuilder
    private var content: some View {
        if let e = list.error, list.isEmpty {
            ErrorStateView(error: e) { await list.refresh() }
                .padding(.vertical, 16)
        } else if list.isEmpty && list.isLoading {
            VStack(spacing: 12) {
                PostSkeleton(mediaHeight: 130)
                PostSkeleton(mediaHeight: 110)
                PostSkeleton(mediaHeight: 150)
            }
            .padding(.vertical, 4)
        } else if list.isEmpty {
            emptyState
        } else {
            ForEach(list.items) { item in
                VStack(alignment: .leading, spacing: 0) {
                    TimelineItemRows(item: item,
                                     onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                                     onMedia: { mediaTarget = $0 })
                        .onAppear { list.loadMoreIfNeeded(current: item) }
                    if item.id != list.items.last?.id { PostSeparator() }
                }
                .id(item.id)
            }
            if let e = list.error {
                Text(e.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bird")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No posts yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Pull down or turn the crown to refresh.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func configure() {
        let key = taskKey
        guard configuredFor != key else { return }
        configuredFor = key
        list.reset()

        let client = app.client
        let k = kind
        let cacheName = app.timelineCacheName(k)
        list.fetch = { cursor in
            let p = try await client.homeTimeline(k, cursor: cursor)
            return (p.items, p.bottomCursor, p.topCursor)
        }
        list.onFirstPage = { items, _ in
            TimelineDiskCache.save(items, name: cacheName)
        }
        list.onPage = { items in
            ImageLoader.shared.prefetchFeed(items.displayTweets)
        }
        list.skip = { $0.isFiller }
        list.seed(TimelineDiskCache.load(name: cacheName))
    }

    /// Show the cached feed immediately; only go to the network when
    /// "Refresh when opening the app" is on, or when there is no cache at all.
    /// Runs once per account/kind so closing a sheet does not re-fetch.
    private func start(_ proxy: ScrollViewProxy) async {
        guard startedFor != taskKey else { return }
        startedFor = taskKey
        if list.isEmpty {
            await refresh(proxy, merge: true)
        } else if autoRefreshOnOpen {
            // Merge, so posts that are already on screen are never reordered or
            // dropped: only new ones appear above them.
            await refresh(proxy, merge: true)
        }
    }

    private func refresh(_ proxy: ScrollViewProxy, merge: Bool) async {
        await list.refresh(merge: merge)
        // Offline taps (like/repost/bookmark) go out as soon as we are online.
        await app.posts.flush(client: app.client)
        // A refresh the reader asked for (pull / crown) brings them to the top;
        // the silent one on open leaves the scroll position alone.
        guard !merge, !list.items.isEmpty else { return }
        // The list has to lay out its first row before `scrollTo` can find it.
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !list.items.isEmpty else { return }
        proxy.scrollTo(list.items[0].id, anchor: .top)
    }
}

/// Loading look: a soft bar glowing around the screen edge (like Pigeon for
/// Telegram). It brightens as a pull/crown turn fills up, then pulses while the
/// feed loads; there is no progress text.
struct EdgeGlow: View {
    var progress: CGFloat = 0
    var loading: Bool = false

    @State private var pulse = false

    private var visible: Bool { loading || progress > 0.03 }

    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(Color.white, lineWidth: 2)
            .blur(radius: 3)
            .padding(2)
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.2), value: visible)
            .onAppear { startPulse() }
            .onChange(of: loading) { _, _ in startPulse() }
    }

    private var opacity: Double {
        guard visible else { return 0 }
        if loading { return pulse ? 0.8 : 0.28 }
        return 0.2 + 0.55 * Double(min(1, max(0, progress)))
    }

    private func startPulse() {
        pulse = false
        guard loading else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
