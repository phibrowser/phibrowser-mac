// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI
import SwiftData

extension MainBrowserWindowController {
    @IBAction func newBrowserTab(_ sender: Any?) {
        let openNewTabPage = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.loadValue()
        if openNewTabPage {
            if browserState.isIncognito {
                browserState.enqueueNativeNTP()
            }
            browserState.createTab("chrome://newtab", focusAfterCreate: true)
        } else {
            toggleOmniBox(fromAddressBar: false)
        }
    }
    
    func handleCloseTab() -> Bool {
        if omniBoxContainerViewController?.hasShown ?? false {
            omniBoxContainerViewController?.hideOmniBox()
            return true
        } else {
            return false
        }
    }
    
    @IBAction func openLocationBar(_ sender: Any?) {
        var addressView = sender as? NSView
        if addressView == nil,
           PhiPreferences.GeneralSettings.loadLayoutMode() != .performance {
            addressView = mainSplitViewController.webContentContainerViewController.addressBarAnchorView
        }
        toggleOmniBox(fromAddressBar: true, addressView: addressView)
    }
    
    @IBAction func selectTabWithIndex(_ index: Int) {
        browserState.selectTabWithIndex(index)
    }
    
    @objc func toggleOmniBox(fromAddressBar: Bool, addressView: NSView? = nil) {
        if omniBoxContainerViewController?.hasShown ?? false == false {
            if omniBoxContainerViewController == nil {
                omniBoxContainerViewController = OmniBoxContainerViewController(browserState: self.browserState, superView: omnibackgroundView)
            }
            omniBoxContainerViewController?.omniBoxController?.beginOpenTrace(
                trigger: fromAddressBar ? "address-bar" : "omnibox",
                addressViewPresent: addressView != nil
            )
            
            // Add background view to content view
            if let contentView = contentViewController?.view {
                contentView.addSubview(omnibackgroundView)
                omnibackgroundView.snp.makeConstraints { make in
                    make.edges.equalToSuperview()
                }
                
                // Add omniBox container to background view
                if let containerView = omniBoxContainerViewController?.view {
                    omnibackgroundView.addSubview(containerView)
                    containerView.snp.makeConstraints { make in
                        make.edges.equalToSuperview()
                    }
                }
            }
            if fromAddressBar, let tab = browserState.focusingTab {
                omniBoxContainerViewController?.omniBoxController?.updateStatus(
                    with: tab,
                    suppressAutomaticSearch: true
                )
            }
            omniBoxContainerViewController?.showOmniBox(fromAddressBar: fromAddressBar, addressView: addressView)
        } else if omniBoxContainerViewController?.omniBoxController?.openningFromCurrenTab == false,
                  fromAddressBar,
                  addressView == nil {
            // `Cmd+L` while already open should refill the current tab state.
            omniBoxContainerViewController?.omniBoxController?.beginOpenTrace(
                trigger: "address-bar-refill",
                addressViewPresent: false
            )
            if let tab = browserState.focusingTab {
                omniBoxContainerViewController?.omniBoxController?.updateStatus(
                    with: tab,
                    suppressAutomaticSearch: true
                )
                omniBoxContainerViewController?.omniBoxController?.requestAtonce(source: .manualRefresh)
            }
        } else {
            // Already showing, just hide it
            omniBoxContainerViewController?.hideOmniBox(fromAddressBar: fromAddressBar)
        }
    }
    
    @IBAction func toggleBookmark(_ sender: Any?) {
        let state = browserState
        guard let tab = state.focusingTab,
              let url = tab.url, !url.isEmpty else { return }

        if let existing = state.bookmarkManager.findBookmark(byURL: url) {
            presentBookmarkEditor(for: existing)
        } else {
            state.bookmarkManager.addBookmark(title: tab.title, url: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if let newBookmark = state.bookmarkManager.findBookmark(byURL: url) {
                    self?.presentBookmarkEditor(for: newBookmark)
                }
            }
        }
    }
    
    @IBAction func reload(_ sender: Any) {
        browserState.focusingTab?.reload()
    }
    
    /// will be called by PhiApplication.sendEvent
    @IBAction func goBack(_ sender: Any) {
        browserState.focusingTab?.goBack()
    }
    
