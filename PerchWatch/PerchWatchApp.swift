import SwiftUI
import WatchKit
import XKit

@main
struct PerchWatchApp: App {
    @WKApplicationDelegateAdaptor(PerchWatchDelegate.self) private var delegate
    @StateObject private var app = AppModel.shared
    @StateObject private var sync = WatchSync.shared
    @State private var showIntro = LaunchIntro.shouldShow
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PerchSettings.registerDefaults()
        OfflineCache.removeLegacyFiles()
        // Cached threads/profiles belong to the session that fetched them.
        // Cached threads/profiles belong to the session that fetched them. (The
        // complication follows the login state by itself: ComplicationPublisher.)
        // Read the saved index now, not on the first feed row that asks for a local photo
        // (a file read + JSON decode in the middle of a frame).
        _ = SavedStore.shared
        // Logout signs out both devices: cached threads/profiles, saved posts and the
        // image cache belonged to that account. (Switching accounts keeps them.)
        AppModel.shared.onLogout = {
            OfflineCache.clear()
            SavedStore.shared.purge()
            ImageLoader.shared.purgeAll()
        }
        ComplicationPublisher.start()
        #if DEBUG
        // Screenshot harness: install the fixture session in the same main-actor turn
        // that created AppModel, so its first reloadState() (a queued Task) sees it.
        PerchDebug.install()
        #endif
    }

    /// The app's root view. The screenshot harness hook lives in
    /// `PerchWatch/Debug`, which Release builds do not compile, so it must stay
    /// behind `#if DEBUG` here.
    @ViewBuilder
    private var root: some View {
        #if DEBUG
        WatchRootView()
            .perchDebugScreens()
            .environmentObject(app)
            .environmentObject(app.posts)
            .environmentObject(sync)
            .onAppear { sync.start() }
        #else
        WatchRootView()
            .environmentObject(app)
            .environmentObject(app.posts)
            .environmentObject(sync)
            .onAppear { sync.start() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                root

                if showIntro {
                    LaunchIntroView(visible: $showIntro)
                        .zIndex(2)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                BackgroundRefresh.scheduleSoon()
                Task { await app.refreshBadge() }
                Task { await app.posts.flush(client: app.client) }
            case .background: ImageLoader.shared.purge()
            default: break
            }
        }

    }
}

struct WatchRootView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var presenter = MediaPresenter.shared

    var body: some View {
        ZStack {
            if app.canBrowse {
                NavigationStack {
                    RootPager()
                        .navigationDestination(for: Route.self) { RouteView(route: $0) }
                }
            } else {
                NavigationStack { OnboardingView() }
            }

            // Full-screen media lives above the whole app: no system close
            // button, and the clock can be hidden while it is open.
            if let target = presenter.target {
                MediaViewer(media: target.media, startIndex: target.startIndex,
                            title: target.title, caption: target.caption,
                            onClose: { presenter.close() })
                    .transition(.opacity)
                    .zIndex(1)
                    .ignoresSafeArea()
            }
        }
        // One app-wide notice for a dead session (X answered 401) instead of an error
        // on every screen; it goes away by itself when the iPhone sends new cookies.
        .overlay(alignment: .bottom) {
            if app.canBrowse, app.sessionExpired, presenter.target == nil {
                SessionExpiredBanner()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: presenter.target?.id)
        .animation(.easeInOut(duration: 0.2), value: app.sessionExpired)
        ._statusBarHidden(presenter.target != nil)
    }
}

/// "Your X session expired": asks the iPhone for fresh cookies (it already did once
/// automatically when the 401 arrived). The Watch never deletes the session itself.
struct SessionExpiredBanner: View {
    @EnvironmentObject private var app: AppModel
    @State private var requested = false

