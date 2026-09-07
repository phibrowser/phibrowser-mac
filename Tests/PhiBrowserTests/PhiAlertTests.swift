// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI
import XCTest
@testable import Phi

@MainActor
final class PhiAlertTests: XCTestCase {
    func testLayoutMatchesFigmaMetrics() {
        XCTAssertEqual(PhiAlertLayout.width, 465)
        XCTAssertEqual(PhiAlertLayout.contentWidth, 417)
        XCTAssertEqual(PhiAlertLayout.outerPadding, 24)
        XCTAssertEqual(PhiAlertLayout.cornerRadius, 24)
        XCTAssertEqual(PhiAlertLayout.iconToCopySpacing, 24)
        XCTAssertEqual(PhiAlertLayout.copySpacing, 16)
        XCTAssertEqual(PhiAlertLayout.actionsSpacing, 36)
        XCTAssertEqual(PhiAlertLayout.iconSize.width, 24)
        XCTAssertEqual(PhiAlertLayout.iconSize.height, 28.4)
        XCTAssertEqual(PhiAlertLayout.titleHeight, 16)
        XCTAssertEqual(PhiAlertLayout.actionHeight, 36)
    }

    func testMaximumScrollableHeightClampsUndersizedConfiguration() {
        let requestedMaximum = PhiAlertLayout.fixedChromeHeight - 100

        XCTAssertEqual(
            PhiAlertLayout.maximumScrollableContentHeight(for: requestedMaximum),
            PhiAlertLayout.minimumContentHeight
        )
    }

    func testShortAlertUsesFixedWidthAndStaysBelowMaximumHeight() {
        let maximumHeight: CGFloat = 500
        let hostingController = makeHostingController(
            message: "You may lose unsaved work",
            maximumHeight: maximumHeight
        )

        let size = hostingController.sizeThatFits(
            in: CGSize(width: PhiAlertLayout.width, height: .greatestFiniteMagnitude)
        )

        XCTAssertEqual(size.width, PhiAlertLayout.width, accuracy: 0.5)
        XCTAssertEqual(
            size.height,
            PhiAlertLayout.fixedChromeHeight + PhiAlertLayout.minimumContentHeight,
            accuracy: 2
        )
        XCTAssertLessThan(size.height, maximumHeight)
    }

    func testLongAlertContentStopsAtMaximumHeight() {
        let maximumHeight: CGFloat = 420
        let message = Array(repeating: "This line must remain readable.", count: 80)
            .joined(separator: "\n")
        let hostingController = makeHostingController(
            message: message,
            maximumHeight: maximumHeight
        )

        let size = hostingController.sizeThatFits(
            in: CGSize(width: PhiAlertLayout.width, height: .greatestFiniteMagnitude)
        )

        XCTAssertEqual(size.width, PhiAlertLayout.width, accuracy: 0.5)
        XCTAssertEqual(size.height, maximumHeight, accuracy: 1)
    }

    func testOneTwoAndThreeActionLayoutsKeepTheSameAlertGeometry() {
        let oneAction = makeHostingController(
            message: "One action",
            maximumHeight: 500
        ).sizeThatFits(
            in: CGSize(width: PhiAlertLayout.width, height: .greatestFiniteMagnitude)
        )
        let twoActions = ThemedHostingController(
            rootView: PhiAlert(title: "Two actions") {
                testIcon
            } content: {
                Text("Two actions")
            } actions: {
                PhiAlertActions(
                    secondaryAction: {
                        PhiAlertButton("Later", action: {})
                    },
                    primaryAction: {
                        PhiAlertButton("Continue", role: .primary, action: {})
                    }
                )
            }
        ).sizeThatFits(
            in: CGSize(width: PhiAlertLayout.width, height: .greatestFiniteMagnitude)
        )
        let threeActions = ThemedHostingController(
            rootView: PhiAlert(title: "Three actions") {
                testIcon
            } content: {
                Text("Three actions")
            } actions: {
                PhiAlertActions(
                    leadingAction: {
                        Button("Custom") {}
                            .buttonStyle(.borderless)
                            .frame(width: 130, height: PhiAlertLayout.actionHeight)
                    },
                    secondaryAction: {
                        PhiAlertButton("Later", action: {})
                    },
                    primaryAction: {
                        PhiAlertButton("Continue", role: .primary, action: {})
                    }
                )
            }
        ).sizeThatFits(
            in: CGSize(width: PhiAlertLayout.width, height: .greatestFiniteMagnitude)
        )

        XCTAssertEqual(twoActions.width, oneAction.width, accuracy: 0.5)
        XCTAssertEqual(threeActions.width, oneAction.width, accuracy: 0.5)
        XCTAssertEqual(twoActions.height, oneAction.height, accuracy: 1)
        XCTAssertEqual(threeActions.height, oneAction.height, accuracy: 1)
    }

