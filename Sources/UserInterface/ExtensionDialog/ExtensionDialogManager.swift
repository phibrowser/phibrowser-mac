// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Foundation

// MARK: - Request Model

struct ExtensionDialogRequest {
    let sessionId: String
    let windowId: Int
    let html: String
    let title: String?
    let width: CGFloat?
    let height: CGFloat?
}

extension ExtensionDialogRequest: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sessionId, windowId, content
    }

    private struct Content: Decodable {
        let html: String
        let title: String?
        let width: CGFloat?
        let height: CGFloat?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        windowId = try container.decode(Int.self, forKey: .windowId)
        let content = try container.decode(Content.self, forKey: .content)
        html = content.html
        title = content.title
        width = content.width
        height = content.height
    }
}

// MARK: - Delegate

protocol ExtensionDialogViewControllerDelegate: AnyObject {
    func dialogViewController(_ vc: ExtensionDialogViewController, didPostMessage data: String)
    func dialogViewControllerDidClose(_ vc: ExtensionDialogViewController)
    func dialogViewController(_ vc: ExtensionDialogViewController, contentSizeMeasured size: NSSize)
}

// MARK: - Manager

final class ExtensionDialogManager {
    static let shared = ExtensionDialogManager()

    private static let defaultWidth: CGFloat = 480
    private static let defaultHeight: CGFloat = 360

    private let messenger: ExtensionMessagingProtocol
    private let windowLookup: MainBrowserWindowLookup
    private var activeWindows: [String: NSWindow] = [:]
    private var activeVCs: [String: ExtensionDialogViewController] = [:]
    private var parentWindows: [String: NSWindow] = [:]
    private var autoSizeSessions: Set<String> = []
    /// The Browser window each dialog belongs to.
    private var sessionWindowIds: [String: Int] = [:]
    /// Dialogs built but not attached, because their Space is not the one
    /// its shell presents (hosted mode). A sheet on the shell would block the
    /// Space on screen for a dialog that belongs to another.
    private var deferredSessions: Set<String> = []
    private var visibleWindowObserver: NSObjectProtocol?

