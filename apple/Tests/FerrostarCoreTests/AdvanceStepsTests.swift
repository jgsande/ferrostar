import Combine
import CoreLocation
import FerrostarCoreFFI
import XCTest
@testable import FerrostarCore

// FORK ADDITION: the test of `FerrostarCore.advanceSteps(_:announce:)` and `hasPendingUpdate`.
// No Ferrostar code builds for macOS, so this test runs on an iOS device only.

/// Records every widget update.
/// The core calls it once in each state update block that carries a visual instruction,
/// with the spoken instruction that block queued, if any.
private final class RecordingWidgetProvider: WidgetProviding {
    struct Update: Equatable {
        let visualText: String
        let spokenText: String?
    }

    private(set) var updates: [Update] = []

    func update(
        visualInstruction: VisualInstruction,
        spokenInstruction: SpokenInstruction?,
        tripProgress _: TripProgress
    ) {
        updates.append(Update(
            visualText: visualInstruction.primaryContent.text,
            spokenText: spokenInstruction?.text
        ))
    }

    func terminate() {}
}

final class AdvanceStepsTests: XCTestCase {
    private static let stepCount = 6
    private static let stepLengthDegrees = 0.001

    /// Six straight steps of about 111 m along the equator.
    /// Each step has one visual and one spoken instruction,
    /// and their trigger distance covers the whole step,
    /// so the current step's instructions are always the active ones.
    private static func sixStepRoute() -> Route {
        let points = (0 ... stepCount).map {
            GeographicCoordinate(lat: 0, lng: Double($0) * stepLengthDegrees)
        }
        let steps = (0 ..< stepCount).map { index in
            RouteStep(
                geometry: [points[index], points[index + 1]],
                distance: 111,
                duration: 10,
                roadName: "Road \(index)",
                exits: [],
                instruction: "Step \(index)",
                visualInstructions: [VisualInstruction(
                    primaryContent: VisualInstructionContent(
                        text: "Step \(index)",
                        maneuverType: .newName,
                        maneuverModifier: .straight,
                        roundaboutExitDegrees: nil,
                        laneInfo: nil,
                        exitNumbers: []
                    ),
                    secondaryContent: nil,
                    subContent: nil,
                    triggerDistanceBeforeManeuver: 100_000
                )],
                spokenInstructions: [SpokenInstruction(
                    text: "Say \(index)",
                    ssml: nil,
                    triggerDistanceBeforeManeuver: 100_000,
                    utteranceId: UUID()
                )],
                annotations: nil,
                incidents: [],
                drivingSide: .right,
                roundaboutExitNumber: nil
            )
        }
        return Route(
            geometry: points,
            bbox: BoundingBox(sw: points[0], ne: points[stepCount]),
            distance: 111 * Double(stepCount),
            waypoints: [
                Waypoint(coordinate: points[0], kind: .break),
                Waypoint(coordinate: points[stepCount], kind: .break),
            ],
            steps: steps
        )
    }

    /// A fix on the first step, `second` seconds into the drive.
    ///
    /// Its time has sub-microsecond digits, as a CoreLocation time does.
    /// The FFI timestamp conversion truncates them,
    /// so the fix that comes back inside a trip state is a fraction of a microsecond EARLIER
    /// than the fix that went in.
    /// `nextDown` picks a time that is certain to lose its last bits that way.
    private static func fix(second: Int) -> UserLocation {
        UserLocation(
            coordinates: GeographicCoordinate(lat: 0, lng: 0.0002),
            horizontalAccuracy: 5,
            courseOverGround: nil,
            timestamp: Date(timeIntervalSinceReferenceDate: (811_692_800.123_456_7 + Double(second)).nextDown),
            speed: nil
        )
    }

    /// Runs every block on the main queue, and the blocks they enqueue, up to `rounds` deep.
    /// `startNavigation` is two deep; a location update and an advance are one deep.
    private func drainMainQueue(rounds: Int = 3) {
        for _ in 0 ..< rounds {
            let drained = expectation(description: "the main queue ran up to this block")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
        }
    }

