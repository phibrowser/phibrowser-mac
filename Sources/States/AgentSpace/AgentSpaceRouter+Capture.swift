// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

extension AgentSpaceRouter {
    /// `agentSpace.captureWindow` — render the agent Space's whole browser
    /// window (native AppKit chrome + web content) to a PNG.
    ///
    /// The hidden agent window is ordered out, so the WindowServer can't capture
    /// it (`CGWindowListCreateImage` needs a visible window) and its GPU web
    /// surface stays blank under `cacheDisplay`. So the caller supplies the web
    /// content it already captured over CDP — which Chromium renders regardless
    /// of window visibility — at `webPath`, and this composites it onto the
    /// chrome. `outPath` receives the PNG; the path is echoed back on success.
    /// Passive with respect to user/agent ownership, but still restricted to
    /// the task's owning driver principal.
    static func handleCaptureWindow(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String,
              let outPath = obj["outPath"] as? String, !outPath.isEmpty else {
            return invalid()
        }
        let webPath = obj["webPath"] as? String
        guard callerMayControl(taskId: taskId, context: context,
                               touchKeepAlive: false) else {
            return unknownTask()
        }

        return MainActor.assumeIsolated {
            guard let windowId = AgentSpaceManager.shared.task(forTaskId: taskId)?.windowId,
                  windowId != 0 else {
                return unknownTask()
            }
            guard let controller = SpaceSessionControllersManager.shared
                    .controller(for: windowId),
                  let contentView = controller.window?.contentView else {
                return "{\"ok\":false,\"error\":\"no_window\"}"
            }

            let bounds = contentView.bounds
            guard bounds.width > 1, bounds.height > 1,
                  let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                return "{\"ok\":false,\"error\":\"capture_failed\"}"
            }
            contentView.cacheDisplay(in: bounds, to: rep)

            // Draw the CDP-captured web content over its (blank) panel region.
            if let webPath, let webImage = NSImage(contentsOfFile: webPath),
               let gctx = NSGraphicsContext(bitmapImageRep: rep) {
                let panel = controller.mainSplitViewController
                    .webContentContainerViewController.view
                let panelRect = panel.convert(panel.bounds, to: contentView)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = gctx
                // Back the page with white first: a CDP capture is transparent
                // where the page paints no background, and a real browser shows
                // white there, not the chrome behind it.
                NSColor.white.setFill()
                panelRect.fill()
                webImage.draw(in: panelRect, from: .zero,
                              operation: .sourceOver, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
            }

            guard let png = rep.representation(using: .png, properties: [:]) else {
                return "{\"ok\":false,\"error\":\"encode_failed\"}"
            }
            do {
                try png.write(to: URL(fileURLWithPath: outPath))
            } catch {
                return "{\"ok\":false,\"error\":\"write_failed\"}"
            }
            let escaped = outPath
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"ok\":true,\"path\":\"\(escaped)\"}"
        }
    }
}
