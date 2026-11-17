import SwiftUI
import XKit

@main
struct PerchWatchApp: App {
    @StateObject private var app = AppModel.shared
    @StateObject private var sync = WatchSync.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(app)
                .environmentObject(app.posts)
                .environmentObject(sync)
                .onAppear { sync.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await app.refreshBadge() }
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
                HomeView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
        } else {
            NavigationStack { OnboardingView() }
        }
    }
}

/// Resolves `Route` values to screens. Screens for later milestones fall back to a placeholder.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .post(let t): PostDetailView(tweet: t)
        case .settings: WatchSettingsView()
        case .debugLog: DebugLogView()
        default: ComingSoonView()
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
                }
                Text(sync.statusText).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Welcome")
    }
}
