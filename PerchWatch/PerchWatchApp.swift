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
        AppModel.shared.onLogout = { OfflineCache.clear() }
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
                            onClose: { presenter.close() })
                    .transition(.opacity)
                    .zIndex(1)
                    .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.18), value: presenter.target?.id)
        ._statusBarHidden(presenter.target != nil)
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
    /// The feed page to return to from the menu (1 = For You, 2 = Following).
    @State private var lastFeed = 1
    @State private var didStart = false

    var body: some View {
        TabView(selection: $page) {
            MenuView(isActive: page == 0, onPick: { kind in
                goFeed(kind)
            })
            .tag(0)
            HomeView(kind: .forYou, isActive: page == 1)
                .tag(1)
            HomeView(kind: .following, isActive: page == 2)
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black)
        // One glow for the whole pager (not per page), so a refresh that is
        // still running stays visible after swiping to the other feed or the menu.
        .overlay { RootGlow(page: page) }
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
        case .post(let t):
            PostDetailView(tweet: t)
        case .user(let screenName):
            ProfileScreen(target: ProfileTarget(screenName: screenName))
        case .userId(let id):
            ProfileScreen(target: ProfileTarget(userId: id))
        case .userFeed(let user):
            UserFeedView(user: user)
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
