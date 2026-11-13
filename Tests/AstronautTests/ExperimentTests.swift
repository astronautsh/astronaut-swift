import XCTest
@testable import Astronaut

/// The app's whole part in an experiment is asking which variant it has, so
/// what matters here is that the answer is exactly what the server dealt:
/// nothing for an install that is not enrolled, the pinned variant for a
/// tester, and nothing again once the experiment is gone.
final class ExperimentTests: XCTestCase {
    private let astronaut = Astronaut.shared
    private var before: [String: String] = [:]

    override func setUp() {
        before = astronaut.heldAssignments
        astronaut.storeAssignments([:])
    }

    override func tearDown() {
        astronaut.setVariantOverride(nil, for: "signin_apple")
        astronaut.storeAssignments(before)
    }

    func testAnInstallThatIsNotEnrolledGetsNothing() {
        XCTAssertNil(astronaut.variant("signin_apple"))
    }

    func testAnEnrolledInstallGetsWhatItWasDealt() {
        astronaut.storeAssignments(["signin_apple": "apple", "paywall_copy": "control"])

        XCTAssertEqual(astronaut.variant("signin_apple"), "apple")
        XCTAssertEqual(astronaut.variant("  signin_apple "), "apple")
        XCTAssertEqual(astronaut.variant("paywall_copy"), "control")
        XCTAssertNil(astronaut.variant("something_else"))
    }

    /// Stopping an experiment drops it from the server's answer, and the
    /// install has to let go with it rather than keep an old variant alive.
    func testAStoppedExperimentLetsGo() {
        astronaut.storeAssignments(["signin_apple": "apple", "paywall_copy": "control"])
        astronaut.storeAssignments(["paywall_copy": "control"])

        XCTAssertNil(astronaut.variant("signin_apple"))
        XCTAssertEqual(astronaut.variant("paywall_copy"), "control")
    }

    func testAPinWinsUntilItIsCleared() {
        astronaut.storeAssignments(["signin_apple": "control"])

        astronaut.setVariantOverride("apple", for: "signin_apple")
        XCTAssertEqual(astronaut.variant("signin_apple"), "apple")

        astronaut.setVariantOverride(nil, for: "signin_apple")
        XCTAssertEqual(astronaut.variant("signin_apple"), "control")
    }

    /// A tester's phone is rarely a new install, so it is usually in nothing.
    /// The pin has to work for it all the same.
    func testAPinWorksForAnInstallThatIsNotEnrolled() {
        astronaut.setVariantOverride("apple", for: "signin_apple")
        XCTAssertEqual(astronaut.variant("signin_apple"), "apple")
    }
}
