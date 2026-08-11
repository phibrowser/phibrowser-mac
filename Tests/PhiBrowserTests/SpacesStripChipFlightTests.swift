// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftUI
import XCTest
@testable import Phi

/// The chip flight's pure rules, pinned the way the lazy-restore wiring's
/// are: the eligibility gate (fly only between pips wholly inside the
/// viewport's clip frame — the stand-in layer is not clipped by SwiftUI),
/// the SwiftUI-frame-to-layer-frame conversion, the stand-in layer's shape
/// (model geometry already at the target, travel carried by an explicit
/// animation), and the strip geometry's publishing contract (layout writes
/// must not re-render the strip).
final class SpacesStripChipFlightTests: XCTestCase {
    private let viewport = CGRect(x: 10, y: 4, width: 200, height: 24)
    private let insideA = CGRect(x: 10, y: 4, width: 24, height: 24)
    private let insideB = CGRect(x: 38, y: 4, width: 24, height: 24)
    /// Overlaps the viewport's leading edge — the half-pip peek shape.
    private let peeking = CGRect(x: 0, y: 4, width: 24, height: 24)

    private func endpoints(
        from: String = "a", to: String = "b",
        pipFrames: [String: CGRect]? = nil,
        viewportFrame: CGRect? = nil,
        duration: TimeInterval = 0.15
    ) -> (from: CGRect, to: CGRect)? {
        SpacesStripHostingView.chipFlightEndpoints(
            fromSpaceId: from,
            toSpaceId: to,
            pipFrames: pipFrames ?? ["a": insideA, "b": insideB],
            viewportFrame: viewportFrame ?? viewport,
            duration: duration
        )
    }

    func testFliesBetweenPipsInsideTheViewport() {
        let resolved = endpoints()
        XCTAssertEqual(resolved?.from, insideA)
        XCTAssertEqual(resolved?.to, insideB)
    }

    func testRefusesADegenerateSwitch() {
        XCTAssertNil(endpoints(from: "a", to: "a"))
        XCTAssertNil(endpoints(duration: 0))
        XCTAssertNil(endpoints(duration: -1))
    }

    func testRefusesUnpublishedPips() {
        XCTAssertNil(endpoints(pipFrames: ["a": insideA]))
        XCTAssertNil(endpoints(pipFrames: ["b": insideB]))
        XCTAssertNil(endpoints(pipFrames: [:]))
    }

    func testRefusesAnUnpublishedViewport() {
        XCTAssertNil(endpoints(viewportFrame: .zero))
    }

    func testRefusesAPipOutsideTheViewport() {
        // Either endpoint in the overflow/peek region grounds the flight —
        // the stand-in would fly outside the row's clip.
        XCTAssertNil(endpoints(pipFrames: ["a": peeking, "b": insideB]))
        XCTAssertNil(endpoints(pipFrames: ["a": insideA, "b": peeking]))
    }

    func testLayerRectPassesThroughOnAFlippedHost() {
        let rect = CGRect(x: 10, y: 4, width: 24, height: 24)
        XCTAssertEqual(
            SpacesStripHostingView.chipLayerRect(rect, boundsHeight: 32, isFlipped: true),
            rect
        )
    }

    func testLayerRectFlipsYOnAnUnflippedHost() {
        // Both fixtures are vertically asymmetric in their bounds, so a
        // pass-through implementation cannot sneak past either assertion.
        let nearTop = CGRect(x: 10, y: 2, width: 24, height: 24)
        XCTAssertEqual(
            SpacesStripHostingView.chipLayerRect(nearTop, boundsHeight: 32, isFlipped: false),
            CGRect(x: 10, y: 6, width: 24, height: 24)
        )
        let atOrigin = CGRect(x: 0, y: 0, width: 24, height: 24)
        XCTAssertEqual(
            SpacesStripHostingView.chipLayerRect(atOrigin, boundsHeight: 32, isFlipped: false),
            CGRect(x: 0, y: 8, width: 24, height: 24)
        )
    }

    func testStandInModelIsAlreadyAtTheTarget() {
        // The model must settle on the TARGET frame: the explicit animation
        // carries the travel, and when CA removes it on completion — which
        // can land mid-block — the settled model shows. A model left at the
        // source would snap the chip back to the source pip right there.
        let from = CGRect(x: 10, y: 4, width: 24, height: 24)
        let to = CGRect(x: 66, y: 4, width: 24, height: 24)
        let chip = SpacesStripHostingView.makeChipFlightLayer(
            from: from, to: to, duration: 0.15,
            fillColor: NSColor.white.cgColor
        )
        XCTAssertEqual(chip.frame, to)
        let slide = chip.animation(forKey: "phiSpacesChipFlight") as? CABasicAnimation
        XCTAssertNotNil(slide)
        XCTAssertEqual(slide?.fromValue as? CGPoint, CGPoint(x: from.midX, y: from.midY))
        XCTAssertEqual(slide?.toValue as? CGPoint, CGPoint(x: to.midX, y: to.midY))
        XCTAssertEqual(slide?.duration ?? 0, 0.15, accuracy: 0.0001)
        XCTAssertEqual(chip.zPosition, -1)
    }

