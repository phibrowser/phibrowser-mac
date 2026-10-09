import AppKit
import Combine
import class SwiftUI.NSHostingView
import XCTest
@testable import Phi

@MainActor
final class PageScreenshotPresenterTests: XCTestCase {
    func testFileNameUsesThePageTitle() {
        XCTAssertEqual(PageScreenshotPresenter.suggestedFileName(title: "Phi Browser"), "Phi Browser.jpg")
        XCTAssertEqual(PageScreenshotPresenter.suggestedFileName(title: "  Page / Section: Details  "),
                       "Page Section Details.jpg")
        XCTAssertEqual(PageScreenshotPresenter.suggestedFileName(title: ""), "Screenshot.jpg")
        XCTAssertEqual(PageScreenshotPresenter.suggestedFileName(title: " / : "), "Screenshot.jpg")
    }

    func testSaveActionRetainsTheOriginalImageWindowAndFileName() throws {
        let center = OverlayToastCenter(targetResolver: { target in
            if case .windowId(let id) = target { return id }
            return nil
        }, scheduler: { _, _ in AnyCancellable {} })
        let firstImage = Data([1, 2, 3]), secondImage = Data([4, 5, 6])
        var saved: [(Data, String, Int)] = []
        PageScreenshotPresenter.showCopied(jpegData: firstImage, title: "First Page", windowId: 7,
                                           toastCenter: center, save: { saved.append(($0, $1, $2)) })
        let firstToast = try XCTUnwrap(center.visibleToasts(for: 7).first)
        let firstAction = try XCTUnwrap(firstToast.action)
        XCTAssertEqual(firstAction.title, "Save")
        XCTAssertTrue(firstAction.isBordered)
        XCTAssertEqual(firstToast.duration, 6)
        PageScreenshotPresenter.showCopied(jpegData: secondImage, title: "Second Page", windowId: 8,
                                           toastCenter: center, save: { saved.append(($0, $1, $2)) })
        firstAction.handler()
        let savedImage = try XCTUnwrap(saved.first)
        XCTAssertEqual(savedImage.0, firstImage)
        XCTAssertEqual(savedImage.1, "First Page.jpg")
        XCTAssertEqual(savedImage.2, 7)
        XCTAssertEqual(saved.count, 1)
    }

    func testSaveButtonUsesTheSameNativeBackgroundAsShareAndInvokesItsAction() throws {
        let center = OverlayToastCenter(targetResolver: { _ in 7 },
                                        scheduler: { _, _ in AnyCancellable {} })
        var didSave = false
        PageScreenshotPresenter.showCopied(jpegData: Data([1, 2, 3]), title: "Page", windowId: 7,
                                           toastCenter: center, save: { _, _, _ in didSave = true })
        var toast = try XCTUnwrap(center.visibleToasts(for: 7).first)
        toast.shareURLs = [try XCTUnwrap(URL(string: "https://example.com"))]
        let host = NSHostingView(rootView: OverlayToastView(toast: toast, toastCenter: center))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rendered = expectation(description: "Native toast buttons mounted")
        DispatchQueue.main.async { rendered.fulfill() }
        wait(for: [rendered], timeout: 1)
        host.layoutSubtreeIfNeeded()

        func button(_ identifier: String, in view: NSView) -> NSButton? {
            if let button = view as? NSButton,
               button.accessibilityIdentifier() == identifier,
               !button.isHiddenOrHasHiddenAncestor { return button }
            return view.subviews.lazy.compactMap { button(identifier, in: $0) }.first
        }
        let save = try XCTUnwrap(button("overlayToast.action", in: host))
        let share = try XCTUnwrap(button("overlayToast.shareButton", in: host))
        XCTAssertTrue(save.isBordered)
        XCTAssertEqual(save.bezelStyle, share.bezelStyle)
        XCTAssertEqual(save.controlSize, share.controlSize)
        save.performClick(nil)
        XCTAssertTrue(didSave)
        XCTAssertTrue(center.visibleToasts(for: 7).isEmpty)
    }
}
