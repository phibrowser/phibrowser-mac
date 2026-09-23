// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

extension WebContentContainerViewController {
    /// Hosted sessions resolve the shell's panel, even when their own page
    /// tree is dormant or detached. Standalone windows have their own host.
    var floatingSidebarHost: FloatingSidebarHostViewController {
        browserState?.windowController?.shellSplit?.floatingSidebarHost ?? standaloneFloatingSidebarHost
    }

    var floatingSidebarContainerView: NSView? { floatingSidebarHost.floatingSidebarContainerView }
    var floatingSidebarViewController: FloatingSidebarViewController? { floatingSidebarHost.floatingSidebarViewController }

    func setupFloatingSidebar() {
        // A prewarmed hosted tree has no window controller yet. Its parent
        // already knows that the eventual shell owns the floating panel.
        guard (parent as? MainSplitViewController)?.isHosted != true,
              browserState?.windowController?.isHosted != true, let browserState else { return }
        standaloneFloatingSidebarHost.install(in: self, over: view)
        standaloneFloatingSidebarHost.present(browserState)
    }
}