    @IBAction func goForward(_ sender: Any) {
        browserState.focusingTab?.goForward()
    }

    private func presentBookmarkEditor(for bookmark: Bookmark) {
        let state = browserState
        let bookmarkGuid = bookmark.guid
        let originalParentGuid = bookmark.parent?.guid

        EditPinnedTabPresenter.presentModal(
            mode: .editOrMoveBookmark,
            title: bookmark.title,
            urlString: bookmark.url ?? "",
            modelContainer: state.localStore.container,
            profileId: state.profileId,
            initialFolderGuid: originalParentGuid,
            from: window,
            onRemove: {
                state.bookmarkManager.removeBookmark(bookmark)
            },
            onCreateFolder: { folderName in
                let guid = UUID().uuidString
                state.localStore.createDirectory(
                    title: folderName, profileId: state.profileId,
                    parentId: nil, guid: guid
                )
                return guid
            },
            onSave: { result in
                state.bookmarkManager.updateBookmark(
                    guid: bookmarkGuid,
                    title: result.title,
                    url: result.url
                )
                if let newParentGuid = result.parentFolderGuid,
                   newParentGuid != originalParentGuid {
                    if let targetFolder = state.bookmarkManager.bookmark(withGuid: newParentGuid) {
                        state.bookmarkManager.moveBookmark(bookmark, to: targetFolder)
                    } else {
                        state.localStore.moveBookmark(
                            bookmarkGuid, profileId: state.profileId,
                            to: newParentGuid, newIndex: Int.max
                        )
                    }
                }
            }
        )
    }
}

extension BrowserState {
    func selectTabWithIndex(_ index: Int) {
        guard index >= 0 else {
            return
        }

        let pinnedCount = pinnedTabs.count
        let bookmarkCount = visibleBookmarkTabs.count
        let normalCount = normalTabs.count

        if index < pinnedCount {
            openOrFocusPinnedTab(pinnedTabs[index])
            return
        }

        let afterPinned = index - pinnedCount
        if afterPinned < bookmarkCount {
            openBookmark(visibleBookmarkTabs[afterPinned])
            return
        }

        let afterBookmarks = afterPinned - bookmarkCount
        if afterBookmarks < normalCount, let wrapper = normalTabs[afterBookmarks].webContentWrapper {
            wrapper.setAsActiveTab()
        }
    }
    
    enum SwitchTabDirection {
        case back, forward, last
    }
    
