import SwiftUI

/// Cold-launch intro: a short, quiet appearance of the bird and the name, like
/// X's splash. Only the first launch of an app process shows it — resuming from
/// the background never does (the flag lives in memory).
enum LaunchIntro {
    private static var hasShown = false
    static var shouldShow: Bool { !hasShown }
    static func markShown() { hasShown = true }
}

/// The intro covers the launch only while there is nothing to show: it ends as
/// soon as the feed has posts (cached ones count, so usually almost at once),
/// the user turns out to be logged out, or after 3 s at the most (the feed's
/// skeletons take over then). It never adds a fixed delay to startup.
struct LaunchIntroView: View {
    @Binding var visible: Bool

    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var activity = FeedActivity.shared
    @State private var shown = false

    private static let maximum: UInt64 = 3_000_000_000

    private var ready: Bool {
        app.stateLoaded && (!app.canBrowse || activity.firstContentReady)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "bird.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.white)
                    .scaleEffect(shown ? 1 : 0.55)
                    .opacity(shown ? 1 : 0)
                Text("Perch")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 8)
            }
        }
        .transition(.opacity)
        .onAppear {
            LaunchIntro.markShown()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { shown = true }
            if ready { finish() }
        }
        .onChange(of: ready) { _, isReady in
            if isReady { finish() }
        }
        .task {
            try? await Task.sleep(nanoseconds: Self.maximum)
            finish()
        }
        .accessibilityLabel("Perch")
    }

    private func finish() {
        guard visible else { return }
        withAnimation(.easeOut(duration: 0.25)) { visible = false }
        // Every crown request made while this covered the app went nowhere: hand
        // the crown back to the screen that is now on display.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            CrownFocusMark.shared.mark()
        }
    }
}