    func testPresenterTracksSheetLifecycle() {
        let parentWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        var returnedResponse: NSApplication.ModalResponse?
        let presenter = parentWindow.presentPhiAlert(onDismiss: { response in
            returnedResponse = response
        }) { dismiss in
            makeAlert(message: "Lifecycle") {
                dismiss(.OK)
            }
        }

        XCTAssertTrue(presenter.isPresented)
        XCTAssertNotNil(parentWindow.attachedSheet)

        presenter.dismiss(.OK)

        XCTAssertFalse(presenter.isPresented)
        XCTAssertNil(parentWindow.attachedSheet)
        XCTAssertEqual(returnedResponse, .OK)
    }

    func testNonModalPresentationAttachesThePanelToTheParentWindow() throws {
        let parentWindow = makeParentWindow()

        let presenter = presentNonModalAlert(over: parentWindow)

        XCTAssertTrue(presenter.isPresented)
        let panel = try XCTUnwrap(parentWindow.childWindows?.first)
        XCTAssertTrue(panel.isVisible)

        presenter.dismiss(.cancel)
    }

    func testNonModalPresentationLeavesTheParentWindowUnblocked() {
        let parentWindow = makeParentWindow()

        let presenter = presentNonModalAlert(over: parentWindow)

        XCTAssertNil(parentWindow.attachedSheet)

        presenter.dismiss(.cancel)
    }

    func testNonModalPanelIsCenteredOnTheParentContentArea() throws {
        let parentWindow = makeParentWindow()
        let contentRect = parentWindow.contentRect(
            forFrameRect: parentWindow.frame
        )

        let presenter = presentNonModalAlert(over: parentWindow)

        let panel = try XCTUnwrap(parentWindow.childWindows?.first)
        XCTAssertEqual(panel.frame.midX, contentRect.midX, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, contentRect.midY, accuracy: 1)

        presenter.dismiss(.cancel)
    }

    func testNonModalPanelKeepsTheAlertWidth() throws {
        let parentWindow = makeParentWindow()

        let presenter = presentNonModalAlert(over: parentWindow)

        let panel = try XCTUnwrap(parentWindow.childWindows?.first)
        XCTAssertEqual(panel.frame.width, PhiAlertLayout.width, accuracy: 0.5)

        presenter.dismiss(.cancel)
    }

    func testNonModalDismissalDetachesThePanelAndReturnsTheResponse() {
        let parentWindow = makeParentWindow()
        var returnedResponse: NSApplication.ModalResponse?

        let presenter = presentNonModalAlert(over: parentWindow) {
            returnedResponse = $0
        }
        presenter.dismiss(.OK)

        XCTAssertFalse(presenter.isPresented)
        XCTAssertEqual(returnedResponse, .OK)
        XCTAssertEqual(parentWindow.childWindows?.count ?? 0, 0)
    }

    func testClosingTheParentWindowRunsTheCompletionExactlyOnce() {
        let parentWindow = makeParentWindow()
        var dismissalCount = 0

        let presenter = presentNonModalAlert(over: parentWindow) { _ in
            dismissalCount += 1
        }
        parentWindow.close()

        XCTAssertEqual(dismissalCount, 1)
        XCTAssertFalse(presenter.isPresented)
        XCTAssertEqual(parentWindow.childWindows?.count ?? 0, 0)
    }

    func testBringingToFrontDoesNothingWithoutAPresentedAlert() {
        let parentWindow = makeParentWindow()
        let presenter = presentNonModalAlert(over: parentWindow)
        presenter.dismiss(.cancel)

        presenter.bringToFront()

        XCTAssertFalse(presenter.isPresented)
        XCTAssertEqual(parentWindow.childWindows?.count ?? 0, 0)
    }

