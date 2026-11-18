import SwiftUI
import Combine

/// Shimmering placeholder shapes (YouTube-style) shown while content and images
/// are still loading, instead of grey blocks or spinners.
struct Skeleton: View {
    var corner: CGFloat = 6

    @State private var slide: CGFloat = -1
    /// Tracked as state: a `body`-time read of `isLowPowerModeEnabled` would not stop a
    /// shimmer that started before Low Power Mode was turned on.
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// No shimmer when motion is reduced or in Low Power Mode: many of these can
    /// be on screen at once (every image that has not loaded yet).
    private var animated: Bool { !reduceMotion && !lowPower }

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay {
                if animated {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.10), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(40, geo.size.width * 0.45))
                        // The repeat-forever animation covers the offset only
                        // (`animation(_:body:)`); a value-scoped one would also
                        // animate any size change of the row made meanwhile.
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { content in
                            content.offset(x: slide * geo.size.width * 1.6)
                        }
                    }
                    .onAppear { slide = 1.6 }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

/// Whole-post placeholder: avatar, name/handle lines, text lines and media block.
struct PostSkeleton: View {
    var mediaHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Skeleton(corner: 22)
                    .frame(width: Metrics.avatar, height: Metrics.avatar)
                VStack(alignment: .leading, spacing: 5) {
                    Skeleton(corner: 4).frame(width: 118, height: 13)
                    Skeleton(corner: 4).frame(width: 76, height: 11)
                }
            }
            Skeleton(corner: 4).frame(height: 16)
            Skeleton(corner: 4).frame(height: 16).padding(.trailing, 46)
            Skeleton(corner: 12).frame(height: mediaHeight)
        }
        .padding(.vertical, 10)
        .accessibilityHidden(true)
    }
}