    /// `advanceSteps(n, announce:)` moves `n` steps in ONE state update,
    /// announces at most the target step's instruction,
    /// and writes the core's state at once, so a fix handled before the update block keeps the advance.
    /// `hasPendingUpdate` is true exactly while a location update's block waits on the main queue.
    /// RED against the stubs, which advance nothing and never report a pending update.
    func testAdvanceStepsPublishesOneStateAndSpeaksOnlyTheTargetStep() throws {
        let locationProvider = SimulatedLocationProvider()
        locationProvider.lastLocation = Self.fix(second: 0)
        let widget = RecordingWidgetProvider()
        let core = FerrostarCore(
            routeAdapter: mockGETRouteAdapter,
            locationProvider: locationProvider,
            navigationControllerConfig: SwiftNavigationControllerConfig(
                waypointAdvance: .waypointWithinRange(100.0),
                // Manual: the core never advances a step by itself, so every advance is the test's.
                stepAdvanceCondition: stepAdvanceManual(),
                arrivalStepAdvanceCondition: stepAdvanceManual(),
                routeDeviationTracking: .none,
                snappedLocationCourseFiltering: .raw
            ),
            networkSession: MockURLSession(),
            spokenInstructionObserver: SpokenInstructionObserver(
                synthesizer: MockSpeechSynthesizer(),
                isMuted: true,
                managesAudioSession: false
            ),
            widgetProvider: widget
        )
        var published: [Int?] = []
        let subscription = core.$state.sink { published.append($0?.remainingSteps?.count) }
        defer { subscription.cancel() }

        try core.startNavigation(route: Self.sixStepRoute())
        drainMainQueue()
        // One fix, so the core holds a last location to advance from.
        locationProvider.lastLocation = Self.fix(second: 1)
        drainMainQueue()
        XCTAssertEqual(core.state?.remainingSteps?.count, 6)
        XCTAssertEqual(widget.updates.last, .init(visualText: "Step 0", spokenText: nil))

        // 1. Two steps with `announce`: one state, and one announcement, the target step's.
        var publishedMark = published.count
        var widgetMark = widget.updates.count
        core.advanceSteps(2, announce: true)
        drainMainQueue()
        XCTAssertEqual(Array(published[publishedMark...]), [4], "ONE state, two steps on")
        XCTAssertEqual(
            Array(widget.updates[widgetMark...]),
            [.init(visualText: "Step 2", spokenText: "Say 2")],
            "only the target step's instruction is queued, never the skipped step's"
        )

        // 2. One step without `announce`: no announcement, and the cue counts as played.
        publishedMark = published.count
        widgetMark = widget.updates.count
        core.advanceSteps(1, announce: false)
        drainMainQueue()
        XCTAssertEqual(Array(published[publishedMark...]), [3])
        XCTAssertEqual(Array(widget.updates[widgetMark...]), [.init(visualText: "Step 3", spokenText: nil)])
        locationProvider.lastLocation = Self.fix(second: 2)
        drainMainQueue()
        XCTAssertEqual(
            widget.updates.last,
            .init(visualText: "Step 3", spokenText: nil),
            "the next fix on the step does not speak the silenced cue either"
        )

        // 3. `hasPendingUpdate` is true between `didUpdateLocations` and its update block.
        XCTAssertFalse(core.hasPendingUpdate, "no location update waits")
        locationProvider.lastLocation = Self.fix(second: 3) // `didUpdateLocations` runs now; its block waits.
        XCTAssertTrue(core.hasPendingUpdate, "the fix's update block has not run yet")
        drainMainQueue()
        XCTAssertFalse(
            core.hasPendingUpdate,
            "the block ran, although the stored fix came back through the FFI a fraction of a microsecond earlier"
        )

        // 4. A fix handled before the advance's update block builds on the advanced state.
        publishedMark = published.count
        widgetMark = widget.updates.count
        core.advanceSteps(1, announce: true)
        XCTAssertFalse(core.hasPendingUpdate, "an advance is not a location update")
        locationProvider.lastLocation = Self.fix(second: 4)
        XCTAssertTrue(core.hasPendingUpdate)
        drainMainQueue()
        XCTAssertEqual(Array(published[publishedMark...]), [2, 2], "the fix's block keeps the advance")
        XCTAssertEqual(
            Array(widget.updates[widgetMark...]),
            [.init(visualText: "Step 4", spokenText: "Say 4"), .init(visualText: "Step 4", spokenText: nil)],
            "the target step's cue is queued once"
        )
        XCTAssertFalse(core.hasPendingUpdate)
    }
}
