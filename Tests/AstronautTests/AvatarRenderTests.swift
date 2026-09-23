import SwiftUI
import XCTest
@testable import Astronaut

/// The avatar is drawn rather than shipped as an image, so the thing that can
/// break it is a drawing change that renders nothing at all — a mask with the
/// wrong offset, a shape sized off a zero. Rendering it and checking that ink
/// actually landed catches that; how friendly the face looks is a judgement
/// only a person can make.
@MainActor
final class AvatarRenderTests: XCTestCase {
    func testCartoonAvatarDrawsSomething() throws {
        let responder = SupportResponder(
            name: "Sahil",
            role: "Founder",
            avatar: .cartoon,
            isOnline: true
        )

        let image = try render(
            SupportAvatarView(responder: responder, tint: .orange, size: 120)
        )

        XCTAssertEqual(image.size.width, 120, accuracy: 1)
        XCTAssertTrue(
            try hasVariedPixels(image),
            "the cartoon avatar rendered as a flat block — nothing was drawn"
        )
    }

    /// Initials must survive the same way, and at navigation-bar size.
    func testInitialsAvatarDrawsSomething() throws {
        let image = try render(
            SupportAvatarView(
                responder: SupportResponder(name: "Sahil"),
                tint: .orange,
                size: 30
            )
        )
        XCTAssertTrue(try hasVariedPixels(image))
    }

    // MARK: - Helpers

    private func render(_ view: some View) throws -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.uiImage)
    }

    /// True when the image contains more than one colour, i.e. something was
    /// drawn on top of the background.
    private func hasVariedPixels(_ image: UIImage) throws -> Bool {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let first = Array(pixels.prefix(4))
        return stride(from: 0, to: pixels.count, by: 4).contains { index in
            Array(pixels[index..<index + 4]) != first
        }
    }
}
