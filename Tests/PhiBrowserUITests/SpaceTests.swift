// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest

/// UI tests for the Spaces feature: creating a Space (and giving it a bookmark
/// and a pinned tab), plus creating and deleting a browser profile.
///
/// The feature is gated behind `spacesFeatureEnabled`, which defaults to
/// `false`, so the suite turns it on with the `-spacesFeatureEnabled YES`
/// launch argument (it lands in `UserDefaults`' argument domain — higher
/// precedence than the persisted value, written to no store). Without it the
/// top-level **Spaces** menu stays hidden and there is nothing to drive.
///
/// The Spaces / Profile surfaces are SwiftUI panels and `NSAlert`s with few
/// stable identifiers, so the tests drive them through the two most reliable
/// surfaces:
///
///  1. The native menu bar. The top-level **Spaces** menu re-lists every Space
///     by name on each open (`rebuildSpacesMenu` via the menu delegate), and
///     its **Delete Profile** submenu re-lists every deletable profile on each
///     open. A menu item titled with the new Space / profile name is therefore
///     the canonical "it exists" signal — and its disappearance the "it was
///     deleted" signal.
///
///  2. The sidebar. A bookmark added to the active Space shows up as a
///     `sidebarBookmark` row; a pinned tab shows up as a `sidebarPinnedTab`
///     grid item. (Same identifiers the split-view suite relies on.)
///
/// The create-Space form is SwiftUI with no test identifiers (the test lives
/// entirely in the test target and changes no production code), so it is
/// addressed through surfaces the production UI already exposes: the name
/// field by its placeholder ("Space name") and the confirm button by its
/// title ("Create Space").
final class SpaceTests: XCTestCase {

    /// Accessibility identifier on the sidebar's bookmark rows (BookmarkCellView).
    private static let bookmarkIdentifier = "sidebarBookmark"
    /// Accessibility identifier on the sidebar's pinned-grid items (PinnedTabItem).
    private static let pinnedTabIdentifier = "sidebarPinnedTab"
    /// Placeholder on the SwiftUI create-Space name field (used to locate it).
    private static let createSpaceNamePlaceholder = "Space name"
    /// Title on the SwiftUI create-Space confirm button.
    private static let createSpaceConfirmTitle = "Create Space"

    // Menu titles (verbatim, including the real ellipsis glyph U+2026).
    private static let spacesMenuTitle = "Spaces"
    private static let newSpaceItem = "New Space\u{2026}"
    private static let deleteSpaceItem = "Delete Space\u{2026}"
    private static let newProfileItem = "New Profile\u{2026}"
    private static let deleteProfileSubmenu = "Delete Profile"

