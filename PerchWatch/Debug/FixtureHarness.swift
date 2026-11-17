#if DEBUG
import SwiftUI
import XKit

/// Installs the fixture session (`-PerchFixtures YES`) and keeps the parsed
/// fixture library around so the requested screen can read media/users from it.
@MainActor
enum FixtureHarness {
    private(set) static var library: FixtureLibrary?

    /// Loads the fixtures once and installs them into `AppModel`. Safe to call
    /// repeatedly: the parsed library is reused.
    @discardableResult
    static func install(screen: PerchDebugScreen?) -> FixtureLibrary? {
        guard let library = self.library ?? FixtureLibrary.load() else {
            print("[perch-debug] fixture JSON not found in the app bundle")
            return nil
        }
        self.library = library
        apply(library, screen: screen)
        if let screen {
            print("[perch-debug] fixtures installed, opening screen: \(screen.rawValue)")
        } else {
            print("[perch-debug] fixtures installed")
        }
        return library
    }

    /// `AppModel.init` starts `reloadState()` in a Task of its own. If that lands
    /// after `install()`, it restores the real (logged out) state and the fixture
    /// client would be replaced. Re-assert once, a second after launch; harmless
    /// when the install already survived.
    static func installAndReassert(screen: PerchDebugScreen?) async -> FixtureLibrary? {
        guard PerchDebug.fixturesEnabled else { return nil }
        guard let library = install(screen: screen) else { return nil }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        apply(library, screen: screen)
        return library
    }

    private static func apply(_ library: FixtureLibrary, screen: PerchDebugScreen?) {
        let client = FixtureXClient(library: library, longPostFirst: screen == .longpost)
        AppModel.shared.installDebugSession(client: client, viewer: library.viewer)
    }
}

/// Renders the screen named by `-PerchScreen` over the normal app. Nothing is
/// shown when the launch argument is absent.
struct PerchDebugOverlay: View {
    @State private var library: FixtureLibrary?

    var body: some View {
        Group {
            if let screen = PerchDebug.screen {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let library {
                        screenView(screen, library: library)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
            }
        }
        .task {
            guard PerchDebug.fixturesEnabled else { return }
            library = await FixtureHarness.installAndReassert(screen: PerchDebug.screen)
        }
    }

    @ViewBuilder
    private func screenView(_ screen: PerchDebugScreen, library: FixtureLibrary) -> some View {
        switch screen {
        case .feed, .longpost:
            // The real root: keeps the screenshot identical to the shipped UI
            // (including the hamburger and the menu/feed pages added in R10).
            WatchRootView()
        case .menu:
            MenuView()
        case .post:
            if let tweet = library.postTweet {
                NavigationStack {
                    PostDetailView(tweet: tweet)
                        .navigationDestination(for: Route.self) { RouteView(route: $0) }
                }
            } else {
                missing("post")
            }
        case .profile:
            ProfileSheet(target: ProfileTarget(user: library.profileUser))
        case .media:
            if library.mediaItems.isEmpty {
                missing("media")
            } else {
                MediaDebugScreen(media: library.mediaItems)
            }
        case .notifications:
            NavigationStack {
                NotificationsView()
            }
        }
    }

    private func missing(_ screen: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text("No fixture for \(screen)").font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Presents the media viewer the way the app does (`fullScreenCover`), so the
/// screenshot includes the system close button instead of the one R6 removed.
private struct MediaDebugScreen: View {
    let media: [XMedia]
    @State private var show = false

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .onAppear { show = true }
            .fullScreenCover(isPresented: $show) {
                MediaViewer(media: media, startIndex: 0)
            }
    }
}
#endif
