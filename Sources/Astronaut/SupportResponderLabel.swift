#if canImport(SwiftUI)
import SwiftUI

/// Who answers, as a compact row: avatar, name, and role beneath it.
///
/// Built to sit in a navigation bar beside the close button, so the identity
/// lines up with the chrome instead of starting a second header below it:
///
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .principal) {
///         SupportResponderLabel(responder: responder, tint: .orange)
///     }
/// }
/// ```
///
/// Use `.principal`. iOS 26 wraps a custom `.topBarLeading` item in a glass
/// capsule sized like a button and drops everything after the first view, so
/// the avatar survives and the name and role disappear without any warning.
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
                    .fill(Color(red: 0.20, green: 0.78, blue: 0.35))
                    // Ringed in the background colour so the dot reads as a
                    // badge on the avatar rather than a blob overlapping it,
                    // and tucked inside the circle rather than hanging off it.
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: size * 0.055))
                    .frame(width: size * 0.26, height: size * 0.26)
                    .offset(x: -size * 0.01, y: -size * 0.01)
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

                // Hair: a disc behind the head, showing as a crown above it.
                Circle()
                    .fill(hair)
                    .frame(width: side * 0.66, height: side * 0.66)
                    .offset(y: -side * 0.10)

                // Head, kept large: at 30pt the face has to survive being
                // three millimetres wide.
                Circle()
                    .fill(Color(red: 0.97, green: 0.81, blue: 0.68))
                    .frame(width: side * 0.60, height: side * 0.60)
                    .offset(y: side * 0.01)

                // Fringe — only the top of the forehead, so it never reaches
                // the eyes and turn them into dark-on-dark.
                Circle()
                    .fill(hair)
                    .frame(width: side * 0.60, height: side * 0.60)
                    .offset(y: -side * 0.28)
                    .mask(
                        Circle()
                            .frame(width: side * 0.60, height: side * 0.60)
                            .offset(y: side * 0.01)
                    )

                // Eyes, low enough to sit on skin.
                HStack(spacing: side * 0.15) {
                    eye(side: side)
                    eye(side: side)
                }
                .offset(y: side * 0.04)

                // Smile: the lower arc of a circle's outline.
                Circle()
                    .trim(from: 0.08, to: 0.42)
                    .stroke(
                        Color(red: 0.42, green: 0.26, blue: 0.20),
                        style: StrokeStyle(lineWidth: side * 0.042, lineCap: .round)
                    )
                    .frame(width: side * 0.24, height: side * 0.24)
                    .offset(y: side * 0.16)

                // Shoulders, so the head is not floating — a sliver at the
                // bottom of the circle, not a slab across the chin.
                Capsule()
                    .fill(tint)
                    .frame(width: side * 0.92, height: side * 0.30)
                    .offset(y: side * 0.54)
            }
            .frame(width: side, height: side)
        }
    }

    private var hair: Color { Color(red: 0.26, green: 0.19, blue: 0.16) }

    private func eye(side: CGFloat) -> some View {
        Circle()
            .fill(Color(red: 0.20, green: 0.16, blue: 0.14))
            .frame(width: side * 0.072, height: side * 0.082)
    }
}
#endif
