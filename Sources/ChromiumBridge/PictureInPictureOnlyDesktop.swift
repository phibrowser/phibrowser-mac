// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Phi is the active app because the user clicked a picture-in-picture window,
/// and no other Phi window is on the current macOS desktop: another app's
/// fullscreen desktop, or a desktop whose Phi windows are all minimized or on
/// other desktops. A Phi command run from there would act on, or open its UI
/// over, a window the user cannot see, so none runs: `PhiApplication` greys
/// out every main-menu item except text editing, and `CommandDispatcher`
/// swallows the Phi shortcuts that skip the menu and the commands Chromium's
/// own key dispatch finds. Typing, text editing and other keys that are not
/// commands still reach the picture-in-picture window; a document
/// picture-in-picture page misses the command keys swallowed before it sees
/// them.
///
/// Follows the picture-in-picture-on-fullscreen-desktops switch, the one that
/// lets picture-in-picture windows onto other apps' fullscreen desktops: while
/// it is off this never applies. Decided from the windows as they are each
/// time a menu item is validated or sent and each time a key reaches
/// `CommandDispatcher`; nothing is cached or observed, so reaching a desktop
/// with a Phi window lifts it at once.
enum PictureInPictureOnlyDesktop {
    /// Whether the state holds now.
    @MainActor
    static var isActive: Bool {
        isActive(
            switchOn: PhiPreferences.GeneralSettings.loadPictureInPictureOnFullscreenDesktops(),
            keyWindow: NSApp.keyWindow,
            windows: NSApp.windows,
            isPictureInPicture: { ChromiumLauncher.sharedInstance().bridge?.isPictureInPictureWindow?($0) })
    }

    /// The rule behind `isActive`. `isPictureInPicture` is Chromium's answer
    /// for a window, nil when the framework does not know the question.
    /// Windows attached to a picture-in-picture window (its alert, permission
    /// bubble or file chooser, as child windows or sheets) count as that
    /// window. Another Phi window counts when the user can see it on the
    /// current desktop and could work in it; tooltips and menus, which can
    /// never become key, do not.
    @MainActor
    static func isActive(
        switchOn: Bool,
        keyWindow: NSWindow?,
        windows: [NSWindow],
        isPictureInPicture: (NSWindow) -> Bool?
    ) -> Bool {
        guard switchOn, let keyWindow,
              isPictureInPicture(attachedTo(keyWindow)) == true else { return false }
        return !windows.contains { window in
            window !== keyWindow && window.isVisible && window.alphaValue > 0
                && !window.isMiniaturized && window.isOnActiveSpace && window.canBecomeKey
                && isPictureInPicture(attachedTo(window)) != true
        }
    }

    /// The window `window` hangs off as a sheet or child window, all the way
    /// up; `window` itself when it hangs off none.
    @MainActor
    private static func attachedTo(_ window: NSWindow) -> NSWindow {
        var top = window
        while let parent = top.sheetParent ?? top.parent { top = parent }
        return top
    }
}
