import XCTest
@testable import Phi

/// The step bar lists only the pages the plan shows, numbered in order, with earlier pages complete.
@MainActor
final class PairingStepBarTests: XCTestCase {
    private typealias Segment = PairingStepBar.Segment

    func testSegmentsBeforeTheCurrentPageAreComplete() {
        XCTAssertEqual(PairingStepBar.segments(steps: [.profiles, .spaces], current: .spaces), [
            Segment(id: 1, step: .profiles, isComplete: true, isCurrent: false),
            Segment(id: 2, step: .spaces, isComplete: false, isCurrent: true),
        ])
        XCTAssertEqual(PairingStepBar.segments(steps: [.profiles, .spaces], current: .profiles), [
            Segment(id: 1, step: .profiles, isComplete: false, isCurrent: true),
            Segment(id: 2, step: .spaces, isComplete: false, isCurrent: false),
        ])
    }

    func testAHiddenPageIsNotNumbered() {
        XCTAssertEqual(PairingStepBar.segments(steps: [.spaces], current: .spaces), [
            Segment(id: 1, step: .spaces, isComplete: false, isCurrent: true),
        ])
        XCTAssertEqual(PairingStepBar.segments(steps: [.method, .spaces], current: .spaces).map(\.id), [1, 2])
    }

    func testBothMethodsSequences() {
        XCTAssertEqual(PairingStepBar.segments(steps: [.method, .confirm], current: .confirm), [
            Segment(id: 1, step: .method, isComplete: true, isCurrent: false),
            Segment(id: 2, step: .confirm, isComplete: false, isCurrent: true),
        ])
        XCTAssertEqual(PairingStepBar.segments(steps: [.method, .profiles, .spaces], current: .method)
            .map(\.isCurrent), [true, false, false])
    }

    func testNoStepsOrNoCurrentPageMarksNothing() {
        XCTAssertEqual(PairingStepBar.segments(steps: [], current: .profiles), [],
                       "Loading and automatic completion show an empty bar")
        XCTAssertTrue(PairingStepBar.segments(steps: [.profiles, .spaces], current: nil)
            .allSatisfy { !$0.isComplete && !$0.isCurrent })
        XCTAssertTrue(PairingStepBar.segments(steps: [.spaces], current: .profiles)
            .allSatisfy { !$0.isComplete && !$0.isCurrent },
                      "A current page the bar does not list marks nothing")
    }

    func testEveryStepHasATitle() {
        for step in [PairingWizardStep.method, .profiles, .spaces, .confirm] {
            XCTAssertFalse(PairingStepBar.title(for: step).isEmpty)
        }
        XCTAssertEqual(PairingStepBar.title(for: .method), "Sync method")
        XCTAssertEqual(PairingStepBar.title(for: .confirm), "Confirm")
    }
}
