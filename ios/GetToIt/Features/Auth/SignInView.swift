import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            FootstepsMark()
                .frame(width: 84, height: 84)
            VStack(spacing: 8) {
                Text("Get To It")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.ink)
                Text("Bring practice to your purpose.")
                    .font(Theme.thoughtFont)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            SignInWithAppleButton(.signIn) { request in
                auth.prepare(request)
            } onCompletion: { result in
                Task { await auth.complete(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if let message = auth.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}

/// The app mark: two footprints stepping upward on the accent tile.
struct FootstepsMark: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .fill(Theme.accent)
                Footprints()
                    .fill(Theme.accentInk)
                    .padding(side * 0.18)
            }
            .frame(width: side, height: side)
        }
    }
}

/// Same drawing as the prototype's `mark` SVG, in a 24×24 space.
struct Footprints: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        for (x, y, angle) in [(8.3, 13.2, -10.0), (15.7, 5.0, 10.0)] {
            var foot = Path()
            foot.move(to: CGPoint(x: 0, y: -3.6))
            foot.addCurve(to: CGPoint(x: 2.5, y: 0.7), control1: CGPoint(x: 2.15, y: -3.6), control2: CGPoint(x: 2.75, y: -1.3))
            foot.addCurve(to: CGPoint(x: 0, y: 3.6), control1: CGPoint(x: 2.3, y: 2.6), control2: CGPoint(x: 1.35, y: 3.6))
            foot.addCurve(to: CGPoint(x: -2.5, y: 0.7), control1: CGPoint(x: -1.35, y: 3.6), control2: CGPoint(x: -2.3, y: 2.6))
            foot.addCurve(to: CGPoint(x: 0, y: -3.6), control1: CGPoint(x: -2.75, y: -1.3), control2: CGPoint(x: -2.15, y: -3.6))
            foot.closeSubpath()
            foot.addEllipse(in: CGRect(x: -1.75, y: 5.8 - 1.95, width: 3.5, height: 3.9))
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: x, y: y)
                .rotated(by: angle * .pi / 180)
                .scaledBy(x: 1.1, y: 1.1)
            path.addPath(foot, transform: transform)
        }
        let offset = CGAffineTransform(translationX: rect.minX + (rect.width - 24 * scale) / 2,
                                       y: rect.minY + (rect.height - 24 * scale) / 2)
        return path.applying(offset)
    }
}
