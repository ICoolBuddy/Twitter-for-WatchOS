import SwiftUI

/// Pull-to-refresh for watchOS scroll views. watchOS accepts `.refreshable` but
/// draws no control for it, so this tracks the scroll view's overscroll at the
/// top: an arrow fades in and turns as you pull, and crossing the threshold
/// starts the refresh. No haptics (refreshing must be silent).
/// While it runs, put `PullToRefreshSpinnerRow` at the top of the content.
struct PullToRefresh: ViewModifier {
    let isRefreshing: Bool
    let action: () async -> Void

    static let threshold: CGFloat = 48

    @State private var pull: CGFloat = 0
    /// Re-armed once the content has settled back near the top, so one pull = one refresh.
    @State private var armed = true

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                // Positive while the content is dragged down past its top edge.
                -(geo.contentOffset.y + geo.contentInsets.top)
            } action: { _, overscroll in
                pull = max(0, overscroll)
                if overscroll < 6 { armed = true }
                if armed, !isRefreshing, overscroll >= Self.threshold {
                    armed = false
                    Task { await action() }
                }
            }
            .overlay(alignment: .top) {
                if pull > 4 && !isRefreshing {
                    let progress = min(1, pull / Self.threshold)
                    Image(systemName: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(progress >= 1 ? Color.accentColor : Color.secondary)
                        .rotationEffect(.degrees(progress >= 1 ? 180 : 0))
                        .opacity(progress)
                        .offset(y: min(pull, Self.threshold) / 2 - 8)
                        .animation(.easeOut(duration: 0.15), value: progress >= 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// Spinner shown while a pull-triggered refresh runs.
struct PullToRefreshSpinnerRow: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Refreshing")
    }
}

extension View {
    func pullToRefresh(isRefreshing: Bool, action: @escaping () async -> Void) -> some View {
        modifier(PullToRefresh(isRefreshing: isRefreshing, action: action))
    }
}