    init(messenger: ExtensionMessagingProtocol = ExtensionMessaging.shared,
         windowLookup: MainBrowserWindowLookup = SpaceSessionControllersManager.shared) {
        self.messenger = messenger
        self.windowLookup = windowLookup
        visibleWindowObserver = NotificationCenter.default.addObserver(
            forName: .spaceSlotVisibleWindowDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileSheetsWithPresentedSpaces()
            }
        }
    }

    func handleRequest(context: ExtensionMessageContext) {
        guard let data = context.payload.data(using: .utf8) else {
            AppLogWarn("[ExtDialog] Invalid payload encoding")
            return
        }

        do {
            let request = try JSONDecoder().decode(ExtensionDialogRequest.self, from: data)

            Task { @MainActor in
                self.presentDialog(request: request, requestId: context.requestId)
            }
        } catch {
            AppLogWarn("[ExtDialog] Failed to decode request: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func presentDialog(request: ExtensionDialogRequest, requestId: String) {
        dismissDialog(sessionId: request.sessionId)

        guard let windowController = windowLookup.controller(for: request.windowId),
              windowController.window != nil else {
            AppLogWarn("[ExtDialog] Window not found for id: \(request.windowId)")
            return
        }

        let needsAutoSize = request.width == nil || request.height == nil
        let width = request.width ?? Self.defaultWidth
        let height = request.height ?? Self.defaultHeight
        let contentSize = NSSize(width: width, height: height)

        let vc = ExtensionDialogViewController(
            html: request.html,
            sessionId: request.sessionId,
            size: contentSize,
            measureContentSize: needsAutoSize
        )
        vc.delegate = self
        activeVCs[request.sessionId] = vc
        sessionWindowIds[request.sessionId] = request.windowId

        if needsAutoSize {
            autoSizeSessions.insert(request.sessionId)
            vc.loadContent()
        } else {
            let window = makeDialogWindow(contentSize: contentSize, vc: vc)
            activeWindows[request.sessionId] = window
            vc.loadContent()
            attachSheet(sessionId: request.sessionId)
        }
    }

    @MainActor
    private func showSheet(sessionId: String, contentSize: NSSize) {
        guard let vc = activeVCs[sessionId],
              sessionWindowIds[sessionId] != nil else { return }

        let window = makeDialogWindow(contentSize: contentSize, vc: vc)
        activeWindows[sessionId] = window
        attachSheet(sessionId: sessionId)
    }

    /// Attaches the dialog as a sheet of its Browser's window — the shell, in
    /// hosted mode — or defers it while that Space is not the one on screen.
    @MainActor
    private func attachSheet(sessionId: String) {
        guard let window = activeWindows[sessionId],
              let windowId = sessionWindowIds[sessionId],
              let controller = windowLookup.controller(for: windowId),
              let parentWindow = controller.window else { return }
        guard controller.isPresentedOrLegacy else {
            deferredSessions.insert(sessionId)
            return
        }
        deferredSessions.remove(sessionId)
        parentWindows[sessionId] = parentWindow
        parentWindow.beginSheet(window)
    }

    /// Hosted mode: a dialog follows its Space in and out of the shell —
    /// detached while another Space is on screen, re-attached when its own
    /// is presented again.
    @MainActor
    private func reconcileSheetsWithPresentedSpaces() {
        for (sessionId, window) in activeWindows {
            guard let windowId = sessionWindowIds[sessionId],
                  let controller = windowLookup.controller(for: windowId) else { continue }
            if deferredSessions.contains(sessionId) {
                if controller.isPresentedOrLegacy {
                    attachSheet(sessionId: sessionId)
                }
            } else if !controller.isPresentedOrLegacy,
                      let parent = parentWindows.removeValue(forKey: sessionId) {
                parent.endSheet(window)
                deferredSessions.insert(sessionId)
            }
        }
    }

    private func makeDialogWindow(contentSize: NSSize, vc: ExtensionDialogViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = vc
        window.animationBehavior = .alertPanel
        return window
    }

    private func dismissDialog(sessionId: String) {
        autoSizeSessions.remove(sessionId)
        activeVCs.removeValue(forKey: sessionId)
        sessionWindowIds.removeValue(forKey: sessionId)
        deferredSessions.remove(sessionId)
        guard let window = activeWindows.removeValue(forKey: sessionId) else {
            parentWindows.removeValue(forKey: sessionId)
            return
        }
        if let parent = parentWindows.removeValue(forKey: sessionId) {
            parent.endSheet(window)
        }
    }

    // MARK: - Broadcast

    private func broadcastClose(sessionId: String) {
        let payload: [String: Any] = ["sessionId": sessionId, "type": "close"]
        broadcastPayload(payload)
    }

    private func broadcastSubmit(sessionId: String, rawData: String) {
        var payload: [String: Any] = ["sessionId": sessionId]
        if let jsonData = rawData.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: jsonData) {
            payload["data"] = parsed
        } else {
            payload["data"] = rawData
        }
        broadcastPayload(payload)
    }

    private func broadcastPayload(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            AppLogWarn("[ExtDialog] Failed to serialize broadcast payload")
            return
        }
        messenger.broadcast(type: "showDialog", payload: json)
    }
}

// MARK: - ExtensionDialogViewControllerDelegate

extension ExtensionDialogManager: @MainActor ExtensionDialogViewControllerDelegate {
    func dialogViewController(_ vc: ExtensionDialogViewController, didPostMessage data: String) {
        broadcastSubmit(sessionId: vc.sessionId, rawData: data)
    }

    func dialogViewControllerDidClose(_ vc: ExtensionDialogViewController) {
        let sessionId = vc.sessionId
        broadcastClose(sessionId: sessionId)
        dismissDialog(sessionId: sessionId)
    }

    @MainActor
    func dialogViewController(_ vc: ExtensionDialogViewController, contentSizeMeasured size: NSSize) {
        let sessionId = vc.sessionId
        guard autoSizeSessions.remove(sessionId) != nil else { return }

        let maxWidth: CGFloat = 800
        let maxHeight: CGFloat = 600
        let minWidth: CGFloat = 200
        let minHeight: CGFloat = 100

        let clampedSize = NSSize(
            width: min(max(size.width, minWidth), maxWidth),
            height: min(max(size.height, minHeight), maxHeight)
        )
        vc.preferredContentSize = clampedSize
        showSheet(sessionId: sessionId, contentSize: clampedSize)
    }
}

