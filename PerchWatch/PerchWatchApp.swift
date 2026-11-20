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
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var presenter = MediaPresenter.shared
    /// The pager's page lives here so the toolbar item can stay the same view across
    /// push/pop (a per-screen leading item is torn down mid-pop, which is what made the
    /// departing screen flash the system back and the icon jump a few points).
    @StateObject private var pager = PagerControl()
    /// The navigation state, owned by the root: a screen is "on top" (and may
    /// own the crown) exactly while it is the last element of this path.
    @StateObject private var nav = Navigator()

    var body: some View {
        ZStack {
            if app.canBrowse {
                NavigationStack(path: $nav.path) {
                    RootPager(rootActive: nav.path.isEmpty, control: pager)
                        .navigationDestination(for: Route.self) { route in
                            RouteView(route: route, pop: { nav.back() })
                                .navigationBarBackButtonHidden(true)
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        TouchDownControl(action: { nav.back() }) {
                                            Image(systemName: "chevron.left")
                                        }
                                        .accessibilityLabel("Back")
                                        .accessibilityIdentifier("chrome.back")
                                        .accessibilityAddTraits(.isButton)
                                    }
                                }
                        }
                }
                .navigationBarBackButtonHidden(true)
            } else {
                NavigationStack { OnboardingView() }
            }
            // Media is an overlay, not a cover: a watchOS cover is always opaque, so
            // the swipe-down could never reveal the feed. The viewer's own background
            // fades from black to clear while it is dragged (and back on release).
            if app.canBrowse, let target = presenter.target,
               presenter.sheetDepth == 0, !target.hasVideo {
                MediaViewer(media: target.media, startIndex: target.startIndex,
                            title: target.title, caption: target.caption,
                            onClose: { presenter.close() }, inCover: true)
                    .zIndex(2)
                    .transition(.opacity)
            }

        }
        // watchOS swallows the first tap while a list is still decelerating, and the
        // system back chevron sits under the scrolling content: a tap there did nothing
        // until the list stopped. This overlay is above the scroll view, so its tap
        // lands immediately (with a short guard against a double pop).
        .overlay(alignment: .topLeading) {
            if app.canBrowse, !nav.path.isEmpty, presenter.target == nil {
                BackCornerTap { nav.back() }
            }
        }
        // A sheet's own onDisappear can be missed; a stale depth kills the viewer.
        .onChange(of: nav.path) { _, path in
            if path.isEmpty { presenter.resetSheetDepth() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, nav.path.isEmpty { presenter.resetSheetDepth() }
        }
        // A video needs a real presentation: dismissing it is what hands the Digital
        // Crown back to the feed (S14 measured dead after an overlay close; S12 passes
        // for photos). Photos and GIFs stay an overlay so the swipe-down can reveal the
        // feed through the viewer's fading background.
        .fullScreenCover(isPresented: videoCoverPresented) {
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
        // A synced account switch must not leave a pushed post/profile from the
        // previous account (its flags and follow state would be the old account's).
        .onChange(of: app.activeAccountId) { _, _ in
            if app.canBrowse { nav.path = [] }
        }
    }
}

/// A toolbar control that acts on touch-DOWN. watchOS spends the first touch of a
/// decelerating scroll stopping it, so a normal Button (which acts on touch-up) is
/// ignored until the screen is static.
struct TouchDownControl<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var last = Date.distantPast

    var body: some View {
        label
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard abs(value.translation.width) < 10,
                              abs(value.translation.height) < 10 else { return }
                        let now = Date()
                        guard now.timeIntervalSince(last) > 0.5 else { return }
                        last = now
                        action()
                    }
            )
    }
}

/// The top-left corner where watchOS draws the back chevron, as a tap target that
/// works while the list below is still moving.
private struct BackCornerTap: View {
    let action: () -> Void
    @State private var last = Date.distantPast

    var body: some View {
        Color.clear
            .frame(width: 56, height: 52)
            .contentShape(Rectangle())
            // Touch-DOWN, not a tap: while a list is decelerating watchOS spends the
            // first touch stopping the scroll, so the tap-up never reaches a control.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard abs(value.translation.width) < 10,
                              abs(value.translation.height) < 10 else { return }
                        let now = Date()
                        guard now.timeIntervalSince(last) > 0.6 else { return }
                        last = now
                        action()
                    }
            )
            .accessibilityHidden(true)
    }
}

