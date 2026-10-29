// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

extension CommandWrapper {
    var shortcutDescription: String {
        switch self {
        case .IDC_OPTIONS:
            return NSLocalizedString("settings.shortcuts.description.openSettings", value: "Open Phi settings.", comment: "Shortcuts settings - Description of the openSettings command")
        case .IDC_HIDE_APP:
            return NSLocalizedString("settings.shortcuts.description.hideApp", value: "Hide Phi and its windows.", comment: "Shortcuts settings - Description of the hideApp command")
        case .IDC_EXIT:
            return NSLocalizedString("settings.shortcuts.description.quitApp", value: "Quit Phi.", comment: "Shortcuts settings - Description of the quitApp command")
        case .IDC_CLEAR_BROWSING_DATA:
            return NSLocalizedString("settings.shortcuts.description.clearBrowsingData", value: "Choose which browsing data to clear.", comment: "Shortcuts settings - Description of the clearBrowsingData command")
        case .IDC_IMPORT_SETTINGS:
            return NSLocalizedString("settings.shortcuts.description.importSettings", value: "Import bookmarks and settings from another browser.", comment: "Shortcuts settings - Description of the importSettings command")
        case .IDC_NEW_TAB:
            return NSLocalizedString("settings.shortcuts.description.newTab", value: "Open a new tab.", comment: "Shortcuts settings - Description of the newTab command")
        case .IDC_NEW_WINDOW:
            return NSLocalizedString("settings.shortcuts.description.newWindow", value: "Open a new browser window.", comment: "Shortcuts settings - Description of the newWindow command")
        case .IDC_NEW_INCOGNITO_WINDOW:
            return NSLocalizedString("settings.shortcuts.description.newIncognitoWindow", value: "Open a new Incognito window.", comment: "Shortcuts settings - Description of the newIncognitoWindow command")
        case .IDC_NEW_SPLIT_TAB:
            return NSLocalizedString("settings.shortcuts.description.newSplitTab", value: "Open a tab in Split View.", comment: "Shortcuts settings - Description of the newSplitTab command")
        case .IDC_RESTORE_TAB:
            return NSLocalizedString("settings.shortcuts.description.restoreTab", value: "Reopen the most recently closed tab.", comment: "Shortcuts settings - Description of the restoreTab command")
        case .IDC_OPEN_FILE:
            return NSLocalizedString("settings.shortcuts.description.openFile", value: "Choose a file to open in Phi.", comment: "Shortcuts settings - Description of the openFile command")
        case .IDC_FOCUS_LOCATION:
            return NSLocalizedString("settings.shortcuts.description.focusLocation", value: "Focus the address bar to enter a URL or search.", comment: "Shortcuts settings - Description of the focusLocation command")
        case .IDC_CLOSE_WINDOW:
            return NSLocalizedString("settings.shortcuts.description.closeWindow", value: "Close the current window.", comment: "Shortcuts settings - Description of the closeWindow command")
        case .IDC_CLOSE_TAB:
            return NSLocalizedString("settings.shortcuts.description.closeTab", value: "Close the current tab.", comment: "Shortcuts settings - Description of the closeTab command")
        case .IDC_SAVE_PAGE:
            return NSLocalizedString("settings.shortcuts.description.savePage", value: "Save the current page to a file.", comment: "Shortcuts settings - Description of the savePage command")
        case .IDC_PRINT:
            return NSLocalizedString("settings.shortcuts.description.print", value: "Open print options for the current page.", comment: "Shortcuts settings - Description of the print command")
        case .IDC_BASIC_PRINT:
            return NSLocalizedString("settings.shortcuts.description.basicPrint", value: "Print the current page using the system dialog.", comment: "Shortcuts settings - Description of the basicPrint command")
        case .IDC_CONTENT_CONTEXT_UNDO:
            return NSLocalizedString("settings.shortcuts.description.undo", value: "Undo the last edit.", comment: "Shortcuts settings - Description of the undo command")
        case .IDC_CONTENT_CONTEXT_REDO:
            return NSLocalizedString("settings.shortcuts.description.redo", value: "Redo the last undone edit.", comment: "Shortcuts settings - Description of the redo command")
        case .IDC_CONTENT_CONTEXT_CUT:
            return NSLocalizedString("settings.shortcuts.description.cut", value: "Cut the selection to the clipboard.", comment: "Shortcuts settings - Description of the cut command")
        case .IDC_CONTENT_CONTEXT_COPY:
            return NSLocalizedString("settings.shortcuts.description.copy", value: "Copy the selection to the clipboard.", comment: "Shortcuts settings - Description of the copy command")
        case .IDC_CONTENT_CONTEXT_PASTE:
            return NSLocalizedString("settings.shortcuts.description.paste", value: "Paste the clipboard contents.", comment: "Shortcuts settings - Description of the paste command")
        case .IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE, .IDS_PASTE_MATCH_STYLE_MAC:
            return NSLocalizedString("settings.shortcuts.description.pasteMatchStyle", value: "Paste text using the surrounding formatting.", comment: "Shortcuts settings - Description of the pasteMatchStyle command")
        case .IDC_CONTENT_CONTEXT_SELECTALL:
            return NSLocalizedString("settings.shortcuts.description.selectAll", value: "Select all content in the focused area.", comment: "Shortcuts settings - Description of the selectAll command")
        case .IDC_FIND:
            return NSLocalizedString("settings.shortcuts.description.find", value: "Find text on the current page.", comment: "Shortcuts settings - Description of the find command")
        case .IDC_FIND_NEXT:
            return NSLocalizedString("settings.shortcuts.description.findNext", value: "Move to the next matching text on the page.", comment: "Shortcuts settings - Description of the findNext command")
        case .IDC_FIND_PREVIOUS:
            return NSLocalizedString("settings.shortcuts.description.findPrevious", value: "Move to the previous matching text on the page.", comment: "Shortcuts settings - Description of the findPrevious command")
        case .IDC_FOCUS_SEARCH:
            return NSLocalizedString("settings.shortcuts.description.focusSearch", value: "Focus the address bar to search the web.", comment: "Shortcuts settings - Description of the focusSearch command")
        case .IDC_SHOW_BOOKMARK_BAR:
            return NSLocalizedString("settings.shortcuts.description.bookmarkBar", value: "Show or hide the bookmarks bar. Only available in Comfortable layout.", comment: "Shortcuts settings - Bookmark bar command description; Comfortable is the layout option name")
        case .IDC_TOGGLE_FULLSCREEN_TOOLBAR:
            return NSLocalizedString("settings.shortcuts.description.fullscreenToolbar", value: "Show or hide the toolbar in full screen.", comment: "Shortcuts settings - Description of the fullscreenToolbar command")
        case .IDC_STOP:
            return NSLocalizedString("settings.shortcuts.description.stop", value: "Stop loading the current page.", comment: "Shortcuts settings - Description of the stop command")
        case .IDC_RELOAD:
            return NSLocalizedString("settings.shortcuts.description.reload", value: "Reload the current page.", comment: "Shortcuts settings - Description of the reload command")
        case .IDC_RELOAD_BYPASSING_CACHE:
            return NSLocalizedString("settings.shortcuts.description.forceReload", value: "Reload the current page without using cached content.", comment: "Shortcuts settings - Description of the forceReload command")
        case .IDC_FULLSCREEN:
            return NSLocalizedString("settings.shortcuts.description.fullscreen", value: "Enter or leave full screen.", comment: "Shortcuts settings - Description of the fullscreen command")
        case .IDC_ZOOM_NORMAL:
            return NSLocalizedString("settings.shortcuts.description.resetZoom", value: "Reset the current page to its default zoom level.", comment: "Shortcuts settings - Description of the resetZoom command")
        case .IDC_ZOOM_PLUS:
            return NSLocalizedString("settings.shortcuts.description.zoomIn", value: "Increase the zoom level of the current page.", comment: "Shortcuts settings - Description of the zoomIn command")
        case .IDC_ZOOM_MINUS:
            return NSLocalizedString("settings.shortcuts.description.zoomOut", value: "Decrease the zoom level of the current page.", comment: "Shortcuts settings - Description of the zoomOut command")
        case .IDC_VIEW_SOURCE:
            return NSLocalizedString("settings.shortcuts.description.viewSource", value: "View the source of the current page.", comment: "Shortcuts settings - Description of the viewSource command")
        case .IDC_DEV_TOOLS:
            return NSLocalizedString("settings.shortcuts.description.developerTools", value: "Open Developer Tools for the current page.", comment: "Shortcuts settings - Description of the developerTools command")
        case .IDC_DEV_TOOLS_INSPECT:
            return NSLocalizedString("settings.shortcuts.description.inspect", value: "Inspect an element on the current page.", comment: "Shortcuts settings - Description of the inspect command")
        case .IDC_DEV_TOOLS_CONSOLE:
            return NSLocalizedString("settings.shortcuts.description.console", value: "Open the JavaScript console for the current page.", comment: "Shortcuts settings - Description of the console command")
        case .IDC_HOME:
            return NSLocalizedString("settings.shortcuts.description.home", value: "Open the home page.", comment: "Shortcuts settings - Description of the home command")
        case .IDC_BACK:
            return NSLocalizedString("settings.shortcuts.description.back", value: "Go to the previous page in this tab's history.", comment: "Shortcuts settings - Description of the back command")
        case .IDC_FORWARD:
            return NSLocalizedString("settings.shortcuts.description.forward", value: "Go to the next page in this tab's history.", comment: "Shortcuts settings - Description of the forward command")
        case .IDC_SHOW_HISTORY:
            return NSLocalizedString("settings.shortcuts.description.history", value: "View your browsing history.", comment: "Shortcuts settings - Description of the history command")
        case .IDC_SHOW_BOOKMARK_MANAGER:
            return NSLocalizedString("settings.shortcuts.description.bookmarks", value: "Open the bookmark manager.", comment: "Shortcuts settings - Description of the bookmarks command")
        case .IDC_BOOKMARK_THIS_TAB:
            return NSLocalizedString("settings.shortcuts.description.bookmarkTab", value: "Bookmark the current page.", comment: "Shortcuts settings - Description of the bookmarkTab command")
        case .IDC_BOOKMARK_ALL_TABS:
            return NSLocalizedString("settings.shortcuts.description.bookmarkAllTabs", value: "Bookmark all open tabs.", comment: "Shortcuts settings - Description of the bookmarkAllTabs command")
        case .IDC_MINIMIZE_WINDOW:
            return NSLocalizedString("settings.shortcuts.description.minimize", value: "Minimize the current window.", comment: "Shortcuts settings - Description of the minimize command")
        case .IDC_SHOW_DOWNLOADS:
            return NSLocalizedString("settings.shortcuts.description.downloads", value: "View your downloads.", comment: "Shortcuts settings - Description of the downloads command")
        case .IDC_MANAGE_EXTENSIONS:
            return NSLocalizedString("settings.shortcuts.description.extensions", value: "Manage installed browser extensions.", comment: "Shortcuts settings - Description of the extensions command")
        case .IDC_TASK_MANAGER:
            return NSLocalizedString("settings.shortcuts.description.taskManager", value: "View browser tasks and their resource usage.", comment: "Shortcuts settings - Description of the taskManager command")
        case .IDC_NEW_TAB_TO_RIGHT:
            return NSLocalizedString("settings.shortcuts.description.newTabToRight", value: "Open a new tab to the right of the current tab.", comment: "Shortcuts settings - Description of the newTabToRight command")
        case .IDC_SELECT_NEXT_TAB, .IDC_CYCLE_TO_NEXT_TAB:
            return NSLocalizedString("settings.shortcuts.description.nextTab", value: "Select the next tab.", comment: "Shortcuts settings - Description of the nextTab command")
        case .IDC_SELECT_PREVIOUS_TAB, .IDC_CYCLE_TO_PREV_TAB:
            return NSLocalizedString("settings.shortcuts.description.previousTab", value: "Select the previous tab.", comment: "Shortcuts settings - Description of the previousTab command")
        case .IDC_SELECT_LAST_TAB:
            return NSLocalizedString("settings.shortcuts.description.lastTab", value: "Select the last tab.", comment: "Shortcuts settings - Description of the lastTab command")
        case .IDC_DUPLICATE_TAB:
            return NSLocalizedString("settings.shortcuts.description.duplicateTab", value: "Create a copy of the current tab.", comment: "Shortcuts settings - Description of the duplicateTab command")
        case .IDC_WINDOW_MUTE_SITE:
            return NSLocalizedString("settings.shortcuts.description.muteSite", value: "Mute or unmute audio from the current site.", comment: "Shortcuts settings - Description of the muteSite command")
        case .IDC_WINDOW_PIN_TAB:
            return NSLocalizedString("settings.shortcuts.description.pinTab", value: "Pin or unpin the current tab.", comment: "Shortcuts settings - Description of the pinTab command")
        case .IDC_WINDOW_GROUP_TAB:
            return NSLocalizedString("settings.shortcuts.description.groupTab", value: "Change the group of the current tab.", comment: "Shortcuts settings - Description of the groupTab command")
        case .IDC_WINDOW_CLOSE_OTHER_TABS:
            return NSLocalizedString("settings.shortcuts.description.closeOtherTabs", value: "Close the other tabs in the current window.", comment: "Shortcuts settings - Description of the closeOtherTabs command")
        case .IDC_WINDOW_CLOSE_TABS_TO_RIGHT:
            return NSLocalizedString("settings.shortcuts.description.closeTabsToRight", value: "Close tabs to the right of the current tab.", comment: "Shortcuts settings - Description of the closeTabsToRight command")
        case .IDC_MOVE_TAB_TO_NEW_WINDOW:
            return NSLocalizedString("settings.shortcuts.description.moveTabToWindow", value: "Move the current tab to a new window.", comment: "Shortcuts settings - Description of the moveTabToWindow command")
        case .IDC_TAB_SEARCH:
            return NSLocalizedString("settings.shortcuts.description.tabSearch", value: "Search open tabs.", comment: "Shortcuts settings - Description of the tabSearch command")
        case .IDC_MOVE_TAB_NEXT:
            return NSLocalizedString("settings.shortcuts.description.moveTabRight", value: "Move the current tab one position to the right.", comment: "Shortcuts settings - Description of the moveTabRight command")
        case .IDC_MOVE_TAB_PREVIOUS:
            return NSLocalizedString("settings.shortcuts.description.moveTabLeft", value: "Move the current tab one position to the left.", comment: "Shortcuts settings - Description of the moveTabLeft command")
        case .IDC_SHOW_AVATAR_MENU:
            return NSLocalizedString("settings.shortcuts.description.profiles", value: "Open the profiles menu.", comment: "Shortcuts settings - Description of the profiles command")
        case .IDC_FOCUS_NEXT_PANE:
            return NSLocalizedString("settings.shortcuts.description.nextPane", value: "Move focus to the next browser pane.", comment: "Shortcuts settings - Description of the nextPane command")
        case .IDC_FOCUS_PREVIOUS_PANE:
            return NSLocalizedString("settings.shortcuts.description.previousPane", value: "Move focus to the previous browser pane.", comment: "Shortcuts settings - Description of the previousPane command")
        case .IDC_FOCUS_INACTIVE_POPUP_FOR_ACCESSIBILITY:
            return NSLocalizedString("settings.shortcuts.description.focusPopup", value: "Move focus to an open popup.", comment: "Shortcuts settings - Description of the focusPopup command")
        case .IDC_SHOW_READING_MODE_KEYBOARD:
            return NSLocalizedString("settings.shortcuts.description.readingMode", value: "Open Reading Mode for the current page.", comment: "Shortcuts settings - Description of the readingMode command")
        case .IDC_ADD_NEW_TAB_TO_GROUP:
            return NSLocalizedString("settings.shortcuts.description.addTabToGroup", value: "Add a new tab to the current tab group.", comment: "Shortcuts settings - Description of the addTabToGroup command")
        case .IDC_CREATE_NEW_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.description.createTabGroup", value: "Create a new tab group.", comment: "Shortcuts settings - Description of the createTabGroup command")
        case .IDC_CLOSE_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.description.closeTabGroup", value: "Close the current tab group.", comment: "Shortcuts settings - Description of the closeTabGroup command")
        case .IDC_FOCUS_NEXT_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.description.nextTabGroup", value: "Move focus to the next tab group.", comment: "Shortcuts settings - Description of the nextTabGroup command")
        case .IDC_FOCUS_PREV_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.description.previousTabGroup", value: "Move focus to the previous tab group.", comment: "Shortcuts settings - Description of the previousTabGroup command")
        case .IDC_DEBUG_TOGGLE_TABLET_MODE:
            return NSLocalizedString("settings.shortcuts.description.tabletMode", value: "Toggle tablet mode for browser debugging.", comment: "Shortcuts settings - Description of the tabletMode command")
        case .IDC_DEBUG_PRINT_VIEW_TREE:
            return NSLocalizedString("settings.shortcuts.description.viewTree", value: "Print the browser view hierarchy for debugging.", comment: "Shortcuts settings - Description of the viewTree command")
        case .IDC_DEBUG_PRINT_VIEW_TREE_DETAILS:
            return NSLocalizedString("settings.shortcuts.description.viewTreeDetails", value: "Print the detailed browser view hierarchy for debugging.", comment: "Shortcuts settings - Description of the viewTreeDetails command")
        case .IDC_FEEDBACK:
            return NSLocalizedString("settings.shortcuts.description.feedback", value: "Open the feedback page.", comment: "Shortcuts settings - Description of the feedback command")
        case .IDC_HELP_PAGE_VIA_MENU:
            return NSLocalizedString("settings.shortcuts.description.help", value: "Open browser help.", comment: "Shortcuts settings - Description of the help command")
        case .PHI_TOGGLE_SIDEBAR:
            return NSLocalizedString("settings.shortcuts.description.sidebar", value: "Show or hide the sidebar.", comment: "Shortcuts settings - Description of the sidebar command")
        case .PHI_TOGGLE_CHATBAR:
            return NSLocalizedString("settings.shortcuts.description.chatbar", value: "Show or hide the chat panel.", comment: "Shortcuts settings - Description of the chatbar command")
        case .PHI_TAB_SWITCHER_FORWARD:
            return NSLocalizedString("settings.shortcuts.description.tabSwitcher", value: "Show the tab switcher and move forward through recent tabs.", comment: "Shortcuts settings - Description of the tabSwitcher command")
        case .PHI_TAB_SWITCHER_BACKWARD:
            return NSLocalizedString("settings.shortcuts.description.tabSwitcherReverse", value: "Show the tab switcher and move backward through recent tabs.", comment: "Shortcuts settings - Description of the tabSwitcherReverse command")
        case .PHI_NEW_CONVERSATION:
            return NSLocalizedString("settings.shortcuts.description.newConversation", value: "Start a new conversation in Phi Chat.", comment: "Shortcuts settings - Description of the newConversation command")
        case .PHI_SELECT_NEXT_SPACE:
            return NSLocalizedString("settings.shortcuts.description.nextSpace", value: "Switch to the next Space.", comment: "Shortcuts settings - Description of the nextSpace command")
        case .PHI_SELECT_PREVIOUS_SPACE:
            return NSLocalizedString("settings.shortcuts.description.previousSpace", value: "Switch to the previous Space.", comment: "Shortcuts settings - Description of the previousSpace command")
        case .PHI_FARRINGDON_TOGGLE:
            return NSLocalizedString("settings.shortcuts.description.organizeTabs", value: "Organize tabs with AI.", comment: "Shortcuts settings - Description of the organizeTabs command")
        case .PHI_COPY_URL:
            return NSLocalizedString("settings.shortcuts.description.copyURL", value: "Copy the current page's URL to the clipboard.", comment: "Shortcuts settings - Description of the copyURL command")
        case .PHI_TOGGLE_READER:
            return NSLocalizedString("settings.shortcuts.description.reader", value: "Open or close Reader for the current page.", comment: "Shortcuts settings - Description of the reader command")
        case .PHI_NEW_KIOSK_WINDOW:
            return NSLocalizedString("settings.shortcuts.description.newKiosk", value: "Open a new Kiosk window.", comment: "Shortcuts settings - Description of the newKiosk command")
        case .PHI_NEW_INCOGNITO_SPACE:
            return NSLocalizedString("settings.shortcuts.description.newIncognitoSpace", value: "Create a new Incognito Space.", comment: "Shortcuts settings - Description of the newIncognitoSpace command")
        case .PHI_SHARE_PAGE:
            return NSLocalizedString("settings.shortcuts.description.sharePage", value: "Share the current page.", comment: "Shortcuts settings - Description of the sharePage command")
        case .PHI_CAPTURE_FULL_PAGE:
            return NSLocalizedString("settings.shortcuts.description.captureFullPage", value: "Capture the entire current webpage and copy it as an image.", comment: "Shortcuts settings - Description of the full page screenshot command")
        case .PHI_CAPTURE_AREA:
            return NSLocalizedString("settings.shortcuts.description.captureArea", value: "Select a visible webpage area to capture and edit.", comment: "Shortcuts settings - Description of the area screenshot command")
        case .PHI_KIOSK_OPEN_IN_SPACE:
            return NSLocalizedString("settings.shortcuts.description.kioskOpenInSpace", value: "Open the current Peek or Kiosk page in a Space.", comment: "Shortcuts settings - Description of the kioskOpenInSpace command")
        case .PHI_KIOSK_CHOOSE_SPACE:
            return NSLocalizedString("settings.shortcuts.description.kioskChooseSpace", value: "Choose a Space for the current Peek or Kiosk page.", comment: "Shortcuts settings - Description of the kioskChooseSpace command")
        case .PHI_SAVE_FOR_LATER:
            return NSLocalizedString("settings.shortcuts.description.saveForLater", value: "Save the current page for later.", comment: "Shortcuts settings - Description of the saveForLater command")
        case .PHI_SPLIT_WITH_NEW_TAB:
            return NSLocalizedString("settings.shortcuts.description.splitWithNewTab", value: "Open a new tab in Split View next to the current tab.", comment: "Shortcuts settings - Description of the splitWithNewTab command")
        case .IDS_HIDE_OTHERS_MAC:
            return NSLocalizedString("settings.shortcuts.description.hideOthers", value: "Hide other applications.", comment: "Shortcuts settings - Description of the hideOthers command")
        case .IDS_CLOSE_ALL_WINDOWS_MAC:
            return NSLocalizedString("settings.shortcuts.description.closeAllWindows", value: "Close all Phi windows.", comment: "Shortcuts settings - Description of the closeAllWindows command")
        case .IDS_EDIT_USE_SELECTION_MAC:
            return NSLocalizedString("settings.shortcuts.description.useSelection", value: "Use the selected text as the search text.", comment: "Shortcuts settings - Description of the useSelection command")
        case .IDS_EDIT_JUMP_TO_SELECTION_MAC:
            return NSLocalizedString("settings.shortcuts.description.jumpToSelection", value: "Scroll to the selected text.", comment: "Shortcuts settings - Description of the jumpToSelection command")
        case .IDS_EDIT_SHOW_SPELLING_GRAMMAR_MAC:
            return NSLocalizedString("settings.shortcuts.description.spellingGrammar", value: "Show spelling and grammar options.", comment: "Shortcuts settings - Description of the spellingGrammar command")
        case .IDS_EDIT_CHECK_DOCUMENT_MAC:
            return NSLocalizedString("settings.shortcuts.description.checkDocument", value: "Check the document for spelling errors.", comment: "Shortcuts settings - Description of the checkDocument command")
        case .IDC_SELECT_TAB_0:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedTab", value: "Switch to tab %d in the current window.", comment: "Shortcuts settings - Description for a numbered tab; %d is its position"), 1)
        case .IDC_SELECT_TAB_1:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedTab", value: "Switch to tab %d in the current window.", comment: "Shortcuts settings - Description for a numbered tab; %d is its position"), 2)
        case .IDC_SELECT_TAB_2:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedTab", value: "Switch to tab %d in the current window.", comment: "Shortcuts settings - Description for a numbered tab; %d is its position"), 3)
        case .IDC_SELECT_TAB_3:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedTab", value: "Switch to tab %d in the current window.", comment: "Shortcuts settings - Description for a numbered tab; %d is its position"), 4)
        case .IDC_SELECT_TAB_4:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedTab", value: "Switch to tab %d in the current window.", comment: "Shortcuts settings - Description for a numbered tab; %d is its position"), 5)
        case .IDC_SELECT_TAB_5:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedTab", value: "Switch to tab %d in the current window.", comment: "Shortcuts settings - Description for a numbered tab; %d is its position"), 6)
        case .IDC_SELECT_TAB_6:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedTab", value: "Switch to tab %d in the current window.", comment: "Shortcuts settings - Description for a numbered tab; %d is its position"), 7)
        case .IDC_SELECT_TAB_7:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedTab", value: "Switch to tab %d in the current window.", comment: "Shortcuts settings - Description for a numbered tab; %d is its position"), 8)
        case .PHI_SELECT_SPACE_0:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedSpace", value: "Switch to Space %d in the current window.", comment: "Shortcuts settings - Description for a numbered space; %d is its position"), 1)
        case .PHI_SELECT_SPACE_1:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedSpace", value: "Switch to Space %d in the current window.", comment: "Shortcuts settings - Description for a numbered space; %d is its position"), 2)
        case .PHI_SELECT_SPACE_2:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedSpace", value: "Switch to Space %d in the current window.", comment: "Shortcuts settings - Description for a numbered space; %d is its position"), 3)
        case .PHI_SELECT_SPACE_3:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedSpace", value: "Switch to Space %d in the current window.", comment: "Shortcuts settings - Description for a numbered space; %d is its position"), 4)
        case .PHI_SELECT_SPACE_4:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedSpace", value: "Switch to Space %d in the current window.", comment: "Shortcuts settings - Description for a numbered space; %d is its position"), 5)
        case .PHI_SELECT_SPACE_5:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedSpace", value: "Switch to Space %d in the current window.", comment: "Shortcuts settings - Description for a numbered space; %d is its position"), 6)
        case .PHI_SELECT_SPACE_6:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedSpace", value: "Switch to Space %d in the current window.", comment: "Shortcuts settings - Description for a numbered space; %d is its position"), 7)
        case .PHI_SELECT_SPACE_7:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedSpace", value: "Switch to Space %d in the current window.", comment: "Shortcuts settings - Description for a numbered space; %d is its position"), 8)
        case .PHI_SELECT_SPACE_8:
            return String(format: NSLocalizedString("settings.shortcuts.description.numberedSpace", value: "Switch to Space %d in the current window.", comment: "Shortcuts settings - Description for a numbered space; %d is its position"), 9)
        }
    }
}
