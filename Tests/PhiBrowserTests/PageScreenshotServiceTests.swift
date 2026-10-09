import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Phi

@MainActor
final class PageScreenshotServiceTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.setString("original clipboard", forType: .string)
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    private func jpeg(size: Int = 2, noise: Bool = false) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(bitmap.bitmapData!, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
        if noise {
            var seed: UInt32 = 0x12345678
            for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
                seed ^= seed << 13
                seed ^= seed >> 17
                seed ^= seed << 5
                bitmap.bitmapData![index] = UInt8(truncatingIfNeeded: seed)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
    }

    func testSnapshotsTargetAndRejectsRepeatedInvocationUntilCompletion() async throws {
        let board = pasteboard(), image = try jpeg()
        let started = expectation(description: "Capture starts")
        let completed = expectation(description: "Capture completes")
        var resume: CheckedContinuation<String?, Error>?
        var capturedTarget: String?
        let service = PageScreenshotService(pasteboard: board, captureJPEG: { targetId, timeout in
            capturedTarget = targetId
            XCTAssertEqual(timeout, 60)
            return try await withCheckedThrowingContinuation {
                resume = $0
                started.fulfill()
            }
        })
        XCTAssertFalse(service.start(targetId: "", windowId: 7) { _ in XCTFail() })
        XCTAssertFalse(service.start(targetId: "page-42", windowId: -1) { _ in XCTFail() })
        XCTAssertTrue(service.start(targetId: "page-42", windowId: 7) { outcome in
            XCTAssertEqual(outcome, .copied(image))
            completed.fulfill()
        })
        XCTAssertTrue(service.isCapturing)
        XCTAssertFalse(service.start(targetId: "page-99", windowId: 8) { _ in XCTFail() })
        // Let the capture start while its response remains suspended.
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(capturedTarget, "page-42")
        try XCTUnwrap(resume).resume(returning: image.base64EncodedString())
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(service.isCapturing)
        XCTAssertEqual(board.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)), image)
    }

    func testSuccessCopiesBinaryJPEGAndCompletesOnce() async throws {
        let board = pasteboard(), image = try jpeg()
        let completed = expectation(description: "JPEG copied")
        var outcomes: [PageScreenshotService.Outcome] = []
        let service = PageScreenshotService(pasteboard: board, captureJPEG: { _, _ in image.base64EncodedString() })
        service.start(targetId: "page-42", windowId: 7) { outcome in
            outcomes.append(outcome)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(board.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)), image)
        XCTAssertNil(board.string(forType: .string))
        XCTAssertNotNil(NSImage(pasteboard: board))
        XCTAssertNil(board.data(forType: .png))
        XCTAssertEqual(outcomes, [.copied(image)])
        XCTAssertFalse(service.isCapturing)
    }

    func testCaptureFailurePreservesClipboardAndAllowsRetry() async throws {
        let board = pasteboard(), image = try jpeg()
        let failed = expectation(description: "Capture fails")
        let retried = expectation(description: "Retry succeeds")
        var shouldFail = true
        let service = PageScreenshotService(pasteboard: board, captureJPEG: { _, _ in
            if shouldFail { throw AppDevToolsPageSession.SessionError.connectionClosed }
            return image.base64EncodedString()
        })
        let count = board.changeCount
        service.start(targetId: "page-42", windowId: 7) { outcome in
            XCTAssertEqual(outcome, .captureFailed)
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(service.isCapturing)
        XCTAssertEqual(board.changeCount, count)
        shouldFail = false
        XCTAssertTrue(service.start(targetId: "page-99", windowId: 8) { outcome in
            XCTAssertEqual(outcome, .copied(image))
            retried.fulfill()
        })
        await fulfillment(of: [retried], timeout: 2)
    }

    func testNewerUserCopyIsPreserved() async throws {
        let board = pasteboard(), image = try jpeg()
        let completed = expectation(description: "New clipboard preserved")
        let service = PageScreenshotService(pasteboard: board, captureJPEG: { _, _ in
            board.clearContents()
            board.setString("newer user copy", forType: .string)
            return image.base64EncodedString()
        })
        service.start(targetId: "page-42", windowId: 7) { outcome in
            XCTAssertEqual(outcome, .clipboardChanged)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(board.string(forType: .string), "newer user copy")
        XCTAssertNil(board.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)))
    }

    func testExpiredDeadlineRejectsLateResponseAndPreservesClipboard() async throws {
        let board = pasteboard(), image = try jpeg()
        var time: TimeInterval = 100
        let completed = expectation(description: "Late response rejected")
        let service = PageScreenshotService(pasteboard: board, uptime: { time }, captureJPEG: { _, _ in
            time = 160
            return image.base64EncodedString()
        })
        let count = board.changeCount
        service.start(targetId: "page-42", windowId: 7) { outcome in
            XCTAssertEqual(outcome, .timedOut)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(board.changeCount, count)
        XCTAssertFalse(service.isCapturing)
    }

    func testCDPTimeoutPreservesClipboardAndReleasesCapture() async {
        let board = pasteboard()
        let completed = expectation(description: "CDP timeout reported")
        let service = PageScreenshotService(pasteboard: board, captureJPEG: { _, _ in
            throw AppDevToolsPageSession.SessionError.timedOut
        })
        let count = board.changeCount
        service.start(targetId: "page-42", windowId: 7) { outcome in
            XCTAssertEqual(outcome, .timedOut)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(board.changeCount, count)
        XCTAssertFalse(service.isCapturing)
    }

    func testMissingAndInvalidJPEGResponsesPreserveClipboard() async throws {
        for data in [nil, "not base64", Data("not a JPEG".utf8).base64EncodedString()] as [String?] {
            let board = pasteboard()
            let completed = expectation(description: "Invalid image rejected")
            let service = PageScreenshotService(pasteboard: board, captureJPEG: { _, _ in data })
            let count = board.changeCount
            service.start(targetId: "page-42", windowId: 7) { outcome in
                XCTAssertEqual(outcome, .invalidImage)
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertEqual(board.changeCount, count)
            XCTAssertFalse(service.isCapturing)
        }
    }

    func testJPEGValidationRejectsTruncatedOversizedAndExcessiveDimensions() throws {
        let image = try jpeg()
        XCTAssertEqual(PageScreenshotService.validatedJPEG(image.base64EncodedString()), image)
        XCTAssertNil(PageScreenshotService.validatedJPEG(image.prefix(33).base64EncodedString()))
        XCTAssertNil(PageScreenshotService.validatedJPEG(String(repeating: "A", count: PageScreenshotService.maxBase64Bytes + 1)))
        XCTAssertNil(PageScreenshotService.validatedJPEG(image.dropLast(2).base64EncodedString()))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: image))
        let png = try XCTUnwrap(decoded.representation(using: .png, properties: [:]))
        XCTAssertNil(PageScreenshotService.validatedJPEG(png.base64EncodedString()))
        // Patch the baseline JPEG frame header without allocating an oversized bitmap.
        let frame = try XCTUnwrap(image.range(of: Data([0xff, 0xc0]))).lowerBound
        for (width, height) in [(0, 2), (32_769, 1), (8_001, 8_000)] {
            var bytes = image
            for (offset, value) in [(frame + 7, width), (frame + 5, height)] {
                bytes.replaceSubrange(offset..<(offset + 2), with: [UInt8(value >> 8), UInt8(value & 255)])
            }
            XCTAssertNil(PageScreenshotService.validatedJPEG(bytes.base64EncodedString()))
        }
    }


    private final class CDPFixture {
        var calls: [(method: String, params: [String: Any], timeout: TimeInterval)] = []
        var openedTargets: [String] = []
        var openTimeout: TimeInterval?
        var closeCount = 0
        var frameCount = 0
        var size: [String: Any] = ["x": 0, "y": 0, "width": 1200, "height": 4000]
        var dpr: Any = 1
        var data: Any?
        var frame: [String: Any] = ["id": "frame-1", "loaderId": "loader-1", "url": "https://example.invalid/"]
        var afterFrame: [String: Any]?
        var failingMethod: String?
        var failFinalFrameQuery = false
        var openFails = false
        var commandDelay: UInt64 = 0

        init(data: String) { self.data = data }

        func open(_ target: String, _ timeout: TimeInterval) async throws -> PageScreenshotService.CaptureSession {
            openedTargets.append(target)
            openTimeout = timeout
            if openFails { throw AppDevToolsPageSession.SessionError.upgradeFailed }
            return .init(command: { method, params, timeout in
                self.calls.append((method, params, timeout))
                if self.commandDelay > 0 { try await Task.sleep(nanoseconds: self.commandDelay) }
                if self.failingMethod == method || (method == "Page.getFrameTree" && self.frameCount == 1 && self.failFinalFrameQuery) {
                    throw AppDevToolsPageSession.SessionError.connectionClosed
                }
                switch method {
                case "Page.getFrameTree":
                    self.frameCount += 1
                    return ["frameTree": ["frame": self.frameCount == 1 ? self.frame : (self.afterFrame ?? self.frame)]]
                case "Page.getLayoutMetrics": return ["cssContentSize": self.size]
                case "Runtime.evaluate": return ["result": ["value": self.dpr]]
                case "Page.captureScreenshot": return self.data.map { ["data": $0] } ?? [:]
                default: XCTFail("Unexpected CDP method: \(method)"); return [:]
                }
            }, close: { self.closeCount += 1 })
        }
    }

    private func capture(_ fixture: CDPFixture, timeout: TimeInterval = 60) async throws -> String? {
        try await PageScreenshotService.capturePage(targetId: "page-42", timeout: timeout, openSession: fixture.open)
    }

    func testCDPCaptureUsesJPEGQualityAndFullDocumentClip() async throws {
        let image = try jpeg(), fixture = CDPFixture(data: image.base64EncodedString())
        fixture.size = ["x": 1.25, "y": -3.5, "width": 1200.1, "height": 4000.2]
        let result = try await capture(fixture)
        XCTAssertEqual(result, image.base64EncodedString())
        XCTAssertEqual(PageScreenshotService.validatedJPEG(try XCTUnwrap(result)), image)
        XCTAssertEqual(fixture.openedTargets, ["page-42"])
        XCTAssertEqual(fixture.openTimeout, 10)
        XCTAssertEqual(fixture.closeCount, 1)
        XCTAssertEqual(fixture.calls.map(\.method), ["Page.getFrameTree", "Page.getLayoutMetrics", "Runtime.evaluate", "Page.captureScreenshot", "Page.getFrameTree"])
        let params = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params)
        XCTAssertEqual(params["format"] as? String, "jpeg")
        XCTAssertEqual(params["quality"] as? Int, 85)
        XCTAssertEqual(params["fromSurface"] as? Bool, true)
        XCTAssertEqual(params["captureBeyondViewport"] as? Bool, true)
        let clip = try XCTUnwrap(params["clip"] as? [String: Double])
        XCTAssertEqual(clip, ["x": 1.25, "y": -3.5, "width": 1201, "height": 4001, "scale": 1])
        XCTAssertEqual(fixture.calls[2].params["expression"] as? String, "window.devicePixelRatio")
        XCTAssertEqual(fixture.calls[2].params["returnByValue"] as? Bool, true)
        XCTAssertTrue(fixture.calls.allSatisfy { $0.timeout > 0 && $0.timeout <= 15 })
    }

    func testCDPCaptureFitsRetinaLongPagesInBothOrientations() async throws {
        for (width, height) in [(1719, 8718), (8718, 1719)] {
            let fixture = CDPFixture(data: try jpeg().base64EncodedString())
            fixture.size = ["x": 0, "y": 0, "width": width, "height": height]
            fixture.dpr = 2
            _ = try await capture(fixture)
            let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
            XCTAssertEqual(try XCTUnwrap(clip["scale"]), 16384.0 / (8718 * 2), accuracy: 0.0000001)
            XCTAssertEqual(clip["width"], Double(width))
            XCTAssertEqual(clip["height"], Double(height))
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureKeepsUnitScaleAt16KBoundaryAndForNonRetinaPage() async throws {
        for (height, dpr) in [(8192, 2), (8718, 1)] {
            let fixture = CDPFixture(data: try jpeg().base64EncodedString())
            fixture.size = ["x": 0, "y": 0, "width": 1719, "height": height]
            fixture.dpr = dpr
            _ = try await capture(fixture)
            let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
            XCTAssertEqual(clip["scale"], 1)
        }
    }

    func testCDPCaptureRejectsInvalidDimensionsBeforeScreenshotAndCloses() async throws {
        for (key, value) in [("x", Double.nan as Any), ("y", "0" as Any), ("width", 0 as Any), ("height", -1 as Any), ("width", true as Any), ("height", NSNull() as Any)] {
            let fixture = CDPFixture(data: try jpeg().base64EncodedString())
            fixture.size[key] = value
            do { _ = try await capture(fixture); XCTFail("Accepted invalid \(key)") }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) { XCTAssertEqual(message, "Invalid screenshot page dimensions") }
            XCTAssertFalse(fixture.calls.contains { $0.method == "Page.captureScreenshot" })
            XCTAssertEqual(fixture.closeCount, 1)
        }
        for value: Any in [0, -1, Double.infinity, "2", true, NSNull()] {
            let fixture = CDPFixture(data: try jpeg().base64EncodedString())
            fixture.dpr = value
            do { _ = try await capture(fixture); XCTFail("Accepted invalid DPR") }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) { XCTAssertEqual(message, "Invalid screenshot page dimensions") }
            XCTAssertFalse(fixture.calls.contains { $0.method == "Page.captureScreenshot" })
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureScalesWideRetinaPagesBeforeApplyingPixelLimits() async throws {
        for width in [1719, 1904] {
            let fixture = CDPFixture(data: try jpeg().base64EncodedString())
            fixture.size = ["x": 0, "y": 0, "width": width, "height": 9519]
            fixture.dpr = 2
            _ = try await capture(fixture)
            let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
            let scale = try XCTUnwrap(clip["scale"])
            XCTAssertEqual(clip["width"], Double(width))
            XCTAssertEqual(clip["height"], 9519)
            XCTAssertEqual(scale, 16384.0 / (9519 * 2), accuracy: 0.0000001)
            XCTAssertLessThanOrEqual(ceil(Double(width) * 2 * scale) * ceil(9519 * 2 * scale), 64_000_000)
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureScalesOversizedPagesWithinRoundedOutputBudget() async throws {
        for (width, height, dpr) in [(16385, 1, 2), (1, 16385, 2), (8001, 8000, 1), (10000, 10000, 2), (20000, 10000, 1), (10000, 20000, 1)] {
            let fixture = CDPFixture(data: try jpeg().base64EncodedString())
            fixture.size = ["x": 0, "y": 0, "width": width, "height": height]
            fixture.dpr = dpr
            _ = try await capture(fixture)
            let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
            let scale = try XCTUnwrap(clip["scale"])
            let outputWidth = ceil(Double(width * dpr) * scale)
            let outputHeight = ceil(Double(height * dpr) * scale)
            XCTAssertGreaterThan(scale, 0)
            XCTAssertLessThan(scale, 1)
            XCTAssertLessThanOrEqual(outputWidth, 16_384)
            XCTAssertLessThanOrEqual(outputHeight, 16_384)
            XCTAssertLessThanOrEqual(outputWidth * outputHeight, 64_000_000)
            XCTAssertEqual(clip["width"], Double(width))
            XCTAssertEqual(clip["height"], Double(height))
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCapturePreservesUnitScaleAtPixelBudget() async throws {
        let fixture = CDPFixture(data: try jpeg().base64EncodedString())
        fixture.size = ["x": 0, "y": 0, "width": 8000, "height": 8000]
        fixture.dpr = 1
        _ = try await capture(fixture)
        let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
        XCTAssertEqual(clip["scale"], 1)
    }

    func testCDPCaptureRejectsOverflowingPhysicalDimensions() async throws {
        let fixture = CDPFixture(data: try jpeg().base64EncodedString())
        fixture.size = ["x": 0, "y": 0, "width": Double.greatestFiniteMagnitude, "height": 100]
        fixture.dpr = 2
        do { _ = try await capture(fixture); XCTFail("Accepted overflowing dimensions") }
        catch AppDevToolsPageSession.SessionError.commandFailed {}
        XCTAssertFalse(fixture.calls.contains { $0.method == "Page.captureScreenshot" })
        XCTAssertEqual(fixture.closeCount, 1)
    }

    func testCDPCaptureChecksEveryDocumentIdentityFieldAndCloses() async throws {
        for key in ["id", "loaderId", "url"] {
            let fixture = CDPFixture(data: try jpeg().base64EncodedString())
            fixture.afterFrame = fixture.frame
            fixture.afterFrame?[key] = "changed"
            do { _ = try await capture(fixture); XCTFail("Accepted changed \(key)") }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) { XCTAssertEqual(message, "Page navigated while taking the screenshot") }
            XCTAssertEqual(fixture.frameCount, 2)
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureRejectsMissingDocumentIdentityBeforeScreenshot() async throws {
        for key in ["id", "loaderId", "url"] {
            let fixture = CDPFixture(data: try jpeg().base64EncodedString())
            fixture.frame[key] = ""
            do { _ = try await capture(fixture); XCTFail("Accepted empty \(key)") }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) { XCTAssertEqual(message, "Unable to identify the page document") }
            XCTAssertTrue(fixture.calls.allSatisfy { $0.method == "Page.getFrameTree" })
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureClosesAfterFailureAtEveryCommand() async throws {
        for method in ["Page.getFrameTree", "Page.getLayoutMetrics", "Runtime.evaluate", "Page.captureScreenshot"] {
            let fixture = CDPFixture(data: try jpeg().base64EncodedString())
            fixture.failingMethod = method
            do { _ = try await capture(fixture); XCTFail("Ignored command failure") }
            catch AppDevToolsPageSession.SessionError.connectionClosed {}
            XCTAssertEqual(fixture.calls.last?.method, method)
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureRejectsInvalidJPEGReplyBeforeFinalFrameQuery() async throws {
        for data: Any? in [nil, 42, "not a JPEG", "/9j/" + String(repeating: "A", count: PageScreenshotService.maxBase64Bytes)] {
            let fixture = CDPFixture(data: try jpeg().base64EncodedString())
            fixture.data = data
            do { _ = try await capture(fixture); XCTFail("Accepted invalid image") }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) { XCTAssertEqual(message, "Invalid or oversized screenshot image") }
            XCTAssertEqual(fixture.frameCount, 1)
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureClosesWhenTotalBudgetExpiresBetweenCommands() async throws {
        let fixture = CDPFixture(data: try jpeg().base64EncodedString())
        fixture.commandDelay = 20_000_000
        do { _ = try await capture(fixture, timeout: 0.01); XCTFail("Ignored deadline") }
        catch AppDevToolsPageSession.SessionError.timedOut {}
        XCTAssertEqual(fixture.closeCount, 1)
        XCTAssertEqual(fixture.openTimeout, 0.01)
    }

    func testCDPCaptureDoesNotCloseAnUnacquiredSession() async throws {
        let fixture = CDPFixture(data: try jpeg().base64EncodedString())
        fixture.openFails = true
        do { _ = try await capture(fixture); XCTFail("Ignored attach failure") }
        catch AppDevToolsPageSession.SessionError.upgradeFailed {}
        XCTAssertEqual(fixture.closeCount, 0)
        XCTAssertTrue(fixture.calls.isEmpty)
    }


    func testCDPCaptureClosesAfterFinalFrameQueryFailureOrInvalidIdentity() async throws {
        for fails in [true, false] {
            let fixture = CDPFixture(data: try jpeg().base64EncodedString())
            fixture.failFinalFrameQuery = fails
            fixture.afterFrame = [:]
            do { _ = try await capture(fixture); XCTFail("Accepted failed final frame query") }
            catch AppDevToolsPageSession.SessionError.connectionClosed { XCTAssertTrue(fails) }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) {
                XCTAssertFalse(fails)
                XCTAssertEqual(message, "Unable to identify the page document")
            }
            XCTAssertEqual(fixture.calls.map(\.method), ["Page.getFrameTree", "Page.getLayoutMetrics", "Runtime.evaluate", "Page.captureScreenshot", "Page.getFrameTree"])
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

}