    var body: some View {
        Button {
            app.sync?.syncNow()
            requested = true
        } label: {
            VStack(spacing: 1) {
                Label("Session expired", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                Text(requested ? "Asked your iPhone…" : "Open Perch on your iPhone")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        .accessibilityHint("Asks your iPhone to send your X session again")
    }
}

/// Three pages: Menu (0) · For You (1) · Following (2), starting on For You.
/// Swiping right on For You reveals the menu, swiping left reveals Following;
/// the hamburger button animates to the menu. Every page shares the root
/// `NavigationStack`, so menu entries push over whichever page is showing.
/// The toolbar lives here so the pages never contribute one themselves.
struct RootPager: View {
    @AppStorage(PerchSettings.homeKind) private var kindRaw = HomeKind.forYou.rawValue
    @State private var page = 1
    /// The two feeds' lists live here (not in the pages) so the edge glow can read
    /// them directly.
    @StateObject private var forYou = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    @StateObject private var following = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    /// The feed page to return to from the menu (1 = For You, 2 = Following).
    @State private var lastFeed = 1
    @State private var didStart = false
    /// Live horizontal finger offset while swiping between pages.
    @State private var dragX: CGFloat = 0
    /// The axis this drag was decided as (see `PagerSwipe`); nil before it is known.
    @State private var dragAxis: PagerSwipe.Axis?
    /// True while the drag gesture is live; SwiftUI resets it when the gesture ends
    /// *or is cancelled*, which is how a lost `onEnded` is noticed.
    @GestureState private var dragLive = false

    // A hand-rolled pager instead of `TabView(.page)`: a page-style TabView
    // inside the root NavigationStack rendered a black screen after a pushed
    // screen (Bookmarks, Notifications…) was popped with a swipe. Three pages
    // side by side, moved by offset; vertical scrolling inside them is left
    // alone (only clearly horizontal drags page).
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                // Off-screen pages are disabled: a disabled view cannot take
                // focus, so the Digital Crown can only ever land on the page
                // that is on screen. (All three pages stay alive; an enabled
                // off-screen list was taking the crown on launch and after the
                // media viewer closed, which is why it needed a touch first.)
                MenuView(isActive: page == 0, onPick: { kind in
                    goFeed(kind)
                })
                .frame(width: w)
                .disabled(page != 0)
                HomeView(kind: .forYou, isActive: page == 1, list: forYou)
                    .frame(width: w)
                    .disabled(page != 1)
                HomeView(kind: .following, isActive: page == 2, list: following)
                    .frame(width: w)
                    .disabled(page != 2)
            }
            .frame(width: w, alignment: .leading)
            .offset(x: -CGFloat(page) * w + dragX)
            .simultaneousGesture(pagerDrag(width: w))
            .onChange(of: dragLive) { _, live in
                guard !live else { return }
                // `onEnded` and this reset arrive at the same lift in either order; after
                // one runloop hop a still-set axis means the gesture was cancelled (wrist
                // down, a sheet appeared) without `onEnded`: settle back, release taps.
                DispatchQueue.main.async {
                    guard dragAxis != nil else { return }
                    dragAxis = nil
                    SwipeGuard.end()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { dragX = 0 }
                }
            }
        }
        // No `.clipped()` and no `.ignoresSafeArea()` here (measured with the
        // layout probe in the CI screenshots): the pager's frame is the safe
        // area (y62 h150 on a 46 mm watch) while each page's scroll view extends
        // to the full 248 pt screen, so clipping cut the feed into black bars
        // at the top and bottom, and ignoring the safe area removed the
        // scroll view's insets (first post under the clock). The neighbouring
        // pages sit outside the display anyway, so nothing needs clipping.
        .background(Color.black)
        // One glow for the whole pager (not per page), so a refresh that is
        // still running stays visible after swiping to the other feed or the menu.
        .overlay { RootGlow(forYou: forYou, following: following) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if page == 0 { go(lastFeed) } else { go(0) }
                } label: {
                    Image(systemName: page == 0 ? "chevron.left" : "line.3.horizontal")
                }
                .accessibilityLabel(page == 0 ? "Back to feed" : "Menu")
            }
        }
        .onAppear {
            // Only once: re-assigning the page every time the root comes back
            // from a pushed screen made the pager flash black while it settled.
            guard !didStart else { return }
            didStart = true
            page = kindRaw == HomeKind.following.rawValue ? 2 : 1
            lastFeed = page
        }
        // The page is the source of truth for the swipe; the stored kind follows
        // it so the menu checkmark, background refresh and account switch agree.
        .onChange(of: page) { _, value in
            guard value != 0 else { return }
            lastFeed = value
            let kind = value == 2 ? HomeKind.following : HomeKind.forYou
            if kindRaw != kind.rawValue { kindRaw = kind.rawValue }
        }
        // And a kind change from elsewhere (menu row, account switch) moves the pager.
        .onChange(of: kindRaw) { _, value in
            guard page != 0 else { return }
            let target = value == HomeKind.following.rawValue ? 2 : 1
            if page != target { go(target) }
        }
    }

    private func goFeed(_ kind: HomeKind) {
        kindRaw = kind.rawValue
        go(kind == .following ? 2 : 1)
    }

    /// Pages only for a deliberate sideways swipe (`PagerSwipe` has the rule and its
    /// numbers): the axis is decided early and revoked if the drag turns out vertical,
    /// and the commit needs real horizontal travel, so a vertical scroll with a thumb arc
    /// no longer opens the menu.
    private func pagerDrag(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 15)
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let axis = PagerSwipe.axis(decided: dragAxis, dx: Double(dx), dy: Double(dy))
                if axis != dragAxis { dragAxis = axis }
                guard axis == .horizontal else {
                    // A scroll (or a revoked arc) never offsets the page or blocks taps.
                    SwipeGuard.end()
                    if dragX != 0 { withAnimation(.easeOut(duration: 0.15)) { dragX = 0 } }
                    return
                }
                SwipeGuard.begin()
                // Rubber band past the first and last page.
                let atEdge = (page == 0 && dx > 0) || (page == 2 && dx < 0)
                dragX = atEdge ? dx * 0.25 : dx
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                SwipeGuard.end()
                guard axis == .horizontal else { return }
                let target = PagerSwipe.target(page: page, width: Double(w),
                                               dx: Double(value.translation.width),
                                               dy: Double(value.translation.height),
                                               predicted: Double(value.predictedEndTranslation.width))
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    page = target
                    dragX = 0
                }
            }
    }

    private func go(_ target: Int) {
        withAnimation(.easeInOut(duration: 0.2)) { page = target }
    }
}