    /// Window ordering is asserted through visibility rather than
    /// `NSApp.orderedWindows`, which depends on the test host being the
    /// active application. Hiding the parent hides its panel with it, so a
    /// visible panel afterwards is what recall has to deliver.
    func testBringingToFrontRecallsAPanelHiddenWithItsParentWindow() throws {
        let parentWindow = makeParentWindow()
        let presenter = presentNonModalAlert(over: parentWindow)
        let panel = try XCTUnwrap(parentWindow.childWindows?.first)
        parentWindow.orderOut(nil)
        XCTAssertFalse(panel.isVisible)

        presenter.bringToFront()

        XCTAssertTrue(parentWindow.isVisible)
        XCTAssertTrue(panel.isVisible)

        presenter.dismiss(.cancel)
    }

    func testAppKitConfigurationModelsOneTwoAndThreeActionLayouts() {
        let icon = NSImage(size: NSSize(width: 30, height: 35))
        let leading = PhiAlertAppKitAction(
            "Discard",
            role: .destructive,
            response: .alertThirdButtonReturn
        )
        let secondary = PhiAlertAppKitAction(
            "Cancel",
            response: .alertSecondButtonReturn
        )
        let primary = PhiAlertAppKitAction(
            "Save",
            role: .primary,
            response: .alertFirstButtonReturn
        )
        let oneAction = PhiAlertAppKitConfiguration(
            title: "One",
            message: "Message",
            icon: icon,
            primaryAction: primary
        )
        let twoActions = PhiAlertAppKitConfiguration(
            title: "Two",
            message: "Message",
            icon: icon,
            secondaryAction: secondary,
            primaryAction: primary
        )
        let threeActions = PhiAlertAppKitConfiguration(
            title: "Three",
            message: "Message",
            icon: icon,
            leadingAction: leading,
            secondaryAction: secondary,
            primaryAction: primary
        )

        XCTAssertEqual(oneAction.actions.map(\.title), ["Save"])
        XCTAssertEqual(twoActions.actions.map(\.title), ["Cancel", "Save"])
        XCTAssertEqual(
            threeActions.actions.map(\.title),
            ["Discard", "Cancel", "Save"]
        )
        XCTAssertEqual(oneAction.style, .normal)
        XCTAssertEqual(twoActions.style, .normal)
        XCTAssertEqual(threeActions.style, .normal)
    }

    func testConfigurationStyleControlsConfirmationButtonRole() {
        XCTAssertEqual(
            PhiAlertAppKitConfiguration.Style.normal.confirmationButtonRole,
            .primary
        )
        XCTAssertEqual(
            PhiAlertAppKitConfiguration.Style.critical.confirmationButtonRole,
            .destructive
        )
    }

    func testAppKitBridgePresentsConfiguredAlertAndReturnsResponse() throws {
        let parentWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let primaryResponse = NSApplication.ModalResponse.alertFirstButtonReturn
        let configuration = PhiAlertAppKitConfiguration(
            title: "AppKit alert",
            message: "Presented without constructing SwiftUI content.",
            icon: NSImage(size: NSSize(width: 30, height: 35)),
            maximumHeight: 480,
            primaryAction: PhiAlertAppKitAction(
                "Continue",
                role: .primary,
                response: primaryResponse
            )
        )
        var returnedResponse: NSApplication.ModalResponse?

        let presenter = parentWindow.presentPhiAlert(
            configuration,
            onDismiss: { returnedResponse = $0 }
        )

        XCTAssertTrue(presenter.isPresented)
        let attachedSheet = try XCTUnwrap(parentWindow.attachedSheet)
        XCTAssertEqual(
            attachedSheet.frame.width,
            PhiAlertLayout.width,
            accuracy: 0.5
        )

        presenter.dismiss(primaryResponse)

        XCTAssertFalse(presenter.isPresented)
        XCTAssertEqual(returnedResponse, primaryResponse)
    }

