import SwiftUI
import WatchKit
import XKit

@main
struct PerchWatchApp: App {
    @WKApplicationDelegateAdaptor(PerchWatchDelegate.self) private var delegate
    @StateObject private var app = AppModel.shared
    @StateObject private var sync = WatchSync.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PerchSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Screenshot harness (CI): no-op unless launched with -PerchScreen/-PerchFixtures.
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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                BackgroundRefresh.scheduleSoon()
                Task { await app.refreshBadge() }
            case .background: ImageLoader.shared.purge()
            default: break
            }
        }

    }
}

struct WatchRootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if app.canBrowse {
            NavigationStack {
                RootPager()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
        } else {
            NavigationStack { OnboardingView() }
        }
    }
}

/// Two pages: the menu (0) and the feed (1). Swiping right on the feed reveals
/// the menu; the hamburger button animates to it. Both share the root
/// `NavigationStack`, so menu entries push over whichever page is showing.
/// The toolbar lives here so the feed and the menu never both contribute one.
struct RootPager: View {
    @State private var page = 1

    var body: some View {
        TabView(selection: $page) {
            MenuView(onShowFeed: { showFeed() })
                .tag(0)
            HomeView()
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if page == 1 { showMenu() } else { showFeed() }
                } label: {
                    Image(systemName: page == 1 ? "line.3.horizontal" : "chevron.left")
                }
                .accessibilityLabel(page == 1 ? "Menu" : "Back to feed")
            }
        }
    }

    private func showFeed() {
        withAnimation(.easeInOut(duration: 0.2)) { page = 1 }
    }

    private func showMenu() {
        withAnimation(.easeInOut(duration: 0.2)) { page = 0 }
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
