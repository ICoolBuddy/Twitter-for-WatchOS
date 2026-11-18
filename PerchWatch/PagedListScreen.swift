import SwiftUI
import XKit

/// Loading / failed / empty for a paged list, written once from `PagedList.phase`
/// (five screens used to recombine the list's flags each in their own way, and had
/// drifted). It renders nothing in the content states on purpose: the rows stay a
/// direct child of the screen's `LazyVStack`, so they are still built lazily.
struct PagedListStatus<Item: Identifiable & Hashable>: View {
    @ObservedObject var list: PagedList<Item>
    var emptyText: String
    /// Extra line under the title (the feeds' "pull to refresh" hint).
    var emptyHint: String? = nil
    var loading: Loading = .postSkeletons

    enum Loading { case spinner, postSkeletons }

    var body: some View {
        switch list.phase {
        case .idle, .loading:
            placeholder
        case .failed(let error):
            ErrorStateView(error: error) { await list.refresh() }
                .padding(.vertical, 8)
        case .empty:
            emptyState
        case .content, .paging:
            // Nothing on purpose: a refresh over posts already on screen shows the
            // status pill (`PullToRefresh`), never a placeholder row — a skeleton
            // there read as a blank gap, and reserved layout it could not fill.
            EmptyView()
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch loading {
        case .spinner:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
        case .postSkeletons:
            VStack(spacing: 12) {
                PostSkeleton(mediaHeight: 130)
                PostSkeleton(mediaHeight: 110)
                PostSkeleton(mediaHeight: 150)
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bird").font(.title2).foregroundStyle(.secondary)
            Text(emptyText).font(.system(size: 15, weight: .semibold))
            if let emptyHint {
                Text(emptyHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

extension View {
    /// Infinite scroll: tell the list this row is on screen.
    func paginates<Item: Identifiable & Hashable>(_ list: PagedList<Item>, with item: Item) -> some View {
        onAppear { list.loadMoreIfNeeded(current: item) }
    }

    /// The chrome every list screen shares. `onRefresh == nil` for screens without
    /// pull-to-refresh (search results).
    func pagedListChrome<Item: Identifiable & Hashable>(
        _ list: PagedList<Item>,
        onRefresh: (() async -> Void)? = nil,
        profile: Binding<ProfileTarget?>,
        media: Binding<MediaTarget?>
    ) -> some View {
        self
            .background(Color.black)
            .modifier(OptionalPullToRefresh(isRefreshing: list.isRefreshing, failed: list.error != nil,
                                            action: onRefresh))
            .postPresentation(profile: profile, media: media)
    }
}

private struct OptionalPullToRefresh: ViewModifier {
    var isRefreshing: Bool
    var failed = false
    var action: (() async -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let action {
            content.pullToRefresh(isRefreshing: isRefreshing, failed: failed, action: action)
        } else {
            content
        }
    }
}