    func swicthTab(_ dir: SwitchTabDirection) {
        guard let current = focusingTab, !tabs.isEmpty else {
            return
        }

        struct Candidate {
            let focus: () -> Void
            let matchesCurrent: (Tab) -> Bool
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(pinnedTabs.count + visibleBookmarkTabs.count + normalTabs.count)

        // 1) pinned (may open if not opened)
        for pinned in pinnedTabs {
            candidates.append(.init(
                focus: { [weak self] in self?.openOrFocusPinnedTab(pinned) },
                matchesCurrent: { current in
                    if pinned.guid == current.guid { return true }
                    if let a = pinned.guidInLocalDB, let b = current.guidInLocalDB, !a.isEmpty, a == b { return true }
                    return false
                }
            ))
        }

        // 2) visible bookmarks (opened or not) ordered by sidebar visibility
        for bookmark in visibleBookmarkTabs {
            candidates.append(.init(
                focus: { [weak self] in self?.openBookmark(bookmark) },
                matchesCurrent: { current in
                    if let b = current.guidInLocalDB, !b.isEmpty, b == bookmark.guid { return true }
                    if bookmark.chromiumTabGuid != -1, bookmark.chromiumTabGuid == current.guid { return true }
                    return false
                }
            ))
        }

        // 3) normal open tabs
        for tab in normalTabs {
            candidates.append(.init(
                focus: { tab.webContentWrapper?.setAsActiveTab() },
                matchesCurrent: { current in
                    if tab.guid == current.guid { return true }
                    if let a = tab.guidInLocalDB, let b = current.guidInLocalDB, !a.isEmpty, a == b { return true }
                    return false
                }
            ))
        }

        guard !candidates.isEmpty else { return }

        guard let currentIndex = candidates.firstIndex(where: { $0.matchesCurrent(current) }) else {
            // If current isn't in our candidate list (rare), fall back to first.
            candidates.first?.focus()
            return
        }

        switch dir {
        case .last:
            candidates.last?.focus()
        case .forward:
            let next = (currentIndex + 1) % candidates.count
            candidates[next].focus()
        case .back:
            let prev = (currentIndex - 1 + candidates.count) % candidates.count
            candidates[prev].focus()
        }
    }
}

extension MainBrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeOther(_:)) {
            guard let tab = menuItem.representedObject as? Tab else {
                return false
            }
            return browserState.tabs.filter { $0.guid != tab.guid }.count > 0
        }
        return true
    }
    
    @objc func myCopyLink(_ item: NSMenuItem) {
        guard let item = item.representedObject as? WebContentRepresentable, let url = item.url else {
            return
        }
        
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(URLProcessor.phiBrandEnsuredUrlString(url), forType: .string)
    }
    
    @objc func closeTab(_ item: NSMenuItem) {
        guard let tab = item.representedObject as? Tab else {
            return
        }
        tab.close()
    }
    
    @objc func closeOther(_ item: NSMenuItem) {
        guard let tab = item.representedObject as? Tab else {
            return
        }
        browserState.closeTabs(keeping: [tab.guid])
    }
    
    @objc func togglePin(_ item: NSMenuItem) {
        guard let tab = item.representedObject as? Tab else {
            return
        }
        browserState.toggleTabPinStatus(tab.guid, guidInDB: tab.guidInLocalDB)
    }
    
    
    func showFeedbackWindow() {
        let identifier = NSUserInterfaceItemIdentifier("Phi Feedback Window")
        // Check if about window already exists
        if let existingWindow = NSApp.windows.first(where: { $0.identifier == identifier }) {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        let vc = FeedbackViewController(host: self)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 652),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = identifier
        window.center()
        window.isReleasedWhenClosed = false
        window.title = NSLocalizedString("Send Feedback to Phi", comment: "Feedback window - Window title for feedback submission")
        window.contentViewController = vc
        window.makeKeyAndOrderFront(nil)
    }
    
    func showImportDataWindow() {
        let identifier = NSUserInterfaceItemIdentifier("Phi Import Data Window")
        // Check if import window already exists
        if let existingWindow = NSApp.windows.first(where: { $0.identifier == identifier }) {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        let vc = ImportFromOtherBrowserViewController(
            displayMode: .normal,
            targetProfileId: browserState.profileId,
            targetWindowId: browserState.windowId
        )
        vc.onCompletion = { [weak vc] in
            vc?.view.window?.close()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 625),
            styleMask: [.titled,.closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = identifier
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = vc
        window.makeKeyAndOrderFront(nil)

        // Keep vc alive while window is open (window.contentViewController changes during navigation)
        objc_setAssociatedObject(window, "importVC", vc, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Data type selection flow for standalone import window
        var dataTypeVCs: [BrowserType: ImportDataTypeViewController] = [:]

        vc.onBrowserSelected = { [weak vc, weak window] browser, chromeDir in
            guard let vc, let window else { return }
            let dtvc = dataTypeVCs[browser] ?? ImportDataTypeViewController(browserType: browser, displayMode: .normal)
            dataTypeVCs[browser] = dtvc
            dtvc.onReturn = { [weak vc, weak window] hasSelection in
                guard let vc, let window else { return }
                if hasSelection {
                    vc.markBrowserConfigured(browser)
                } else {
                    vc.unmarkBrowserConfigured(browser)
                    dataTypeVCs.removeValue(forKey: browser)
                }
                // Collect data types and pass to VC
                var dataTypesPerBrowser: [BrowserType: [String]] = [:]
                for (b, dtvc) in dataTypeVCs {
                    dataTypesPerBrowser[b] = dtvc.selectedDataTypeStrings()
                }
                vc.dataTypesPerBrowser = dataTypesPerBrowser.isEmpty ? nil : dataTypesPerBrowser
                window.contentViewController = vc
            }
            window.contentViewController = dtvc
        }
    }
}
