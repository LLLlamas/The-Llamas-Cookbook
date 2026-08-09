import SwiftUI

// MARK: - Check-off celebration

// The one-shot animation an item plays as it lands in the cart, driven by
// `GroceryItemRow`'s `celebration` counter. Split out of
// `GroceryListDetailView` — these are self-contained animation primitives
// with no grocery-model dependency.

/// Phases of the check-off stamp: the mark lifts, crashes down slightly
/// below resting size (the "sink"), then springs back to settle. The glow
/// peaks on the lift and dies as the mark comes to rest.
enum CheckStampPhase: CaseIterable {
    case settled, lift, sink

    var scale: CGFloat {
        switch self {
        case .settled: return 1.0
        case .lift: return 1.3
        case .sink: return 0.82
        }
    }

    var glowRadius: CGFloat {
        switch self {
        case .settled: return 0
        case .lift: return 7
        case .sink: return 3
        }
    }

    var glowOpacity: Double {
        switch self {
        case .settled: return 0
        case .lift: return 0.55
        case .sink: return 0.3
        }
    }

    /// The animation used to ENTER this phase — quick lift, sharper drop,
    /// then a bouncy spring back to rest.
    var animation: Animation {
        switch self {
        case .settled: return .spring(duration: 0.32, bounce: 0.45)
        case .lift: return .easeOut(duration: 0.12)
        case .sink: return .easeIn(duration: 0.1)
        }
    }
}

/// One-shot "poof" over the check circle the moment an item lands in the
/// cart: a soft green ring plus a few radial specks that expand and fade.
/// Self-animating on appear — the parent replays it per check-off by
/// re-creating it with `.id(celebration)`.
struct CheckPoof: View {
    @State private var burst = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppColor.success.opacity(burst ? 0 : 0.7), lineWidth: 1.5)
                .frame(width: 23, height: 23)
                .scaleEffect(burst ? 1.9 : 0.5)
            ForEach(0..<6, id: \.self) { i in
                let angle = Double(i) * .pi / 3 - .pi / 2
                Circle()
                    .fill(AppColor.success.opacity(burst ? 0 : 0.85))
                    .frame(width: 3.5, height: 3.5)
                    .scaleEffect(burst ? 0.4 : 1)
                    .offset(
                        x: CGFloat(cos(angle)) * (burst ? 19 : 5),
                        y: CGFloat(sin(angle)) * (burst ? 19 : 5)
                    )
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { burst = true }
        }
    }
}

/// One-shot green highlight band that sweeps the full row, leading edge to
/// trailing, as an item is checked off. Same self-animating/`.id` replay
/// contract as `CheckPoof`. Hit-testing is disabled so the wash never
/// steals a tap from the row's buttons.
struct CheckSweep: View {
    @State private var swept = false

    var body: some View {
        GeometryReader { geo in
            let bandWidth = max(geo.size.width * 0.42, 80)
            LinearGradient(
                colors: [
                    AppColor.success.opacity(0),
                    AppColor.success.opacity(0.2),
                    AppColor.success.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: bandWidth)
            .frame(maxHeight: .infinity)
            .offset(x: swept ? geo.size.width : -bandWidth)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55)) { swept = true }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .allowsHitTesting(false)
    }
}
