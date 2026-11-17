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
    /// 0…1: how far a pull/crown turn is towards a refresh (drives `FeedStatusBar`).
    @State private var pullProgress: CGFloat = 0
    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?
    /// Ids of the rows currently on screen; the hand double-tap scrolls from the
    /// topmost one. Cheap: a couple of entries change per swipe, not per frame.
    @State private var visibleIDs: Set<String> = []

    /// How many posts a hand double-tap advances (≈ two screens of normal posts).
    private static let pinchStep = 4

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
                    content
                }
                .padding(.horizontal, Metrics.horizontalPadding)
            }
            .background(Color.black)
            // Fixed height: the bar comes and goes, and a safe-area inset that
            // changes height would move the whole feed.
            .safeAreaInset(edge: .top, spacing: 0) {
                FeedStatusBar(loading: (list.isRefreshing || list.isLoading) && !list.isEmpty,
                              progress: pullProgress)
            }
            .pullToRefresh(isRefreshing: list.isRefreshing, progress: $pullProgress) {
                await refresh(proxy, merge: false)
            }
            .overlay(alignment: .bottomTrailing) {
                pinchButton(proxy)
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
                        .onScrollVisibilityChange { isVisible in
                            if isVisible { visibleIDs.insert(item.id) } else { visibleIDs.remove(item.id) }
                        }
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
        // A refresh the reader asked for (pull / crown) brings them to the top;
        // the silent one on open leaves the scroll position alone.
        guard !merge, !list.items.isEmpty else { return }
        // The list has to lay out its first row before `scrollTo` can find it.
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !list.items.isEmpty else { return }
        proxy.scrollTo(list.items[0].id, anchor: .top)
    }

    /// Hand double-tap (pinch). Claiming the shortcut replaces the system's
    /// one-screen scroll, which felt too short: this jumps `pinchStep` posts,
    /// about two screens, from the topmost visible post.
    private func pinchButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            scrollFurther(proxy)
        } label: {
            Color.clear
        }
        .buttonStyle(.plain)
        .frame(width: 1, height: 1)
        // Barely-there rather than fully transparent: the system can treat a
        // zero-opacity view as hidden and drop the gesture shortcut.
        .opacity(0.01)
        .accessibilityHidden(true)
        .handGestureShortcut(.primaryAction)
    }

    private func scrollFurther(_ proxy: ScrollViewProxy) {
        guard !list.items.isEmpty else { return }
        let anchor = list.items.firstIndex { visibleIDs.contains($0.id) } ?? 0
        let target = min(anchor + Self.pinchStep, list.items.count - 1)
        guard target > anchor else { return }
        withAnimation(.easeOut(duration: 0.28)) {
            proxy.scrollTo(list.items[target].id, anchor: .top)
        }
        // Near the end now: ask for the next page while the animation runs.
        if target >= list.items.count - 3 {
            list.loadMoreIfNeeded(current: list.items[target])
        }
    }
}

/// Slim status line under the navigation bar. It has a fixed height so showing
/// and hiding it never moves the feed. Three states:
/// - idle: invisible (space reserved),
/// - pulling / turning the crown: a bar that fills towards the refresh,
/// - loading: an indeterminate bar + the current download rate.
struct FeedStatusBar: View {
    let loading: Bool
    var progress: CGFloat = 0

    private var visible: Bool { loading || progress > 0.02 }

    var body: some View {
        HStack(spacing: 6) {
            bar
            captionView
        }
        .frame(height: 14)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: visible)
    }

    /// The rate changes while loading, so poll it only then.
    private var captionView: some View {
        Group {
            if loading {
                TimelineView(.periodic(from: Date(), by: 0.5)) { _ in
                    captionText
                }
            } else {
                captionText
            }
        }
    }

    private var captionText: some View {
        Text(caption)
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 52, alignment: .trailing)
    }

    @ViewBuilder
    private var bar: some View {
        if loading {
            IndeterminateBar()
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(progress >= 1 ? Color.accentColor : Color.secondary)
                        .frame(width: geo.size.width * min(1, max(0, progress)))
                }
            }
            .frame(height: 3)
        }
    }

    private var caption: String {
        guard loading else { return progress >= 1 ? "Release" : "" }
        let rate = TransferMonitor.shared.snapshot().bytesPerSecond
        if rate >= 512 { return TransferMonitor.formatRate(rate) }
        return "Loading"
    }
}

/// A 3 pt capsule with a highlight sliding left ↔ right: the loading look shared
/// with the video downloader.
struct IndeterminateBar: View {
    @State private var right = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: max(10, geo.size.width * 0.32))
                    .offset(x: right ? geo.size.width * 0.68 : 0)
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                right = true
            }
        }
    }
}
