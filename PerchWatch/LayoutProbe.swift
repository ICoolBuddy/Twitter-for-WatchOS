import SwiftUI

/// DEBUG-only layout probe for the CI screenshots: outlines a view's frame and
/// prints its size and safe-area insets, so layout problems are measured, not
/// guessed. Inert in Release and outside the fixture harness.
struct LayoutProbe: ViewModifier {
    let name: String
    let color: Color

    func body(content: Content) -> some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PerchFixtures") || UserDefaults.standard.string(forKey: "PerchScreen") != nil {
            content.overlay {
                GeometryReader { geo in
                    let f = geo.frame(in: .global)
                    let i = geo.safeAreaInsets
                    Rectangle()
                        .strokeBorder(color, lineWidth: 2)
                        .overlay(alignment: .center) {
                            Text("\(name) y\(Int(f.minY)) h\(Int(f.height)) safe t\(Int(i.top)) b\(Int(i.bottom))")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(color)
                                .background(Color.black.opacity(0.7))
                        }
                }
                .allowsHitTesting(false)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func layoutProbe(_ name: String, _ color: Color) -> some View {
        modifier(LayoutProbe(name: name, color: color))
    }
}

/// DEBUG-only Digital Crown probe (the modifier itself lives in `Debug/CrownProbe.swift`,
/// which Release does not compile): reports a scroll view's offset as the
/// `accessibilityValue` of `probe.<name>` for the crown routing UI tests. Same shape
/// as `layoutProbe`, so app files can call it without an `#if DEBUG` of their own.
/// In Release this is a no-op.
extension View {
    @ViewBuilder
    func crownProbe(_ name: String) -> some View {
        #if DEBUG
        modifier(CrownProbe(name: name))
        #else
        self
        #endif
    }
}
