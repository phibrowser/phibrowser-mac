// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// Keeps a Space instance's content surface (chromium ADR 0014) told the
/// corner radii and stacking order of every web view in its hosting
/// container, as views tells `NativeViewHostMac` upstream.
///
/// It reconciles once per run-loop pass, as `TrafficLightPositioner` does
/// with the traffic lights. Mounting a web view, restacking a tab's view, a
/// layout pass, docking DevTools and opening the AI Chat panel can each
/// change what the surface has to be told, and a web view the surface
/// attaches again starts out square and at the bottom; looking at the
/// laid-out tree after AppKit's pass covers every such path. A pass with
/// nothing new sends nothing, since each send makes Chromium draw a frame.
@MainActor
final class ContentSurfaceHosting {
    /// What one web view's host is told: the radii of its four on-screen
    /// corners and its stacking order among the web views of the container.
    private struct Hosting: Equatable {
        var topLeft: CGFloat = 0
        var topRight: CGFloat = 0
        var bottomRight: CGFloat = 0
        var bottomLeft: CGFloat = 0
        var zOrder = 0
    }

    private struct Sent {
        weak var address: NSObject?
        var hosting: Hosting
    }

    private weak var container: NSView?
    private weak var browserState: BrowserState?
    private var observer: CFRunLoopObserver?
    /// Last `Hosting` sent, keyed by address.
    private var sent: [ObjectIdentifier: Sent] = [:]

    /// After AppKit's flush observer, so the views are laid out.
    private static let observerOrder = CFIndex.max

    init(container: NSView, browserState: BrowserState?) {
        self.container = container
        self.browserState = browserState
        let observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
            true,
            Self.observerOrder
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.update()
            }
        }
        self.observer = observer
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    deinit {
        if let observer {
            CFRunLoopObserverInvalidate(observer)
        }
    }

    /// The stacking order is the web views' back-to-front order below the
    /// container, so a tab waiting for its first paint under the current one
    /// stays under it until promoted, and docked DevTools, mounted below its
    /// page, stays above the web views of any tab mounted under the current
    /// one.
    private func update() {
        guard let container, let browserState,
              let bridge = ChromiumLauncher.sharedInstance().bridge,
              let window = container.window,
              !container.isHiddenOrHasHiddenAncestor else {
            // A web view attached again meanwhile has lost what it was told.
            sent.removeAll()
            return
        }
        let tabs = browserState.tabs + browserState.aiChatTabs.values
        var wrappers = tabs.compactMap(\.webContentWrapper)
        if let placeholder = browserState.placeholderWrapper {
            wrappers.append(placeholder)
        }
        // A web view is addressed by its wrapper. Docked DevTools has none and
        // is addressed by its web view, the view Chromium handed over.
        var addresses = wrappers.map { (address: $0 as NSObject, webView: $0.nativeView) }
        addresses += tabs.compactMap(\.devToolsView)
            .map { (address: $0 as NSObject, webView: Optional($0)) }
        var seen = Set<ObjectIdentifier>()
        let mounted = addresses
            .compactMap { item -> (address: NSObject, webView: NSView, path: [Int])? in
                guard seen.insert(ObjectIdentifier(item.address)).inserted,
                      let webView = item.webView, webView.window === window,
                      let path = Self.indexPath(of: webView, below: container) else { return nil }
                return (item.address, webView, path)
            }
            .sorted { $0.path.lexicographicallyPrecedes($1.path) }

        var nowSent: [ObjectIdentifier: Sent] = [:]
        for (zOrder, item) in mounted.enumerated() {
            let hosting = Self.hosting(of: item.webView, zOrder: zOrder, below: container)
            let key = ObjectIdentifier(item.address)
            if sent[key]?.address !== item.address || sent[key]?.hosting != hosting {
                if let wrapper = item.address as? WebContentWrapper {
                    bridge.setContentHosting?(wrapper,
                                              topLeftRadius: hosting.topLeft,
                                              topRightRadius: hosting.topRight,
                                              bottomRightRadius: hosting.bottomRight,
                                              bottomLeftRadius: hosting.bottomLeft,
                                              zOrder: hosting.zOrder)
                } else {
                    bridge.setContentHosting?(forWebView: item.webView,
                                              topLeftRadius: hosting.topLeft,
                                              topRightRadius: hosting.topRight,
                                              bottomRightRadius: hosting.bottomRight,
                                              bottomLeftRadius: hosting.bottomLeft,
                                              zOrder: hosting.zOrder)
                }
            }
            nowSent[key] = Sent(address: item.address, hosting: hosting)
        }
        sent = nowSent
    }

    /// Subview indices from `container` down to `view`, or nil when `view` is
    /// not below it. Ordered lexicographically, these give the back-to-front
    /// order in which AppKit draws the views.
    private static func indexPath(of view: NSView, below container: NSView) -> [Int]? {
        var path: [Int] = []
        var child = view
        while let parent = child.superview {
            guard let index = parent.subviews.firstIndex(of: child) else { return nil }
            path.append(index)
            if parent === container {
                return path.reversed()
            }
            child = parent
        }
        return nil
    }

    /// The radii AppKit gives `webView`'s corners: at each corner, the largest
    /// corner radius among its clipping ancestors below `container` whose own
    /// corner it reaches. A corner that reaches none stays square: one next to
    /// docked DevTools, the top of a page under the address bar.
    private static func hosting(of webView: NSView, zOrder: Int, below container: NSView) -> Hosting {
        var hosting = Hosting(zOrder: zOrder)
        var ancestor = webView.superview
        while let clip = ancestor, clip !== container {
            ancestor = clip.superview
            guard let layer = clip.layer, layer.masksToBounds, layer.cornerRadius > 0 else {
                continue
            }
            let rect = clip.convert(webView.bounds, from: webView)
            let bounds = clip.bounds
            let atMinX = abs(rect.minX - bounds.minX) < 0.5
            let atMaxX = abs(rect.maxX - bounds.maxX) < 0.5
            let atMinY = abs(rect.minY - bounds.minY) < 0.5
            let atMaxY = abs(rect.maxY - bounds.maxY) < 0.5
            func radius(_ reaches: Bool, _ corner: CACornerMask) -> CGFloat {
                reaches && layer.maskedCorners.contains(corner) ? layer.cornerRadius : 0
            }
            let minXMinY = radius(atMinX && atMinY, .layerMinXMinYCorner)
            let maxXMinY = radius(atMaxX && atMinY, .layerMaxXMinYCorner)
            let minXMaxY = radius(atMinX && atMaxY, .layerMinXMaxYCorner)
            let maxXMaxY = radius(atMaxX && atMaxY, .layerMaxXMaxYCorner)
            // A layer's corners follow its view's coordinates (AppKit flips a
            // flipped view's layer), so minY is the top only when flipped.
            let flipped = clip.isFlipped
            hosting.topLeft = max(hosting.topLeft, flipped ? minXMinY : minXMaxY)
            hosting.topRight = max(hosting.topRight, flipped ? maxXMinY : maxXMaxY)
            hosting.bottomLeft = max(hosting.bottomLeft, flipped ? minXMaxY : minXMinY)
            hosting.bottomRight = max(hosting.bottomRight, flipped ? maxXMaxY : maxXMinY)
        }
        return hosting
    }
}
