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
                    .controller(for: windowId) else {
                return "{\"ok\":false,\"error\":\"no_window\"}"
            }
            let webImage = webPath.flatMap { NSImage(contentsOfFile: $0) }
            guard let rep = renderWindow(of: controller, webImage: webImage) else {
                return "{\"ok\":false,\"error\":\"capture_failed\"}"
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

    /// The window as the user would see it, with `webImage` — the page the
    /// caller captured over CDP — drawn over the page panel.
    ///
    /// Legacy mode: the window's content view. Hosted mode: the presented
    /// session is the shell's content view; a background session — the
    /// usual agent Space — is composed from its own trees laid out the way
    /// the shell shows a Space: its sidebar content in the shell's sidebar
    /// column and its page tree in the page area. Those trees stay resident
    /// in the shell, laid out but hidden, and a hidden view draws nothing
    /// into a bitmap while its unhidden children do — so a hidden tree is
    /// drawn child by child, each where it sits.
    static func renderWindow(of controller: SpaceSessionController,
                             webImage: NSImage?) -> NSBitmapImageRep? {
        guard let canvas = controller.window?.contentView else { return nil }
        let split = controller.mainSplitViewController
        let panel = split.isViewLoaded ? split.webContentContainerViewController.view : nil
        guard controller.isHosted else {
            return render(canvas: canvas, trees: [(canvas, canvas.bounds)],
                          panel: panel.map { ($0, $0.convert($0.bounds, to: canvas)) },
                          webImage: webImage)
        }
        if controller.isPresented {
            return render(canvas: canvas, trees: [(canvas, canvas.bounds)],
                          panel: panel.map { ($0, $0.convert($0.bounds, to: canvas)) },
                          webImage: webImage)
        }
        guard split.isViewLoaded, let shell = controller.shellSplit else { return nil }
        let pageArea = shell.contentHost.view.convert(shell.contentHost.view.bounds, to: canvas)
        let column = shell.sidebarHost.view.convert(shell.sidebarHost.view.bounds, to: canvas)
        let page = split.view
        // AppKit can defer autoresizing for hidden trees; a tree never shown
        // in the shell has no frame at all (see
        // `ShellContentHostViewController.install`).
        if page.frame.size != pageArea.size {
            page.frame = NSRect(origin: page.frame.origin, size: pageArea.size)
        }
        page.layoutSubtreeIfNeeded()
        let sidebar = split.sidebarViewController.view
        sidebar.layoutSubtreeIfNeeded()
        var trees: [(NSView, NSRect)] = []
        if !shell.isSidebarCollapsed, column.width >= 1 {
            trees.append((sidebar, column))
        }
        trees.append((page, pageArea))
        let panelRect = panel.map { placement(of: $0, in: canvas, tree: page, treeRect: pageArea) }
        return render(canvas: canvas, backdrop: shell.contentHost.backdrop.presentedFillColor,
                      trees: trees,
                      panel: panel.flatMap { p in panelRect.map { (p, $0) } },
                      webImage: webImage)
    }

    /// Draws the `trees` — each at its rect in `canvas` coordinates — over
    /// `backdrop`, then `webImage` over `panel`.
    private static func render(canvas: NSView, backdrop: CGColor? = nil,
                               trees: [(NSView, NSRect)],
                               panel: (NSView, NSRect)?,
                               webImage: NSImage?) -> NSBitmapImageRep? {
        let bounds = canvas.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = canvas.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        if trees.contains(where: { $0.0 === canvas }) {
            canvas.cacheDisplay(in: bounds, to: rep)
        }
        guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let backdrop, let color = NSColor(cgColor: backdrop) {
            color.setFill()
            bounds.fill()
        }
        for (tree, rect) in trees where tree !== canvas {
            draw(tree, at: rect, in: canvas)
        }
        // Draw the CDP-captured web content over its (blank) panel region.
        if let webImage, let panel {
            let panelRect = panel.1
            // Back the page with white first: a CDP capture is transparent
            // where the page paints no background, and a real browser shows
            // white there, not the chrome behind it.
            NSColor.white.setFill()
            panelRect.fill()
            webImage.draw(in: panelRect, from: .zero,
                          operation: .sourceOver, fraction: 1.0)
        }
        return rep
    }

    /// Draws `tree` at `rect`; a hidden tree contributes its unhidden
    /// children, each where it sits within `rect`.
    private static func draw(_ tree: NSView, at rect: NSRect, in canvas: NSView) {
        guard tree.isHidden else {
            drawView(tree, at: rect)
            return
        }
        for child in tree.subviews where !child.isHidden {
            drawView(child, at: placement(of: child, in: canvas, tree: tree, treeRect: rect))
        }
    }

    private static func drawView(_ view: NSView, at rect: NSRect) {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
                 respectFlipped: true, hints: nil)
    }

    /// Where `view` — a descendant of `tree`, drawn at `treeRect` — lands in
    /// `canvas`: through the window when both share it, else by offset.
    private static func placement(of view: NSView, in canvas: NSView,
                                  tree: NSView, treeRect: NSRect) -> NSRect {
        if let window = view.window, window === canvas.window {
            return view.convert(view.bounds, to: canvas)
        }
        let frame = tree.convert(view.bounds, from: view)
        let y = tree.isFlipped ? treeRect.maxY - frame.maxY : treeRect.minY + frame.minY
        return NSRect(x: treeRect.minX + frame.minX, y: y,
                      width: frame.width, height: frame.height)
    }
}