    func testGeometryWritesDoNotPublishAndConcealmentDoes() {
        // The strip observes SpacesStripGeometry; layout writes frames on
        // every pass, so those must stay silent — only the concealment flag
        // may re-render the strip.
        let geometry = SpacesStripGeometry()
        var events = 0
        let subscription = geometry.objectWillChange.sink { _ in events += 1 }
        geometry.pipFrames["a"] = CGRect(x: 0, y: 0, width: 24, height: 24)
        geometry.viewportFrame = CGRect(x: 0, y: 0, width: 200, height: 24)
        XCTAssertEqual(events, 0)
        geometry.isChipConcealed = true
        XCTAssertEqual(events, 1)
        geometry.isChipConcealed = false
        XCTAssertEqual(events, 2)
        subscription.cancel()
    }
}

/// The hosting view's begin/cancel contract, exercised on a real
/// `SpacesStripHostingView` (empty SwiftUI root — the flight machinery only
/// needs the view's layer and the injected geometry): the stand-in mounts
/// and conceals on begin, sweeps and restores on cancel, cancel is
/// idempotent, and an ineligible begin has zero side effects — INCLUDING
/// leaving a live flight untouched, the ordering the eligibility-first
/// sweep exists for.
@MainActor
final class SpacesStripChipFlightHostTests: XCTestCase {
    private let viewport = CGRect(x: 10, y: 4, width: 200, height: 24)
    private let insideA = CGRect(x: 10, y: 4, width: 24, height: 24)
    private let insideB = CGRect(x: 38, y: 4, width: 24, height: 24)

    private func makeHost() -> (SpacesStripHostingView, SpacesStripGeometry) {
        let host = SpacesStripHostingView(rootView: AnyView(EmptyView()))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 32)
        host.wantsLayer = true
        let geometry = SpacesStripGeometry()
        geometry.pipFrames = ["a": insideA, "b": insideB]
        geometry.viewportFrame = viewport
        host.stripGeometry = geometry
        return (host, geometry)
    }

    private func flightLayers(of host: SpacesStripHostingView) -> [CALayer] {
        (host.layer?.sublayers ?? []).filter {
            $0.animation(forKey: "phiSpacesChipFlight") != nil
        }
    }

    func testBeginMountsTheStandInAndConcealsTheChip() {
        let (host, geometry) = makeHost()
        XCTAssertTrue(host.beginSpacesChipFlight(fromSpaceId: "a", toSpaceId: "b",
                                                 duration: 0.15))
        XCTAssertEqual(flightLayers(of: host).count, 1)
        XCTAssertTrue(geometry.isChipConcealed)
        // A4 record for the implementation report: whether the host layer
        // would clip the stand-in's 1pt shadow.
        print("A4: SpacesStripHostingView.layer.masksToBounds = "
              + "\(host.layer?.masksToBounds ?? false)")
    }

    func testCancelSweepsTheStandInAndRestoresTheChip() {
        let (host, geometry) = makeHost()
        _ = host.beginSpacesChipFlight(fromSpaceId: "a", toSpaceId: "b", duration: 0.15)
        host.cancelSpacesChipFlight()
        XCTAssertTrue(flightLayers(of: host).isEmpty)
        XCTAssertFalse(geometry.isChipConcealed)
    }

    func testDoubleCancelIsIdempotent() {
        let (host, geometry) = makeHost()
        _ = host.beginSpacesChipFlight(fromSpaceId: "a", toSpaceId: "b", duration: 0.15)
        host.cancelSpacesChipFlight()
        var events = 0
        let subscription = geometry.objectWillChange.sink { _ in events += 1 }
        host.cancelSpacesChipFlight()
        XCTAssertEqual(events, 0)
        XCTAssertTrue(flightLayers(of: host).isEmpty)
        XCTAssertFalse(geometry.isChipConcealed)
        subscription.cancel()
    }

    func testIneligibleBeginHasZeroSideEffects() {
        let (host, geometry) = makeHost()
        XCTAssertFalse(host.beginSpacesChipFlight(fromSpaceId: "missing", toSpaceId: "b",
                                                  duration: 0.15))
        XCTAssertTrue(flightLayers(of: host).isEmpty)
        XCTAssertFalse(geometry.isChipConcealed)
    }

    func testIneligibleBeginDoesNotSweepALiveFlight() {
        let (host, geometry) = makeHost()
        XCTAssertTrue(host.beginSpacesChipFlight(fromSpaceId: "a", toSpaceId: "b",
                                                 duration: 0.15))
        let live = flightLayers(of: host)
        XCTAssertEqual(live.count, 1)
        XCTAssertFalse(host.beginSpacesChipFlight(fromSpaceId: "missing", toSpaceId: "b",
                                                  duration: 0.15))
        let after = flightLayers(of: host)
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(after.first === live.first)
        XCTAssertTrue(geometry.isChipConcealed)
    }
}
