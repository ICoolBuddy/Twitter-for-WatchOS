import Foundation
import SwiftUI
import XKit

/// Home timeline, Parrot style: pure black, no platters, big 19 pt text,
/// full-width media. Infinite scroll, pull to refresh, opens instantly from the
/// on-disk cache. The menu lives one page to the right (see `RootPager`), which
/// also owns the hamburger button.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage(PerchSettings.autoRefreshOnOpen) private var autoRefreshOnOpen = true
    @AppStorage(PerchSettings.homeKind) private var kindRaw = HomeKind.following.rawValue

    @StateObject private var list = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    @State private var configuredFor: String?
    @State private var startedFor: String?
    /// False once the reader scrolls away from the top. A refresh that lands
    /// afterwards must not replace the list under them (that jumped the feed).
    @State private var atTop = true
    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?

    private var kind: HomeKind { HomeKind(rawValue: kindRaw) ?? .following }

    private var taskKey: String {
        "\(kindRaw)-\(app.isLoggedIn)-\(app.activeAccountId ?? "none")"
    }

    var body: some View {
        // `ScrollViewReader` instead of `.scrollPosition(id:)`: that binding is
        // rewritten by the system on every scroll and re-applied on every list
        // update, so the feed jumped back to a stale post after refreshes and
        // while pages loaded. We only scroll explicitly, once, when a refresh
        // has brought a new first post.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, Metrics.horizontalPadding)
            }
            .background(Color.black)
            .pullToRefresh(isRefreshing: list.isRefreshing, atTop: $atTop) { await refresh(proxy) }
            // Fixed height: the status line appears and disappears as pages load,
            // and a safe-area inset that changes height moves the whole feed.
            .safeAreaInset(edge: .top, spacing: 0) {
                LoadingStatusLine(active: (list.isRefreshing || list.isLoading) && !list.isEmpty)
                    .frame(height: 14)
            }
            .task(id: taskKey) {
                configure()
                await start(proxy)
            }
            .postPresentation(profile: $profileTarget, media: $mediaTarget)
            .onDisappear { list.cancel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let e = list.error, list.isEmpty {
            ErrorStateView(error: e) { await list.refresh() }
                .padding(.vertical, 16)
        } else if list.isEmpty && list.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
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
            Text("Pull down to refresh.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        list.seed(TimelineDiskCache.load(name: cacheName))
    }

    /// Show the cached feed immediately; only go to the network when
    /// "Refresh when opening the app" is on, or when there is no cache at all.
    /// Runs once per account/kind so closing a sheet does not re-fetch.
    private func start(_ proxy: ScrollViewProxy) async {
        guard startedFor != taskKey else { return }
        startedFor = taskKey
        if list.isEmpty {
            await refresh(proxy)
        } else if autoRefreshOnOpen {
            await refresh(proxy)
        }
    }

    private func refresh(_ proxy: ScrollViewProxy) async {
        await list.refresh(applyIf: { atTop })
        // Only follow the new first post when the reader is still at the top
        // (pull-to-refresh, or the first load). If they already scrolled, the
        // list was kept as-is above and there is nothing to move.
        guard atTop, !list.items.isEmpty else { return }
        // The list has to lay out its first row before `scrollTo` can find it.
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard atTop, !list.items.isEmpty else { return }
        proxy.scrollTo(list.items[0].id, anchor: .top)
    }
}

/// Slim "Loading posts · 85 KB/s" line shown while the feed refreshes or loads
/// more. Polls the shared `TransferMonitor` every half second, only while active.
struct LoadingStatusLine: View {
    var active: Bool

    var body: some View {
        if active {
            TimelineView(.periodic(from: Date(), by: 0.5)) { _ in
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 2)
            .accessibilityLabel("Loading posts")
        }
    }

    private var label: String {
        let rate = TransferMonitor.shared.snapshot().bytesPerSecond
        guard rate >= 512 else { return "Loading posts" }
        return "Loading posts · " + TransferMonitor.formatRate(rate)
    }
}
