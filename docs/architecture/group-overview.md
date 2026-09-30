# Group overview

`BrowserState.groupOverviewState` stores the selected group token. Membership is
derived from `normalTabs` and each tab's `groupToken`; the overview must not
maintain a second group membership list. Showing an unknown or empty group
clears the overview. Later group/tab changes revalidate the selection.

The overview is a native presentation in the web-content host. Entering it
collapses the active chat presentation. Group collapse and opening an overview
are distinct sidebar interactions and should keep distinct hit targets.

## Tab creation boundary

Submitting a URL while a group overview is active schedules the native insertion
and calls the bridge with the group token, `groupIndex: 0` and focus requested.
Creating a plain new tab uses the existing group-create operation and schedules
insertion after the group's current members. Both paths clear overview state.

The framework owns atomic tab creation and group membership. Do not emulate it
by separately creating, moving and grouping a tab in view code. The public native
header and supplied framework must agree on the selector; this document does
not include the framework implementation.

## Source and checks

- [Overview state and actions](../../Sources/States/TabGroup/BrowserState+GroupOverview.swift)
- [State value](../../Sources/States/TabGroup/GroupOverviewState.swift)
- [Presentation](../../Sources/UserInterface/WebContent/GroupOverview/GroupOverviewViewController.swift)
- [Bridge declaration](../../Sources/ChromiumBridge/PhiChromiumBridgeHeader.h)
- [Focused tests](../../Tests/PhiBrowserTests/BrowserStateGroupOverviewTests.swift)

Verify empty/deleted groups, changing members, group-header versus chevron clicks,
URL insertion at the start, new-tab insertion at the end and correct focus after
creation. Source or unit-test checks do not establish paired framework behavior.