    func testRunModalBridgeUsesSheetAndReturnsResponseSynchronously() {
        let sourceWindow = makeVisibleSourceWindow()
        defer { sourceWindow.close() }
        let expectedResponse = NSApplication.ModalResponse.alertSecondButtonReturn
        let configuration = PhiAlertAppKitConfiguration(
            title: "Synchronous alert",
            message: "The caller should resume with the selected response.",
            icon: NSImage(size: NSSize(width: 30, height: 35)),
            secondaryAction: PhiAlertAppKitAction(
                "Cancel",
                response: expectedResponse
            ),
            primaryAction: PhiAlertAppKitAction(
                "Continue",
                role: .primary,
                response: .alertFirstButtonReturn
            )
        )

        DispatchQueue.main.async {
            guard let sheet = sourceWindow.attachedSheet else {
                XCTFail("Expected PhiAlert to be attached to the source window")
                NSApp.abortModal()
                return
            }
            XCTAssertEqual(
                sheet.frame.width,
                PhiAlertLayout.width,
                accuracy: 0.5
            )
            XCTAssertNil(NSApp.modalWindow)
            sourceWindow.endSheet(sheet, returnCode: expectedResponse)
        }

        let response = NSApp.runPhiAlert(
            configuration,
            relativeTo: sourceWindow
        )

        XCTAssertEqual(response, expectedResponse)
        XCTAssertNil(sourceWindow.attachedSheet)
        XCTAssertNil(NSApp.modalWindow)
    }

    func testSynchronousSheetDispatchesAppKitEvents() {
        let sourceWindow = makeVisibleSourceWindow()
        defer { sourceWindow.close() }
        let expectedResponse = NSApplication.ModalResponse.alertFirstButtonReturn
        var dismissHandler: ((NSApplication.ModalResponse) -> Void)?
        var didDispatchEvent = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in
            didDispatchEvent = true
            dismissHandler?(expectedResponse)
            return nil
        }
        defer {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sourceWindow.windowNumber,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        )
        if let event {
            NSApp.postEvent(event, atStart: false)
        } else {
            XCTFail("Expected to create an AppKit key event")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !didDispatchEvent else { return }
            dismissHandler?(.cancel)
        }

        let response = NSApp.runPhiAlert(relativeTo: sourceWindow) { dismiss in
            makeAppKitEventDismissAlert(
                dismiss: dismiss,
                installDismissHandler: { dismissHandler = $0 }
            )
        }

