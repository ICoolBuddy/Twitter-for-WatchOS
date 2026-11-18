import SwiftUI
import XKit

/// Search posts: the query comes from the system text input (dictation,
/// keyboard, scribble) via `TextFieldLink`; results scroll like a feed.
struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var list = PagedList<TimelineItem>(maxItems: 150, fetch: { _ in ([], nil, nil) })
    @State private var query = ""
    @State private var product: SearchProduct = .top
    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                searchField
                if !query.isEmpty { productPicker }

                if query.isEmpty {
                    Text("Search posts on X.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else {
                    PagedListStatus(list: list, emptyText: "No results.")
                }

                ForEach(list.items) { item in
                    TimelineItemRows(item: item,
                                     onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                                     onMedia: { mediaTarget = $0 })
                        .paginates(list, with: item)
                    PostSeparator()
                }

                PagingFooter(list: list)
            }
            .padding(.horizontal, Metrics.horizontalPadding)
        }
        .pagedListChrome(list, profile: $profileTarget, media: $mediaTarget)
        .navigationTitle("Search")
        // crown-lab measurement hook (DEBUG only): `probe.search`.
        .crownProbe("search")
        .swipeBack()
    }

    private var searchField: some View {
        TextFieldLink(prompt: Text("Search X")) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text(query.isEmpty ? "Search" : query)
                    .lineLimit(1)
                    .foregroundStyle(query.isEmpty ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 15))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        } onSubmit: { text in
            let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return }
            query = q
            run()
        }
        .buttonStyle(.swipeSafe)
        .padding(.bottom, 6)
        .accessibilityLabel(query.isEmpty ? "Search" : "Search: \(query)")
    }

    private var productPicker: some View {
        HStack(spacing: 6) {
            chip(.top, "Top")
            chip(.latest, "Latest")
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    private func chip(_ p: SearchProduct, _ label: String) -> some View {
        Button {
            guard product != p else { return }
            product = p
            run()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(product == p ? Color.black : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(product == p ? Color.white : Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.swipeSafe)
    }

    private func run() {
        list.reset()
        let client = app.client
        let q = query
        let p = product
        list.fetch = { cursor in
            let page = try await client.search(q, product: p, cursor: cursor)
            return (page.items, page.bottomCursor, page.topCursor)
        }
        list.onPage = { items in ImageLoader.shared.prefetchFeed(items.displayTweets) }
        list.skip = { $0.isFiller }
        Task { await list.refresh() }
    }
}
