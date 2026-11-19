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
        // Logout clears the cached threads/profiles (they carry the account's like/follow
        // state). Saved posts and the image cache stay: the user decided (2026-11-18)
        // that downloads they made on purpose survive a logout.
        AppModel.shared.onLogout = { OfflineCache.clear() }
        // Cached threads/profiles are per account; a removed account's go with it.
        AppModel.shared.onActiveAccountChange = { OfflineCache.setNamespace($0) }
        AppModel.shared.onAccountRemoved = { OfflineCache.clear(accountId: $0) }
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
    /// The navigation state, owned by the root: a screen is "on top" (and may
    /// own the crown) exactly while it is the last element of this path.
    @StateObject private var nav = Navigator()

    var body: some View {
        ZStack {
            if app.canBrowse {
                NavigationStack(path: $nav.path) {
                    RootPager(rootActive: nav.path.isEmpty)
                        .navigationDestination(for: Route.self) { route in
                            RouteView(route: route, pop: { nav.back() })
                        }
                }
            } else {
                NavigationStack { OnboardingView() }
            }

        }
        // Full-screen media is a real presentation (crown fix, 2026-11-18): when an
        // overlay viewer went away, watchOS did not hand the crown back to the feed;
        // dismissing a presentation is a moment it re-picks the crown's scroll view.
        // The viewer hides the cover's X and clock (`inCover`); it closes by swipe down.
        .fullScreenCover(isPresented: mediaCoverPresented) {
            if let target = presenter.target {
                MediaViewer(media: target.media, startIndex: target.startIndex,
                            title: target.title, caption: target.caption,
                            onClose: { presenter.close() }, inCover: true)
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
        .animation(.easeInOut(duration: 0.2), value: app.sessionExpired)
        // Logout: do not restore the old stack when the next session appears.
        .onChange(of: app.canBrowse) { _, canBrowse in
            if !canBrowse { nav.path = [] }
        }
    }
}

extension WatchRootView {
    /// The root media viewer is presented while there is a target and no sheet is up
    /// (a sheet draws its own `MediaHost`).
    var mediaCoverPresented: Binding<Bool> {
        Binding(
            get: { presenter.target != nil && presenter.sheetDepth == 0 },
            set: { presented in if !presented { presenter.close() } }
        )
    }
}

/// The pushed-screen stack. `back()` is one state mutation, so a pop cannot
/// race the system's own pop (the two used to leave a black frame).
@MainActor
final class Navigator: ObservableObject {
    @Published var path: [Route] = []

    func back() {
        if !path.isEmpty { path.removeLast() }
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
///
/// The pager is the system's `TabView(.page)` (crown fix, 2026-11-18). The hand-rolled
/// offset pager it replaces kept three live scroll views side by side with the
/// off-screen two `.disabled`; watchOS then routed the Digital Crown nowhere every
/// time a feed became the visible list again (page swipe, toolbar button, pop, sheet
/// dismissal) until a finger touched it. Measured in the simulator by
/// `PerchWatchUITests/CrownRoutingTests.swift`; see `docs/crown/PHASE2-REPORT.md`.
/// The system pager hands the crown to the page on screen by itself, so there is no
/// focus code here (explicit focus on a scroll view suppresses that routing).
struct RootPager: View {
    /// False while a detail screen is pushed.
    var rootActive = true
    @AppStorage(PerchSettings.homeKind) private var kindRaw = HomeKind.forYou.rawValue
    @State private var page = 1
    /// The two feeds' lists live here (not in the pages) so the edge glow can read
    /// them directly.
    @StateObject private var forYou = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    @StateObject private var following = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    /// The feed page to return to from the menu (1 = For You, 2 = Following).
    @State private var lastFeed = 1
    @State private var didStart = false
    /// Each feed's reading place, kept here so it outlives the pages.
    @State private var forYouPlace = FeedPlace()
    @State private var followingPlace = FeedPlace()

    var body: some View {
        TabView(selection: $page) {
            MenuView(onPick: { kind in goFeed(kind) })
                .tag(0)
            HomeView(kind: .forYou, isActive: rootActive && page == 1,
                     onSelect: { goFeed($0) }, list: forYou, place: forYouPlace)
                .tag(1)
            HomeView(kind: .following, isActive: rootActive && page == 2,
                     onSelect: { goFeed($0) }, list: following, place: followingPlace)
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
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
                // The crown routing tests press this one.
                .accessibilityIdentifier("chrome.menuToggle")
            }
        }
        .onAppear {
            // Only once: re-assigning the page every time the root comes back
            // from a pushed screen made the pager flash while it settled.
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

    private func go(_ target: Int) {
        guard target != page else { return }
        withAnimation(.easeInOut(duration: 0.2)) { page = target }
    }
}

/// Resolves `Route` values to screens. Screens for later milestones fall back to
/// a placeholder.
struct RouteView: View {
    let route: Route
    /// Pops one screen by state (no `dismiss()` round trip).
    var pop: (() -> Void)? = nil
    @EnvironmentObject private var app: AppModel

    var body: some View {
        screen
            .environment(\.popScreen, pop)
    }

    @ViewBuilder
    private var screen: some View {
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