/// Resolves `Route` values to screens. Screens for later milestones fall back to
/// a placeholder.
struct RouteView: View {
    let route: Route
    @EnvironmentObject private var app: AppModel

    var body: some View {
        switch route {
        case .post(let route):
            PostDetailView(tweet: route.value)
        case .user(let screenName):
            ProfileScreen(target: ProfileTarget(screenName: screenName))
        case .userId(let id):
            ProfileScreen(target: ProfileTarget(userId: id))
        case .userFeed(let route):
            UserFeedView(user: route.value)
        case .profileMe:
            if let id = app.activeAccount?.user?.id ?? app.viewer?.id {
                ProfileScreen(target: ProfileTarget(userId: id))
            } else {
                ComingSoonView()
            }
        case .notifications:
            NotificationsView()
        case .likes:
            TimelineListView(kind: .likes, title: "Likes")
        case .bookmarks:
            TimelineListView(kind: .bookmarks, title: "Bookmarks")
        case .saved:
            SavedView()
        case .search:
            SearchView()
        case .settings:
            WatchSettingsView()
        case .debugLog:
            DebugLogView()
        default:
            ComingSoonView()
        }
    }
}

struct ComingSoonView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "hammer").font(.title2)
            Text("Coming in the next milestone.").font(.footnote).multilineTextAlignment(.center)
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var sync: WatchSync

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "bird.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                Text("Perch").font(.title3.bold())
                Text("Open Perch on your iPhone and log in. Your session is sent to the Watch automatically.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button {
                    sync.syncNow()
                } label: {
                    Label("Sync from iPhone", systemImage: "iphone.and.arrow.forward")
                        .frame(maxWidth: .infinity)
                }
                Text(sync.statusText).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Welcome")
    }
}

/// Background app refresh (~every 30 min, watchOS decides): feed cache, badge and
/// complication. See BackgroundRefresh.swift.
final class PerchWatchDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                Task { @MainActor in
                    await BackgroundRefresh.handle()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
