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
            // feed/longpost use the real root, which is already on screen: no second
            // app instance on top of it.
            if let screen = PerchDebug.screen, screen != .feed, screen != .longpost {
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
            // Already installed synchronously in PerchWatchApp.init, before AppModel's
            // first reloadState() could run (which then returns early): no re-assert.
            library = FixtureHarness.install(screen: PerchDebug.screen)
        }
    }

    @ViewBuilder
    private func screenView(_ screen: PerchDebugScreen, library: FixtureLibrary) -> some View {
        switch screen {
        case .feed, .longpost:
            // Not drawn here: the real root underneath is the screen.
            EmptyView()
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
                // Same as the root presentation in WatchRootView.
                MediaViewer(media: media, startIndex: 0, showsCloseButton: false)
                    ._statusBarHidden(true)
            }
    }
}
#endif
