import SwiftUI
import XKit

/// Home timeline: "Following" (latest) / "For You", infinite scroll, pull to refresh,
/// opens instantly from the on-disk cache.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage("homeKind") private var kindRaw = HomeKind.following.rawValue
    @StateObject private var list = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    @State private var configuredFor: String?

    private var kind: HomeKind { HomeKind(rawValue: kindRaw) ?? .following }

    var body: some View {
        List {
            if list.isRefreshing && !list.isEmpty {
                PullToRefreshSpinnerRow()
            }
            kindPicker
            if let e = list.error, list.isEmpty {
                ErrorStateView(error: e) { await list.refresh() }
                    .listRowBackground(Color.clear)
            } else if list.isEmpty && list.isLoading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            ForEach(list.items) { item in
                TimelineItemRows(item: item)
                    .onAppear { list.loadMoreIfNeeded(current: item) }
            }
            if let e = list.error, !list.isEmpty {
                Text(e.localizedDescription).font(.caption2).foregroundStyle(.orange)
                Button("Retry") { list.error = nil; list.loadMore() }
            }
            if !list.isEmpty {
                LoadMoreRow(isLoading: list.isLoading, reachedEnd: list.reachedEnd) { list.loadMore() }
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(kind == .forYou ? "For You" : "Following")
        .pullToRefresh(isRefreshing: list.isRefreshing) { await list.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: Route.settings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .task(id: "\(kindRaw)-\(app.isLoggedIn)") {
            configure()
            await list.loadIfNeeded()
        }
        .onDisappear { list.cancel() }
    }

    private var kindPicker: some View {
        HStack(spacing: 6) {
            ForEach([HomeKind.following, .forYou], id: \.self) { k in
                Button {
                    guard k != kind else { return }
                    kindRaw = k.rawValue
                    Haptics.click()
                } label: {
                    Text(k == .forYou ? "For You" : "Following")
                        .font(.caption.weight(k == kind ? .bold : .regular))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(k == kind ? .accentColor : .gray)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func configure() {
        let key = "\(kind.rawValue)-\(app.isLoggedIn)"
        guard configuredFor != key else { return }
        configuredFor = key
        let client = app.client
        let k = kind
        let cacheName = "home-\(k.rawValue)"
        list.fetch = { cursor in
            let p = try await client.homeTimeline(k, cursor: cursor)
            return (p.items, p.bottomCursor, p.topCursor)
        }
        list.onFirstPage = { items, _ in TimelineDiskCache.save(items, name: cacheName) }
        list.update { $0.removeAll() }
        list.seed(TimelineDiskCache.load(name: cacheName))
    }
}

/// One timeline item: a single post, or a short conversation (thread) shown as consecutive posts.
struct TimelineItemRows: View {
    let item: TimelineItem

    var body: some View {
        switch item {
        case .tweet(let t):
            row(t)
        case .conversation(let ts):
            ForEach(Array(ts.enumerated()), id: \.element.id) { idx, t in
                row(t, threaded: idx < ts.count - 1)
            }
        case .user(let u):
            UserRow(user: u)
        }
    }

    @ViewBuilder
    private func row(_ t: XTweet, threaded: Bool = false) -> some View {
        if t.isTombstone {
            TweetRow(tweet: t, showCounts: false)
        } else {
            NavigationLink(value: Route.post(t)) {
                TweetRow(tweet: t, lineLimit: 12)
                    .overlay(alignment: .bottomLeading) {
                        if threaded {
                            Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 2, height: 8).offset(x: 10, y: 10)
                        }
                    }
            }
        }
    }
}