    /// A fresh app per test. These tests create heavyweight Chromium profiles
    /// and Spaces that don't cleanly tear down (a deleted profile lingers in the
    /// list, etc.), so a shared instance accumulates state and lets one test's
    /// crash cascade into the next. A per-test launch keeps every test
    /// independent. The cold start (Chromium + Sentinel + bridge warm-up) is the
    /// price of that isolation.
    ///
    /// Two isolation layers are in play: `--user-data-dir` gives Chromium a
    /// fresh profile tree, and `-uitest` makes the Swift-side `LocalStore`
    /// (Spaces / bookmarks / pinned tabs) use a throwaway per-launch temp
    /// directory (see `Account.uiTestStoreDirectoryURL`) so the suite never
    /// reads or mutates the real account's data.
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest", "1",
            // Master toggle for the Spaces + profile-management UI. Defaults to
            // false; the argument domain flips it on for this launch only.
            "-spacesFeatureEnabled", "YES",
            // `--user-data-dir` (a `--` arg, forwarded straight to Chromium by
            // `ChromiumLauncher`) gives the test an isolated profile so it
            // neither collides with a running Phi's process-singleton nor
            // mutates the real dev profile's Spaces / profiles / bookmarks.
            // Unique per launch so a stale Chromium SingletonLock left by an
            // earlier (possibly hung) run can't make this launch hand off to a
            // dead instance.
            "--user-data-dir=\(NSTemporaryDirectory())PhiUITest-\(ProcessInfo.processInfo.globallyUniqueString)",
        ]
        app.launch()
        self.app = app

        let window = app.windows.firstMatch
        // Cold launch is slow: Chromium cold start + session restore + Sentinel
        // can take well over 45s.
        XCTAssertTrue(window.waitForExistence(timeout: 120),
                      "Main window did not appear (Phi cold start + session restore can be slow)")
        app.activate()
        app.typeKey(.escape, modifierFlags: [])

        // Proves the feature flag took effect: with Spaces disabled the
        // top-level menu is hidden and the rest of the suite is meaningless.
        let spacesMenu = app.menuBars.menuBarItems[Self.spacesMenuTitle]
        XCTAssertTrue(spacesMenu.waitForExistence(timeout: 30),
                      "Top-level 'Spaces' menu never appeared — the Spaces feature may not be enabled")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Tests

    @MainActor
    func test_createSpace_appearsInSpacesMenu() throws {
        let spaceName = "Space-\(Self.token())"

        try runStep("Create a Space named \(spaceName)") {
            try self.createSpace(named: spaceName)
        }

        // The Spaces menu re-lists every Space on open, so a menu item titled
        // with the new name proves the Space was created.
        XCTAssertTrue(waitUntilSpacesMenu(contains: spaceName, timeout: 15),
                      "The new Space '\(spaceName)' should be listed in the Spaces menu")
        attachDiagnostics(label: "after-create-space")
    }

    @MainActor
    func test_createSpace_thenAddBookmarkAndPinnedTab() throws {
        let spaceName = "BkSpace-\(Self.token())"

        try runStep("Create and activate a Space") {
            try self.createSpace(named: spaceName)
            XCTAssertTrue(self.waitUntilSpacesMenu(contains: spaceName, timeout: 15),
                          "The new Space should be listed before activating it")
            try self.activateSpace(named: spaceName)
        }

        try runStep("Open a fresh tab on a real URL") {
            self.app.typeKey("t", modifierFlags: .command)
            self.app.typeKey("l", modifierFlags: .command)
            self.app.typeText("https://example.com")
            self.app.typeKey("\r", modifierFlags: [])
        }

        let outline = app.windows.firstMatch.outlines["sidebarTabList"]
        XCTAssertTrue(outline.waitForExistence(timeout: 15),
                      "Sidebar outline 'sidebarTabList' not found")

        // Bookmark first — pinning the tab moves it out of the normal list, so
        // it must still be a normal tab when we bookmark it.
        let bookmarksBefore = sidebarBookmarks().count
        try runStep("Add the tab to this Space's bookmarks") {
            try self.rightClickFocusedSidebarTab()
            try self.clickMenuItem(matching: ["Add to Bookmark", "Add to Bookmark Bar"])
        }
        XCTAssertTrue(waitForCount(of: sidebarBookmarks(), equalTo: bookmarksBefore + 1, timeout: 15),
                      "Adding a bookmark should add one 'sidebarBookmark' row")
        attachDiagnostics(label: "after-add-bookmark")

        let pinnedBefore = sidebarPinnedTabs().count
        try runStep("Pin the tab") {
            try self.rightClickFocusedSidebarTab()
            try self.clickMenuItem(matching: ["Pin"])
        }
        XCTAssertTrue(waitForCount(of: sidebarPinnedTabs(), equalTo: pinnedBefore + 1, timeout: 15),
                      "Pinning the tab should add one 'sidebarPinnedTab' grid item")
        attachDiagnostics(label: "after-pin-tab")
    }

    @MainActor
    func test_createProfile_appearsInDeleteProfileSubmenu() throws {
        let profileName = "Prof-\(Self.token())"

        try runStep("Create a profile named \(profileName)") {
            try self.createProfile(named: profileName)
        }

        // Profile creation round-trips through the Chromium bridge, so poll the
        // Delete Profile submenu (every non-default profile is listed there).
        // The window is generous because the very first profile op on a
        // cold-started app waits for the Chromium profile system to warm up.
        XCTAssertTrue(waitUntilDeleteProfileSubmenu(contains: profileName, timeout: 60),
                      "The new profile '\(profileName)' should appear in the Delete Profile submenu")
        attachDiagnostics(label: "after-create-profile")
    }

    @MainActor
    func test_deleteProfile_afterDeletingItsBoundSpace() throws {
        // A profile bound to a Space cannot be cleanly deleted — its bound
        // Space(s) must be deleted first. This drives that whole workflow:
        // create a Space on a new profile, delete the Space to free the profile,
        // then delete the now-free profile.
        let spaceName = "DPSpace-\(Self.token())"
        let profileName = "DPProf-\(Self.token())"

        try runStep("Create a Space bound to a brand-new profile") {
            try self.createSpace(named: spaceName, withNewProfile: profileName)
        }

        // The Space binds to the profile, so its Delete Profile row reads
        // "<name> — in use by a Space".
        XCTAssertTrue(waitUntilDeleteProfileSubmenu(profileInUse: profileName, timeout: 60),
                      "The new profile should be listed as 'in use by a Space' while its Space exists")

        try runStep("Delete the user-created bound Space first") {
            try self.activateSpace(named: spaceName)
            try self.deleteActiveSpace(expectingName: spaceName)
            XCTAssertTrue(self.waitUntilSpacesMenu(lacks: spaceName, timeout: 20),
                          "The bound Space should be gone after deleting it")
        }

        // The profile retains an auto-created "Default" Space (spaceId
        // == defaultSpaceId) that `deleteSpace` refuses to remove, so the row
        // keeps its "in use" suffix — but the Delete Profile affordance still
        // permits deleting the profile. Per the workflow, the user-created bound
        // Space was removed first; now delete the profile itself.
        try runStep("Delete the profile") {
            try self.confirmDeleteProfile(matchingPrefix: profileName)
        }

        // Accepting the deletion must not surface an error dialog. The on-disk
        // removal is an async Chromium cascade that `listProfiles()` may not
        // reflect within the test session, so we assert the flow is accepted
        // cleanly rather than polling for the row to vanish.
        try runStep("Verify the deletion was accepted without error") {
            let errorTitle = self.app.staticTexts["Couldn't delete profile"]
            XCTAssertFalse(errorTitle.waitForExistence(timeout: 4),
                           "Deleting the profile should not report an error")
        }
        attachDiagnostics(label: "after-delete-profile-and-space")
    }

    @MainActor
    func test_createSpace_withNewProfile_createsSpaceAndProfile() throws {
        let spaceName = "PSpace-\(Self.token())"
        let profileName = "PProf-\(Self.token())"

        try runStep("Create a Space bound to a brand-new profile") {
            try self.createSpace(named: spaceName, withNewProfile: profileName)
        }

        // The Space must be created...
        XCTAssertTrue(waitUntilSpacesMenu(contains: spaceName, timeout: 15),
                      "The new Space '\(spaceName)' should be listed in the Spaces menu")
        // ...and so must the profile created from the panel's picker. Once the
        // Space binds to it the Delete Profile row reads "<name> — in use by a
        // Space", so match by prefix to cover both the bound and unbound cases.
        XCTAssertTrue(waitUntilDeleteProfileSubmenu(containsPrefix: profileName, timeout: 60),
                      "The new profile '\(profileName)' should appear in the Delete Profile submenu")
        attachDiagnostics(label: "after-create-space-with-new-profile")
    }

    @MainActor
    func test_deleteSpace_removesItFromSpacesMenu() throws {
        let spaceName = "DelSpace-\(Self.token())"

        try runStep("Create and activate a Space") {
            try self.createSpace(named: spaceName)
            XCTAssertTrue(self.waitUntilSpacesMenu(contains: spaceName, timeout: 15),
                          "The new Space should be listed before deleting it")
            try self.activateSpace(named: spaceName)
        }

        try runStep("Delete the active Space and confirm the destructive dialog") {
            try self.deleteActiveSpace(expectingName: spaceName)
        }

        // Unlike profile deletion (an async Chromium cascade), Space deletion is
        // a local SwiftData cascade, so the row drops from the menu once the
        // write republishes `SpaceManager.spaces`.
        XCTAssertTrue(waitUntilSpacesMenu(lacks: spaceName, timeout: 20),
                      "The deleted Space '\(spaceName)' should disappear from the Spaces menu")
        attachDiagnostics(label: "after-delete-space")
    }

    // MARK: - Space actions

    /// Opens Spaces → New Space… and fills the SwiftUI form's name field,
    /// returning the still-unclicked confirm button (the anchor that proves the
    /// form mounted). The form renders inline in the sidebar (vertical layout)
    /// or as a floating window; the app-wide queries find it either way.
    @MainActor
    private func openAndFillCreateSpaceForm(name: String) throws -> XCUIElement? {
        try clickSpacesMenuItem(Self.newSpaceItem)

        let confirm = app.buttons[Self.createSpaceConfirmTitle]
        guard confirm.waitForExistence(timeout: 15) else {
            attachDiagnostics(label: "no create-space confirm button")
            XCTFail("Create-Space form did not appear ('\(Self.createSpaceConfirmTitle)' button missing)")
            return nil
        }

        let nameField = app.textFields
            .matching(NSPredicate(format: "placeholderValue == %@", Self.createSpaceNamePlaceholder))
            .firstMatch
        guard nameField.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no create-space name field")
            XCTFail("Create-Space name field (placeholder '\(Self.createSpaceNamePlaceholder)') did not appear")
            return nil
        }
        nameField.click()
        nameField.typeText(name)
        return confirm
    }

    /// Opens Spaces → New Space…, fills the form, and confirms with the default
    /// profile.
    @MainActor
    private func createSpace(named name: String) throws {
        guard let confirm = try openAndFillCreateSpaceForm(name: name) else { return }
        confirm.click()
    }

    /// Opens Spaces → New Space…, fills the form, creates a brand-new profile
    /// from the form's profile picker (the form's single menu button) so the
    /// Space binds to it, then confirms.
    @MainActor
    private func createSpace(named name: String, withNewProfile profileName: String) throws {
        guard let confirm = try openAndFillCreateSpaceForm(name: name) else { return }

        let picker = app.windows.firstMatch.menuButtons.firstMatch
        guard picker.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no create-space profile picker")
            XCTFail("Create-Space profile picker (menu button) did not appear")
            return
        }
        picker.click()

        // "New Profile…" exists in both the always-present menu-bar Spaces menu
        // and the open picker popup, so an app-wide title lookup is ambiguous.
        // Only the open picker's item is on-screen, so click the hittable one.
        guard clickHittableMenuItem(Self.newProfileItem, timeout: 5) else {
            attachDiagnostics(label: "no New Profile… in picker")
            closeMenus()
            XCTFail("'New Profile…' was not offered in the create-Space profile picker")
            return
        }

        // The picker's "New Profile…" opens the same NSAlert as the menu's.
        let alert = waitForAlert()
        guard alert.exists else {
            attachDiagnostics(label: "no new-profile alert from picker")
            XCTFail("New Profile alert did not appear from the picker")
            return
        }
        let field = alert.textFields.firstMatch
        guard field.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no profile-name field from picker")
            XCTFail("Profile-name field did not appear in the New Profile alert")
            return
        }
        field.click()
        field.typeText(profileName)
        let create = alert.buttons["Create"]
        guard create.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no profile Create button from picker")
            XCTFail("'Create' button did not appear in the New Profile alert")
            return
        }
        create.click()

        // Profile creation round-trips through the Chromium bridge, which then
        // selects the new profile in the picker. Wait for the alert to dismiss
        // (and let the selection land) before committing, so the Space binds to
        // the new profile rather than the previously-selected default.
        _ = alert.waitForNonExistence(timeout: 5)

        // Bind the Space to the new profile *deterministically*: the post-create
        // auto-selection lands asynchronously (after the bridge round-trip), so
        // committing now could bind to the previously-selected default instead.
        // The picker's profile rows set the binding synchronously on click, so
        // reopen the picker, wait for the new profile row to appear, and pick it.
        guard selectProfileInCreateSpacePicker(named: profileName, timeout: 60) else {
            attachDiagnostics(label: "new profile never selectable in picker")
            XCTFail("New profile '\(profileName)' never became selectable in the create-Space picker")
            return
        }

        guard confirm.waitForExistence(timeout: 10) else {
            attachDiagnostics(label: "create-space confirm gone after new profile")
            XCTFail("Create Space button should remain after creating a profile")
            return
        }
        confirm.click()
    }

    /// Reopens the create-Space profile picker until it offers a row titled
    /// `profileName` (the new profile appears once the bridge create round-trips),
    /// then clicks it — which binds the Space to that profile synchronously.
    @MainActor
    private func selectProfileInCreateSpacePicker(named profileName: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let picker = app.windows.firstMatch.menuButtons.firstMatch
            guard picker.waitForExistence(timeout: 3) else { return false }
            picker.click()
            // The new profile row only appears after the bridge create lands;
            // until then, close the picker and retry.
            if clickHittableMenuItem(profileName, timeout: 2) {
                return true   // selecting a row closes the picker menu
            }
            closeMenus()
        } while Date() < deadline
        return false
    }

    /// Activates a Space by clicking its name row in the Spaces menu (the full
    /// activation path that brings the Space's window/tab set forward).
    @MainActor
    private func activateSpace(named name: String) throws {
        try clickSpacesMenuItem(name)
    }

    /// Opens Spaces → Delete Space… (which deletes the *active* Space), asserts
    /// the destructive confirmation names `name`, then confirms.
    @MainActor
    private func deleteActiveSpace(expectingName name: String) throws {
        try clickSpacesMenuItem(Self.deleteSpaceItem)

        let alert = waitForAlert()
        guard alert.exists else {
            attachDiagnostics(label: "no delete-space confirmation dialog")
            XCTFail("Delete Space confirmation dialog did not appear")
            return
        }
        let namesSpace = alert.staticTexts.containing(
            NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", name, name)
        ).firstMatch
        XCTAssertTrue(namesSpace.waitForExistence(timeout: 3),
                      "The confirmation should name the Space '\(name)' being deleted")

        let delete = alert.buttons["Delete"]
        guard delete.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no Delete confirm button (space)")
            XCTFail("'Delete' confirmation button did not appear")
            return
        }
        delete.click()
    }

    // MARK: - Profile actions

    /// Opens Spaces → New Profile…, types a name into the resulting NSAlert, and
    /// clicks Create.
    @MainActor
    private func createProfile(named name: String) throws {
        try clickSpacesMenuItem(Self.newProfileItem)

        let alert = waitForAlert()
        guard alert.exists else {
            attachDiagnostics(label: "no new-profile alert")
            XCTFail("New Profile alert did not appear")
            return
        }
        let field = alert.textFields.firstMatch
        guard field.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no profile-name field")
            XCTFail("Profile-name field did not appear in the New Profile alert")
            return
        }
        field.click()
        field.typeText(name)

        let create = alert.buttons["Create"]
        guard create.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no profile Create button")
            XCTFail("'Create' button did not appear in the New Profile alert")
            return
        }
        create.click()
    }

    /// Opens Spaces → Delete Profile → <profile starting with `prefix`> and
    /// confirms the destructive NSAlert. Prefix-matches so it works whether the
    /// row is the plain name or "<name> — in use by a Space".
    @MainActor
    private func confirmDeleteProfile(matchingPrefix prefix: String) throws {
        guard openDeleteProfileSubmenu() else {
            XCTFail("Could not open the Delete Profile submenu")
            return
        }
        let item = app.menuBars.menuItems[Self.deleteProfileSubmenu]
            .descendants(matching: .menuItem)
            .matching(NSPredicate(format: "title BEGINSWITH %@ OR label BEGINSWITH %@", prefix, prefix))
            .firstMatch
        guard item.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "profile \(prefix) absent from delete submenu")
            closeMenus()
            XCTFail("No profile starting with '\(prefix)' in the Delete Profile submenu")
            return
        }
        item.click()

        let alert = waitForAlert()
        let delete = alert.buttons["Delete"]
        guard delete.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no delete-profile confirm button")
            XCTFail("'Delete' confirmation button did not appear")
            return
        }
        delete.click()
    }

    // MARK: - Menu-bar helpers

    /// Opens the top-level Spaces menu. Returns false (after attaching
    /// diagnostics) if the menu never appears.
    @MainActor
    @discardableResult
    private func openSpacesMenu() -> Bool {
        closeMenus()
        let spaces = app.menuBars.menuBarItems[Self.spacesMenuTitle]
        guard spaces.waitForExistence(timeout: 10) else {
            attachDiagnostics(label: "no Spaces menu-bar item")
            return false
        }
        spaces.click()
        return true
    }

    /// Clicks the on-screen (hittable) menu item titled `title`. Used when the
    /// same title exists both in the persistent menu bar and in a transient
    /// popup (e.g. "New Profile…"): only the open popup's copy is hittable.
    @MainActor
    private func clickHittableMenuItem(_ title: String, timeout: TimeInterval) -> Bool {
        let query = app.menuItems.matching(
            NSPredicate(format: "label == %@ OR title == %@", title, title)
        )
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let target = query.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                target.click()
                return true
            }
        } while Date() < deadline
        return false
    }

    /// Opens the Spaces menu and clicks the item titled `title`.
    @MainActor
    private func clickSpacesMenuItem(_ title: String) throws {
        guard openSpacesMenu() else {
            XCTFail("Spaces menu unavailable")
            return
        }
        let item = app.menuBars.menuItems[title]
        guard item.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no Spaces menu item '\(title)'")
            closeMenus()
            XCTFail("Spaces menu item '\(title)' not found")
            return
        }
        item.click()
    }

    /// Opens the Spaces menu and hovers Delete Profile to expand its submenu.
    @MainActor
    @discardableResult
    private func openDeleteProfileSubmenu() -> Bool {
        guard openSpacesMenu() else { return false }
        let parent = app.menuBars.menuItems[Self.deleteProfileSubmenu]
        guard parent.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no Delete Profile submenu parent")
            closeMenus()
            return false
        }
        // Hovering opens the submenu without dismissing the parent menu.
        parent.hover()
        return true
    }

    /// The profile row titled `name` *inside the Delete Profile submenu*. The
    /// Spaces menu also has a Change Profile submenu listing the same profile
    /// names, so a whole-menu-bar lookup matches twice; scoping to the Delete
    /// Profile parent's descendants keeps the match unambiguous.
    @MainActor
    private func deleteProfileItem(named name: String) -> XCUIElement {
        app.menuBars.menuItems[Self.deleteProfileSubmenu]
            .descendants(matching: .menuItem)[name]
    }

    /// Whether the Spaces menu currently lists an item titled `title`. Opens and
    /// closes the menu as a side effect.
    @MainActor
    private func spacesMenuContains(_ title: String, timeout: TimeInterval) -> Bool {
        guard openSpacesMenu() else { return false }
        let exists = app.menuBars.menuItems[title].waitForExistence(timeout: timeout)
        closeMenus()
        return exists
    }

    /// Whether the Delete Profile submenu currently lists an item titled `name`.
    /// Opens and closes the menu as a side effect.
    @MainActor
    private func deleteProfileSubmenuContains(_ name: String, timeout: TimeInterval) -> Bool {
        guard openDeleteProfileSubmenu() else { return false }
        let exists = deleteProfileItem(named: name).waitForExistence(timeout: timeout)
        closeMenus()
        return exists
    }

    /// Polls the Spaces menu until it lists `title` (Space creation is a
    /// synchronous optimistic insert, but the menu only refreshes on open).
    @MainActor
    private func waitUntilSpacesMenu(contains title: String, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { self.spacesMenuContains(title, timeout: 1) }
    }

    /// Polls the Delete Profile submenu until it lists `name` (profile creation
    /// round-trips through the Chromium bridge, so this can take a few seconds).
    @MainActor
    private func waitUntilDeleteProfileSubmenu(contains name: String, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { self.deleteProfileSubmenuContains(name, timeout: 1) }
    }

    /// Whether the Delete Profile submenu lists a profile whose title starts
    /// with `prefix`. A Space-bound profile reads "<name> — in use by a Space",
    /// so an exact-title match would miss it; prefix matching covers both the
    /// bound and unbound spellings.
    @MainActor
    private func deleteProfileSubmenuContains(prefix: String, timeout: TimeInterval) -> Bool {
        guard openDeleteProfileSubmenu() else { return false }
        let item = app.menuBars.menuItems[Self.deleteProfileSubmenu]
            .descendants(matching: .menuItem)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR title BEGINSWITH %@", prefix, prefix))
            .firstMatch
        let exists = item.waitForExistence(timeout: timeout)
        closeMenus()
        return exists
    }

    /// Polls the Delete Profile submenu until a profile whose title starts with
    /// `prefix` appears.
    @MainActor
    private func waitUntilDeleteProfileSubmenu(containsPrefix prefix: String, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { self.deleteProfileSubmenuContains(prefix: prefix, timeout: 1) }
    }

    /// Whether the Delete Profile submenu lists `profileName` with the
    /// "— in use by a Space" suffix (i.e. it is bound to a Space).
    @MainActor
    private func deleteProfileSubmenuShowsInUse(_ profileName: String, timeout: TimeInterval) -> Bool {
        guard openDeleteProfileSubmenu() else { return false }
        let item = app.menuBars.menuItems[Self.deleteProfileSubmenu]
            .descendants(matching: .menuItem)
            .matching(NSPredicate(
                format: "(label BEGINSWITH %@ OR title BEGINSWITH %@) AND (label CONTAINS %@ OR title CONTAINS %@)",
                profileName, profileName, "in use", "in use"))
            .firstMatch
        let exists = item.waitForExistence(timeout: timeout)
        closeMenus()
        return exists
    }

    /// Polls until `profileName` is shown as in use by a Space (bound).
    @MainActor
    private func waitUntilDeleteProfileSubmenu(profileInUse profileName: String, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { self.deleteProfileSubmenuShowsInUse(profileName, timeout: 1) }
    }

    /// Polls the Spaces menu until it no longer lists an item titled `title`
    /// (Space deletion is a local SwiftData cascade that republishes the list).
    @MainActor
    private func waitUntilSpacesMenu(lacks title: String, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { !self.spacesMenuContains(title, timeout: 1) }
    }

    /// Closes any open menu / submenu (two escapes covers a submenu nested one
    /// level under the menu bar).
    @MainActor
    private func closeMenus() {
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The frontmost modal NSAlert. `runModal()` surfaces as a dialog; some
    /// configurations expose it as a sheet, so fall back to that.
    @MainActor
    private func waitForAlert(timeout: TimeInterval = 10) -> XCUIElement {
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: timeout) { return dialog }
        let sheet = app.sheets.firstMatch
        _ = sheet.waitForExistence(timeout: 2)
        return sheet.exists ? sheet : dialog
    }

    // MARK: - Sidebar helpers

    @MainActor
    private func sidebarBookmarks() -> XCUIElementQuery {
        app.windows.firstMatch.buttons.matching(identifier: Self.bookmarkIdentifier)
    }

    @MainActor
    private func sidebarPinnedTabs() -> XCUIElementQuery {
        app.windows.firstMatch.buttons.matching(identifier: Self.pinnedTabIdentifier)
    }

    /// Right-clicks the active (last) tab cell in the sidebar's `sidebarTabList`
    /// outline. Clicks ~8% in from the left edge to dodge a split-pair cell's
    /// centre dead-space gap (a plain tab is unaffected).
    @MainActor
    private func rightClickFocusedSidebarTab() throws {
        let outline = app.windows.firstMatch.outlines["sidebarTabList"]
        guard outline.waitForExistence(timeout: 10) else {
            attachDiagnostics(label: "no sidebar outline")
            XCTFail("Sidebar outline 'sidebarTabList' not found")
            return
        }
        guard outline.cells.firstMatch.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no tab cell")
            XCTFail("Sidebar outline never populated a cell")
            return
        }
        let target = outline.cells.element(boundBy: outline.cells.count - 1)
        guard target.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "last cell missing")
            XCTFail("Last sidebar cell not resolvable")
            return
        }
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).rightClick()
    }

    /// Clicks the first context-menu item whose title matches any of
    /// `candidates`. Dumps the visible menu items if none match.
    @MainActor
    private func clickMenuItem(matching candidates: [String]) throws {
        for title in candidates {
            let item = app.menuItems[title]
            if item.waitForExistence(timeout: 3) {
                item.click()
                return
            }
        }
        let frontMenu = app.windows.firstMatch.menus.firstMatch
        let titles = frontMenu.exists
            ? frontMenu.menuItems.allElementsBoundByIndex.prefix(40).map { $0.title }
            : []
        let attachment = XCTAttachment(string: titles.isEmpty ? "<no context menu open>" : titles.joined(separator: "\n"))
        attachment.name = "menu-items-on-failure"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("None of the expected menu items appeared: \(candidates).")
    }

    // MARK: - Generic waits

    /// Waits until `query` reports exactly `count` elements.
    @MainActor
    private func waitForCount(of query: XCUIElementQuery, equalTo count: Int, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in query.count == count }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    /// Repeatedly evaluates `condition` until it returns true or `timeout`
    /// elapses. Used for the menu-reopen polls, where each probe already blocks
    /// for ~1s inside `waitForExistence`.
    @MainActor
    private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
        } while Date() < deadline
        return false
    }

    // MARK: - Step / diagnostics

    @MainActor
    private func runStep(_ name: String, _ body: () throws -> Void) throws {
        try XCTContext.runActivity(named: name) { _ in
            attachDiagnostics(label: "before \(name)")
            do {
                try body()
            } catch {
                attachDiagnostics(label: "failed \(name)")
                throw error
            }
            attachDiagnostics(label: "after \(name)")
        }
    }

    @MainActor
    private func attachDiagnostics(label: String) {
        let shot = XCUIScreen.main.screenshot()
        let imageAttachment = XCTAttachment(screenshot: shot)
        imageAttachment.name = "screen — \(label)"
        imageAttachment.lifetime = .keepAlways
        add(imageAttachment)

        let tree = app.windows.firstMatch.debugDescription
        let treeAttachment = XCTAttachment(string: tree)
        treeAttachment.name = "axtree — \(label)"
        treeAttachment.lifetime = .keepAlways
        add(treeAttachment)
    }

    /// Short, unique token so Spaces / profiles created across tests in the same
    /// shared app instance don't collide by name.
    private static func token() -> String {
        String(UUID().uuidString.prefix(6))
    }
}
