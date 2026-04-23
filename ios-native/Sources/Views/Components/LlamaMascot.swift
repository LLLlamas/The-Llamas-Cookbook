import SwiftUI

/// Stylized llama mascot. Ported from the RN SVG shape-for-shape so the
/// proportions match between apps during the port.
struct LlamaMascot: View {
    var size: CGFloat = 120
    var color: Color = AppColor.accent

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height

            // Ground shadow
            context.fill(
                Path(ellipseIn: CGRect(x: w * 0.267, y: h * 0.617, width: w * 0.467, height: h * 0.3)),
                with: .color(color.opacity(0.15))
            )

            // Body
            context.fill(
                Path(roundedRect: CGRect(x: w * 0.367, y: h * 0.433, width: w * 0.267, height: h * 0.35),
                                 cornerRadius: w * 0.117),
                with: .color(color.opacity(0.9))
            )

            // Neck / head
            context.fill(
                Path(roundedRect: CGRect(x: w * 0.433, y: h * 0.167, width: w * 0.15, height: h * 0.35),
                                 cornerRadius: w * 0.067),
                with: .color(color)
            )

            // Left ear
            var leftEar = Path()
            leftEar.move(to: CGPoint(x: w * 0.4, y: h * 0.217))
            leftEar.addLine(to: CGPoint(x: w * 0.433, y: h * 0.1))
            leftEar.addLine(to: CGPoint(x: w * 0.467, y: h * 0.217))
            leftEar.closeSubpath()
            context.fill(leftEar, with: .color(color))

            // Right ear
            var rightEar = Path()
            rightEar.move(to: CGPoint(x: w * 0.55, y: h * 0.217))
            rightEar.addLine(to: CGPoint(x: w * 0.583, y: h * 0.1))
            rightEar.addLine(to: CGPoint(x: w * 0.617, y: h * 0.217))
            rightEar.closeSubpath()
            context.fill(rightEar, with: .color(color))

            // Eyes
            let eyeRadius = w * 0.018
            context.fill(
                Path(ellipseIn: CGRect(x: w * 0.475 - eyeRadius, y: h * 0.3 - eyeRadius,
                                       width: eyeRadius * 2, height: eyeRadius * 2)),
                with: .color(AppColor.textPrimary)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: w * 0.542 - eyeRadius, y: h * 0.3 - eyeRadius,
                                       width: eyeRadius * 2, height: eyeRadius * 2)),
                with: .color(AppColor.textPrimary)
            )

            // Smile
            var smile = Path()
            smile.move(to: CGPoint(x: w * 0.475, y: h * 0.367))
            smile.addQuadCurve(
                to: CGPoint(x: w * 0.542, y: h * 0.367),
                control: CGPoint(x: w * 0.508, y: h * 0.392)
            )
            context.stroke(
                smile,
                with: .color(AppColor.textPrimary),
                style: StrokeStyle(lineWidth: max(1.5, w * 0.015), lineCap: .round)
            )

            // Legs
            context.fill(
                Path(roundedRect: CGRect(x: w * 0.408, y: h * 0.767, width: w * 0.05, height: h * 0.1),
                                 cornerRadius: 2),
                with: .color(color)
            )
            context.fill(
                Path(roundedRect: CGRect(x: w * 0.542, y: h * 0.767, width: w * 0.05, height: h * 0.1),
                                 cornerRadius: 2),
                with: .color(color)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 32) {
        LlamaMascot(size: 140)
        LlamaMascot(size: 44)
        LlamaMascot(size: 32)
    }
    .padding()
    .background(AppColor.background)
}
