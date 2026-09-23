#if canImport(SwiftUI)
import SwiftUI

/// Who answers, as a compact row: avatar, name, and role beneath it.
///
/// Built to sit in a navigation bar beside the close button, so the identity
/// lines up with the chrome instead of starting a second header below it:
///
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .topBarLeading) {
///         SupportResponderLabel(responder: responder, tint: .orange)
///     }
/// }
/// ```
@available(iOS 16.0, *)
public struct SupportResponderLabel: View {
    private let responder: SupportResponder
    private let tint: Color
    private let size: CGFloat

    public init(
        responder: SupportResponder,
        tint: Color = .accentColor,
        size: CGFloat = 30
    ) {
        self.responder = responder
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 8) {
            SupportAvatarView(responder: responder, tint: tint, size: size)

            VStack(alignment: .leading, spacing: 0) {
                Text(responder.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                if let role = responder.role {
                    Text(role)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The avatar on its own: initials or a drawn face, with the online dot.
@available(iOS 16.0, *)
public struct SupportAvatarView: View {
    private let responder: SupportResponder
    private let tint: Color
    private let size: CGFloat

    public init(responder: SupportResponder, tint: Color, size: CGFloat = 30) {
        self.responder = responder
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            face
                .frame(width: size, height: size)
                .clipShape(Circle())

            if responder.isOnline {
                Circle()
                    .fill(Color.green)
                    // Ringed in the background colour so the dot reads as a
                    // badge on the avatar rather than a blob overlapping it.
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: size * 0.07))
                    .frame(width: size * 0.3, height: size * 0.3)
                    .accessibilityLabel("Online")
            }
        }
        .accessibilityLabel(responder.name)
    }

    @ViewBuilder
    private var face: some View {
        switch responder.avatar {
        case .initials:
            ZStack {
                Circle().fill(tint)
                Text(responder.initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        case .cartoon:
            CartoonFace(tint: tint)
        }
    }
}

/// A face drawn from circles and an arc.
///
/// Vector rather than an image so it stays sharp at any size, ships no asset
/// with the SDK, and takes the host app's tint — the point is a friendlier
/// "someone is here" than two initials, not a portrait.
@available(iOS 16.0, *)
private struct CartoonFace: View {
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                Circle().fill(tint.opacity(0.22))

                // Hair: a disc behind the head, trimmed by the head itself.
                Circle()
                    .fill(Color(red: 0.24, green: 0.18, blue: 0.15))
                    .frame(width: side * 0.66, height: side * 0.66)
                    .offset(y: -side * 0.16)

                // Head.
                Circle()
                    .fill(Color(red: 0.97, green: 0.80, blue: 0.66))
                    .frame(width: side * 0.58, height: side * 0.58)
                    .offset(y: side * 0.02)

                // Fringe, sitting on the forehead.
                Circle()
                    .fill(Color(red: 0.24, green: 0.18, blue: 0.15))
                    .frame(width: side * 0.58, height: side * 0.58)
                    .offset(y: -side * 0.20)
                    .mask(
                        Circle()
                            .frame(width: side * 0.58, height: side * 0.58)
                            .offset(y: side * 0.02)
                    )

                // Eyes.
                HStack(spacing: side * 0.14) {
                    eye(side: side)
                    eye(side: side)
                }
                .offset(y: side * 0.02)

                // Smile: the lower quarter of a circle's outline.
                Circle()
                    .trim(from: 0.08, to: 0.42)
                    .stroke(
                        Color(red: 0.42, green: 0.26, blue: 0.20),
                        style: StrokeStyle(lineWidth: side * 0.045, lineCap: .round)
                    )
                    .frame(width: side * 0.26, height: side * 0.26)
                    .offset(y: side * 0.13)

                // Shoulders, so the head is not floating.
                Capsule()
                    .fill(tint)
                    .frame(width: side * 0.78, height: side * 0.34)
                    .offset(y: side * 0.46)
            }
            .frame(width: side, height: side)
        }
    }

    private func eye(side: CGFloat) -> some View {
        Circle()
            .fill(Color(red: 0.20, green: 0.16, blue: 0.14))
            .frame(width: side * 0.075, height: side * 0.085)
    }
}
#endif