        XCTAssertTrue(didDispatchEvent)
        XCTAssertEqual(response, expectedResponse)
        XCTAssertNil(sourceWindow.attachedSheet)
        XCTAssertNil(NSApp.modalWindow)
    }

    func testEscapeReturnsSecondaryActionResponse() {
        let expectedResponse = NSApplication.ModalResponse.alertSecondButtonReturn
        let response = runKeyboardShortcutAlert(
            characters: "\u{1B}",
            keyCode: 53
        )

        XCTAssertEqual(response, expectedResponse)
    }

    func testReturnReturnsPrimaryActionResponse() {
        let expectedResponse = NSApplication.ModalResponse.alertFirstButtonReturn
        let response = runKeyboardShortcutAlert(
            characters: "\r",
            keyCode: 36
        )

        XCTAssertEqual(response, expectedResponse)
    }

    func testReturnConfirmsNothingWithoutADefaultButton() {
        // `.cancel` is how the harness ends a sheet nothing dismissed, so it
        // says Return was ignored rather than answered by some other button.
        let response = runKeyboardShortcutAlert(
            characters: "\r",
            keyCode: 36,
            runAlert: { sourceWindow in
                NSApp.runPhiAlert(
                    self.irreversibleConfirmation,
                    relativeTo: sourceWindow
                )
            }
        )

        XCTAssertEqual(response, .cancel)
    }

    func testEscapeStillCancelsWithoutADefaultButton() {
        let response = runKeyboardShortcutAlert(
            characters: "\u{1B}",
            keyCode: 53,
            runAlert: { sourceWindow in
                NSApp.runPhiAlert(
                    self.irreversibleConfirmation,
                    relativeTo: sourceWindow
                )
            }
        )

        XCTAssertEqual(response, .alertSecondButtonReturn)
    }

    func testCommandQConfirmsQuitAlert() {
        let expectedResponse = NSApplication.ModalResponse.alertFirstButtonReturn
        let response = runKeyboardShortcutAlert(
            characters: "q",
            modifierFlags: .command,
            keyCode: 12,
            runAlert: { sourceWindow in
                PhiAlert.runQuitAlert(relativeTo: sourceWindow)
                    ? .alertFirstButtonReturn
                    : .cancel
            }
        )

        XCTAssertEqual(response, expectedResponse)
    }

    /// The synchronous bridge hosts a sheet only on a visible window and
    /// floats a standalone panel otherwise, so a sheet test has to put its
    /// source window on screen first.
    private func makeVisibleSourceWindow() -> NSWindow {
        let window = makeParentWindow()
        window.orderFront(nil)
        return window
    }

    private func makeParentWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // These tests close the window themselves, so ARC keeps ownership.
        window.isReleasedWhenClosed = false
        return window
    }

    @discardableResult
    private func presentNonModalAlert(
        over parentWindow: NSWindow,
        onDismiss: ((NSApplication.ModalResponse) -> Void)? = nil
    ) -> PhiAlertPresenter {
        parentWindow.presentPhiAlertNonModally(onDismiss: onDismiss) { dismiss in
            makeAlert(message: "Non-modal") {
                dismiss(.OK)
            }
        }
    }

    private func makeHostingController(
        message: String,
        maximumHeight: CGFloat
    ) -> NSHostingController<AnyView> {
        let hostingController = ThemedHostingController(
            rootView: makeAlert(
                message: message,
                maximumHeight: maximumHeight,
                action: {}
            )
        )
        return hostingController
    }

    private func runKeyboardShortcutAlert(
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = [],
        keyCode: UInt16,
        runAlert: ((NSWindow) -> NSApplication.ModalResponse)? = nil
    ) -> NSApplication.ModalResponse {
        let sourceWindow = makeVisibleSourceWindow()
        defer { sourceWindow.close() }
        let configuration = PhiAlertAppKitConfiguration(
            title: "Keyboard shortcut",
            message: "The alert should handle its standard keyboard shortcuts.",
            secondaryAction: PhiAlertAppKitAction(
                "Cancel",
                response: .alertSecondButtonReturn
            ),
            primaryAction: PhiAlertAppKitAction(
                "Confirm",
                role: .primary,
                response: .alertFirstButtonReturn
            )
        )

        RunLoop.current.perform(inModes: [.eventTracking]) {
            guard let sheet = sourceWindow.attachedSheet else {
                XCTFail("Expected PhiAlert to be attached before posting the key event")
                return
            }
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ) else {
                XCTFail("Expected to create an AppKit key event")
                return
            }
            NSApp.postEvent(event, atStart: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let sheet = sourceWindow.attachedSheet else { return }
            sourceWindow.endSheet(sheet, returnCode: .cancel)
        }

        if let runAlert {
            return runAlert(sourceWindow)
        }

        return NSApp.runPhiAlert(configuration, relativeTo: sourceWindow)
    }

    /// A destructive confirmation that keeps the Return key off every button.
    private var irreversibleConfirmation: PhiAlertAppKitConfiguration {
        PhiAlertAppKitConfiguration(
            title: "Irreversible confirmation",
            message: "Return must not confirm what cannot be undone.",
            style: .critical,
            defaultButton: .noButton,
            secondaryAction: PhiAlertAppKitAction(
                "Cancel",
                response: .alertSecondButtonReturn
            ),
            primaryAction: PhiAlertAppKitAction(
                "Delete",
                response: .alertFirstButtonReturn
            )
        )
    }

    private var testIcon: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .resizable()
            .scaledToFit()
    }

    private func makeAlert(
        message: String,
        maximumHeight: CGFloat = PhiAlertLayout.defaultMaximumHeight,
        action: @escaping () -> Void
    ) -> some View {
        PhiAlert(
            title: "Are you sure you want to quit Phi?",
            maximumHeight: maximumHeight
        ) {
            testIcon
        } content: {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            PhiAlertActions {
                PhiAlertButton("Continue", role: .primary, action: action)
            }
        }
    }

    private func makeAppKitEventDismissAlert(
        dismiss: PhiAlertDismissAction,
        installDismissHandler: (
            @escaping (NSApplication.ModalResponse) -> Void
        ) -> Void
    ) -> some View {
        installDismissHandler { response in
            dismiss(response)
        }

        return makeAlert(
            message: "Dismissed after dispatching an AppKit event.",
            action: {}
        )
    }
}
