import SwiftUI

/// Cold-launch intro: a short, quiet appearance of the bird and the name, like
/// X's splash. Only the first launch of an app process shows it — resuming from
/// the background never does (the flag lives in memory).
enum LaunchIntro {
    private static var hasShown = false
    static var shouldShow: Bool { !hasShown }
    static func markShown() { hasShown = true }
}

struct LaunchIntroView: View {
    @Binding var visible: Bool

    @State private var shown = false

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
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { shown = true }
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                withAnimation(.easeOut(duration: 0.35)) { visible = false }
            }
        }
        .accessibilityLabel("Perch")
    }
}