extension WatchRootView {
    var videoCoverPresented: Binding<Bool> {
        Binding(
            get: {
                presenter.target?.hasVideo == true && presenter.sheetDepth == 0
            },
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
/// The root pager's page, shared with the stack-level toolbar item.
@MainActor
final class PagerControl: ObservableObject {
    @Published var page = 1
    var lastFeed = 1

    func go(_ target: Int) {
        guard target != page else { return }
        withAnimation(.easeInOut(duration: 0.2)) { page = target }
    }

    func toggle() {
        if page == 0 { go(lastFeed) } else { go(0) }
    }
}

struct RootPager: View {
    /// False while a detail screen is pushed.
    var rootActive = true
    @ObservedObject var control: PagerControl
    @EnvironmentObject private var app: AppModel
    @AppStorage(PerchSettings.homeKind) private var kindRaw = HomeKind.forYou.rawValue
    @AppStorage(PerchSettings.autoRefreshOnOpen) private var autoRefreshOnOpen = true

    /// The two feeds' lists live here (not in the pages) so the edge glow can read
    /// them directly.
    @StateObject private var forYou = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    @StateObject private var following = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    @State private var didStart = false
    /// Each feed's reading place, kept here so it outlives the pages.
    @State private var forYouPlace = FeedPlace()
    @State private var followingPlace = FeedPlace()
    /// Owned here (not by the pages): both feeds are configured at launch, before the
    /// pager has built a page for the off-screen one.
    @State private var forYouVisibility = PageVisibility()
    @State private var followingVisibility = PageVisibility()

    var body: some View {
        TabView(selection: $control.page) {
            MenuView(onPick: { kind in goFeed(kind) })
                .tag(0)
            HomeView(kind: .forYou, isActive: rootActive && control.page == 1,
                     onSelect: { goFeed($0) }, refreshOther: { await following.refreshNewer() },
                     list: forYou, place: forYouPlace, visibility: forYouVisibility)
                .tag(1)
            HomeView(kind: .following, isActive: rootActive && control.page == 2,
                     onSelect: { goFeed($0) }, refreshOther: { await forYou.refreshNewer() },
                     list: following, place: followingPlace, visibility: followingVisibility)
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black)
        // One glow for the whole pager (not per page), so a refresh that is
        // still running stays visible after swiping to the other feed or the menu.
        .overlay { RootGlow(forYou: forYou, following: following) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TouchDownControl(action: { control.toggle() }) {
                    // Both symbols stay laid out: a ternary swapped their different
                    // widths inside the page animation and the item snapped at the end.
                    ZStack {
                        Image(systemName: "line.3.horizontal").opacity(control.page == 0 ? 0 : 1)
                        Image(systemName: "chevron.left").opacity(control.page == 0 ? 1 : 0)
                    }
                }
                .animation(nil, value: control.page)
                .accessibilityLabel(control.page == 0 ? "Back to feed" : "Menu")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("chrome.menuToggle")
            }
        }
        .onAppear {
            // Only once: re-assigning the page every time the root comes back
            // from a pushed screen made the pager flash while it settled.
            guard !didStart else { return }
            didStart = true
            // A cold start always opens For You (the owner's choice), whatever feed
            // was open when the app was last used.
            control.page = 1
            control.lastFeed = 1
            kindRaw = HomeKind.forYou.rawValue
        }
        // The pager builds a page only when it is first selected, so without this the
        // off-screen feed had no real fetch and was only refreshed on arrival. Start
        // both, the one on screen first (the system pager is left untouched).
        .task(id: "\(app.isLoggedIn)-\(app.activeAccountId ?? "none")") {
            guard app.canBrowse else { return }
            let first: HomeKind = kindRaw == HomeKind.following.rawValue ? .following : .forYou
            await startFeed(first)
            await startFeed(first == .forYou ? .following : .forYou)
        }
        // The page is the source of truth for the swipe; the stored kind follows
        // it so the menu checkmark, background refresh and account switch agree.
        .onChange(of: control.page) { _, value in
            guard value != 0 else { return }
            control.lastFeed = value
            let kind = value == 2 ? HomeKind.following : HomeKind.forYou
            if kindRaw != kind.rawValue { kindRaw = kind.rawValue }
        }
        // And a kind change from elsewhere (menu row, account switch) moves the pager.
        .onChange(of: kindRaw) { _, value in
            guard control.page != 0 else { return }
            let target = value == HomeKind.following.rawValue ? 2 : 1
            if control.page != target { control.go(target) }
        }
    }

    /// Configure/seed/start one feed from here (the same steps HomeView's task runs).
    private func startFeed(_ kind: HomeKind) async {
        let list = kind == .forYou ? forYou : following
        let place = kind == .forYou ? forYouPlace : followingPlace
        let visibility = kind == .forYou ? forYouVisibility : followingVisibility
        let key = HomeFeedSetup.key(kind, loggedIn: app.isLoggedIn, accountId: app.activeAccountId)
        let setup = HomeFeedSetup(kind: kind, list: list, place: place,
                                  visibility: visibility, key: key)
        setup.configure(client: app.client, scope: app.homeCacheScope(kind))
        setup.seed(await TimelineDiskCache.loadAsync(app.homeCacheScope(kind)))
        await setup.start(client: app.client, posts: app.posts,
                          autoRefreshOnOpen: autoRefreshOnOpen)
    }

    private func goFeed(_ kind: HomeKind) {
        kindRaw = kind.rawValue
        control.go(kind == .following ? 2 : 1)
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
