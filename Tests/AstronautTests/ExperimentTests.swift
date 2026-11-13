import XCTest
@testable import Astronaut

/// An experiment is only worth reading if the split behind it is fair and
/// stays put: an install that changes sides between launches is in both
/// groups, and a split that leans one way is a difference nobody tested.
final class ExperimentTests: XCTestCase {
    func testAnInstallKeepsItsVariant() {
        let device = UUID()
        let first = Astronaut.experimentBucket(experiment: "signin_apple", deviceId: device, count: 2)
        for _ in 0..<50 {
            XCTAssertEqual(
                Astronaut.experimentBucket(experiment: "signin_apple", deviceId: device, count: 2),
                first
            )
        }
    }

    /// Pinned to a known answer, so a change to the hash — which would move
    /// every install in every running experiment — fails here first.
    func testTheHashHasNotMoved() {
        let device = UUID(uuidString: "ED0346A2-7C49-43EE-B4FF-ADD21FAA4E4E")!
        XCTAssertEqual(
            Astronaut.experimentBucket(experiment: "signin_apple", deviceId: device, count: 2),
            0
        )
        XCTAssertEqual(
            Astronaut.experimentBucket(experiment: "signin_apple", deviceId: device, count: 3),
            1
        )
    }

    func testTheSplitIsEven() {
        for count in [2, 3, 4] {
            var tally = [Int](repeating: 0, count: count)
            let installs = 20_000
            for _ in 0..<installs {
                tally[Astronaut.experimentBucket(experiment: "paywall_copy", deviceId: UUID(), count: count)] += 1
            }
            let expected = Double(installs) / Double(count)
            for share in tally {
                // Well outside what chance does at this size, well inside
                // what a lopsided hash would.
                XCTAssertEqual(Double(share), expected, accuracy: expected * 0.05)
            }
        }
    }

    /// Two experiments running at once must not put the same people on the
    /// same side of both, or each one's result is partly the other's.
    func testExperimentsSplitIndependently() {
        var both = 0
        let installs = 20_000
        for _ in 0..<installs {
            let device = UUID()
            let a = Astronaut.experimentBucket(experiment: "signin_apple", deviceId: device, count: 2)
            let b = Astronaut.experimentBucket(experiment: "paywall_copy", deviceId: device, count: 2)
            if a == 1 && b == 1 { both += 1 }
        }
        XCTAssertEqual(Double(both), Double(installs) / 4, accuracy: Double(installs) / 4 * 0.08)
    }

    func testOneVariantOrNoneIsNotASplit() {
        XCTAssertEqual(Astronaut.experimentBucket(experiment: "x", deviceId: UUID(), count: 1), 0)
        XCTAssertEqual(Astronaut.shared.variant("x", []), "")
        XCTAssertEqual(Astronaut.shared.variant("x", ["only"]), "only")
    }
}
