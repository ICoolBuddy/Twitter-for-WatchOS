import SwiftUI
import XKit

/// Home timeline, Parrot style: pure black, no platters, big 19 pt text,
/// full-width media, hamburger button top-left. Infinite scroll, pull to refresh,
/// opens instantly from the on-disk cache.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage(PerchSettings.autoRefreshOnOpen) private var autoRefreshOnOpen = true
    @AppStorage(PerchSettings.homeKind) private var kindRaw = HomeKind.following.rawValue

    @StateObject private var list = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    @State private var configuredFor: String?
    @State private var startedFor: String?
    /// The item at the top of the viewport (double-tap likes this one).
    @State private var topID: String?
    @State private var showMenu = false
    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?
    @State private var replyTarget: XTweet?

    private var kind: HomeKind { HomeKind(rawValue: kindRaw) ?? .following }

    private var taskKey: String {
        "\(kindRaw)-\(app.isLoggedIn)-\(app.activeAccountId ?? "none")"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if list.isRefreshing && !list.isEmpty {
                    PullToRefreshSpinnerRow()
                        .padding(.vertical, 6)
                }
                content
            }
            .scrollTargetLayout()
            .padding(.horizontal, Metrics.horizontalPadding)
        }
        .scrollPosition(id: $topID, anchor: .top)
        // Before the first scroll nothing is "at the top"; treat the first post as current
        // so double-tap likes it right away.
        .onChange(of: list.items.first?.id) { _, first in
            if topID == nil { topID = first }
        }
        .background(Color.black)
        .pullToRefresh(isRefreshing: list.isRefreshing) { await list.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showMenu = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .accessibilityLabel("Menu")
            }
        }
        .task(id: taskKey) {
            configure()
            await start()
        }
        .sheet(isPresented: $showMenu) {
            MenuView()
        }
        .postPresentation(profile: $profileTarget, media: $mediaTarget, reply: $replyTarget)
        .onDisappear { list.cancel() }
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
                                     isTop: item.id == topID,
                                     onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                                     onMedia: { mediaTarget = $0 },
                                     onReply: { replyTarget = $0 })
                        .onAppear { list.loadMoreIfNeeded(current: item) }
                    if item.id != list.items.last?.id { PostSeparator() }
                }
                .id(item.id)
            }
            if list.isLoading && !list.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
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
        topID = nil

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
        list.seed(TimelineDiskCache.load(name: cacheName))
    }

    /// Show the cached feed immediately; only go to the network when
    /// "Refresh when opening the app" is on, or when there is no cache at all.
    /// Runs once per account/kind so closing a sheet does not re-fetch.
    private func start() async {
        guard startedFor != taskKey else { return }
        startedFor = taskKey
        if list.isEmpty {
            await list.refresh()
        } else if autoRefreshOnOpen {
            await list.refresh()
        }
    }
}
