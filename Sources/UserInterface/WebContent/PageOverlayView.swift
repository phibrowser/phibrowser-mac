// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SnapKit

/// Reader and Peek share the browser's window and responder chain. Their
/// unflipped roots keep screen-space geometry and Peek's animation aligned.
class PageOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.zPosition = WebContentContainerViewController.LayerZIndex.pageOverlay
        layer?.masksToBounds = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isPresented: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// Stacking among page overlays: a higher rank always sits above a lower
    /// one, however often either is re-installed. Reader (1) can cover a
    /// peek's card, so it must stay above Peek (0).
    var stackingRank: Int { 0 }

    var screenFrame: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    func setScreenFrame(_ rect: NSRect) {
        guard let window, let superview else { return }
        frame = superview.convert(window.convertFromScreen(rect), from: nil)
        layoutSubtreeIfNeeded()
    }

    override func removeFromSuperview() {
        // Do not leave keyboard input targeting a detached Chromium view.
        if containsFirstResponder { window?.makeFirstResponder(nil) }
        isHidden = true
        super.removeFromSuperview()
    }
}

extension WebContentContainerViewController {
    func installPageOverlay(_ overlay: PageOverlayView) {
        // AppKit hit testing follows subview order, independently of layer z.
        // The floating sidebar is mounted above this whole page tree.
        if let higher = view.subviews.first(where: {
            $0 !== overlay && (($0 as? PageOverlayView)?.stackingRank ?? .min) > overlay.stackingRank
        }) {
            view.addSubview(overlay, positioned: .below, relativeTo: higher)
            return
        }
        view.addSubview(overlay, positioned: .above, relativeTo: nil)
    }
}

/// Docked DevTools for a tab hosted by a page overlay (Peek, Reader) instead
/// of a `WebContentViewController`. Same model as that controller's
/// single-content path: DevTools fills the host below the page, and the page
/// takes the frame DevTools JS reports. The state lives on the `Tab`, so an
/// overlay re-mounts it when it re-hosts the tab, and "Open as Tab" hands it
/// to `WebContentViewController.restoreDevToolsState` unchanged.
///
/// `host` is the overlay view the tab's page is mounted in, or nil while the
/// overlay is not hosting the tab (panel hidden behind another opener) — the
/// state is then only recorded, for `mount` to apply later.
enum PageOverlayDevToolsDock {
    static func attach(_ devToolsView: NSView, to tab: Tab, in host: NSView?) {
        // Right-click "Inspect" with DevTools already open re-sends the
        // attach for the same view; keep the cached bounds — Chromium won't
        // resend them unchanged.
        if !(tab.devToolsAttached && tab.devToolsView === devToolsView) {
            if tab.devToolsAttached, let stale = tab.devToolsView {
                stale.removeFromSuperview()
            }
            tab.devToolsAttached = true
            tab.devToolsView = devToolsView
            tab.inspectedPageBounds = nil
            tab.hideInspectedContents = false
        }
        if let host { mount(tab, in: host) }
    }

    static func detach(_ tab: Tab, in host: NSView?) {
        tab.devToolsView?.removeFromSuperview()
        tab.devToolsAttached = false
        tab.devToolsView = nil
        tab.inspectedPageBounds = nil
        tab.hideInspectedContents = false
        guard let host, let webView = tab.webContentView,
              webView.superview === host else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = false
        webView.snp.remakeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    static func updateInspectedPageBounds(_ bounds: CGRect, hide: Bool,
                                          for tab: Tab, in host: NSView?) {
        tab.inspectedPageBounds = bounds
        tab.hideInspectedContents = hide
        guard let host, tab.devToolsView?.superview === host else { return }
        layoutPage(of: tab, in: host)
    }

    /// Re-applies a tab's recorded DevTools state after its page was mounted
    /// in `host`. No-op for a tab without docked DevTools.
    static func mount(_ tab: Tab, in host: NSView) {
        guard tab.devToolsAttached, let devToolsView = tab.devToolsView,
              let webView = tab.webContentView, webView.superview === host else { return }
        if devToolsView.superview !== host {
            devToolsView.wantsLayer = true
            host.addSubview(devToolsView, positioned: .below, relativeTo: webView)
        }
        devToolsView.frame = host.bounds
        devToolsView.autoresizingMask = [.width, .height]
        // Manual frame from here on; a leftover mask would translate into
        // fill-superview constraints fighting it (see attachDevTools).
        webView.snp.removeConstraints()
        webView.autoresizingMask = []
        webView.translatesAutoresizingMaskIntoConstraints = true
        layoutPage(of: tab, in: host)
    }

    /// Whether keyboard focus is inside the tab's docked DevTools, whose own
    /// shortcuts (Esc, Cmd-[ / Cmd-]) the overlay must not claim.
    static func hasFocus(_ tab: Tab?) -> Bool {
        guard let devToolsView = tab?.devToolsView,
              let responder = devToolsView.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: devToolsView)
    }

    private static func layoutPage(of tab: Tab, in host: NSView) {
        guard let webView = tab.webContentView, webView.superview === host else { return }
        guard let bounds = tab.inspectedPageBounds else {
            // Until DevTools reports its first bounds the page covers it.
            webView.isHidden = false
            webView.frame = host.bounds
            return
        }
        webView.isHidden = tab.hideInspectedContents
        guard !tab.hideInspectedContents else { return }
        // Web coordinates (origin top-left) to the unflipped host.
        webView.frame = NSRect(x: bounds.origin.x,
                               y: host.bounds.height - bounds.origin.y - bounds.size.height,
                               width: bounds.size.width,
                               height: bounds.size.height)
    }
}

/// Vibrancy suppression for the views a page overlay hosts its tab in (the
/// page, docked DevTools). Chromium's web views allow vibrancy, so under the
/// window's visual-effect views AppKit composites them with its Plus Lighter
/// filter, which adds the overlay's backing onto every pixel and washes a
/// dark page and its images out. The host view forwards its subview changes
/// here, and each hosted view has the filter stripped as `WebContentHostView`
/// does for a tab's page; that view itself is not reused because its frame
/// sync would undo the page frame `PageOverlayDevToolsDock` lays out.
final class PageOverlayVibrancySuppressor {
    private var filterObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]

    deinit {
        filterObservers.values.forEach { $0.invalidate() }
    }

    func didAddSubview(_ subview: NSView) {
        let key = ObjectIdentifier(subview)
        guard filterObservers[key] == nil else { return }
        subview.wantsLayer = true
        guard let layer = subview.layer else { return }
        filterObservers[key] = WebContentHostView.observeVibrancyFilter(on: layer)
    }

    func willRemoveSubview(_ subview: NSView) {
        filterObservers.removeValue(forKey: ObjectIdentifier(subview))?.invalidate()
    }
}
