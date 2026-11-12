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

    /// A standalone window mounts its host on the window's content view,
    /// over this page area, as a hosted shell mounts its own: a page in
    /// content fullscreen lifts into an overlay there, and the panel must be
    /// that overlay's sibling to open over it. A hosted tree, prewarmed ones
    /// included, uses the shell's panel instead.
    func setupFloatingSidebar(in mainSplit: MainSplitViewController) {
        guard !mainSplit.isHosted, let browserState else { return }
        standaloneFloatingSidebarHost.install(in: mainSplit)
        standaloneFloatingSidebarHost.present(browserState)
    }
}
