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
    static func attachedTo(_ window: NSWindow) -> NSWindow {
        var top = window
        while let parent = top.sheetParent ?? top.parent { top = parent }
        return top
    }
}

/// Phi brought to the front by an app switch (Cmd-Tab, the Dock icon, another
/// app activating it) onto a macOS desktop where its only window is a
/// picture-in-picture window. AppKit makes key and main the frontmost of the
/// app's windows on the current desktop, and a picture-in-picture window
/// visits every desktop, so it takes key while the browser windows sit on
/// other desktops. This hands key to the last active browser window instead,
/// and macOS moves to that window's desktop, as with Safari, whose
/// picture-in-picture runs in another process.
///
/// A Dock click goes through this twice: once on activation, then again when
/// AppKit handles the reopen event, as it picks a key window on the current
/// desktop again before asking the app delegate
/// (`AppController.applicationShouldHandleReopen`).
///
/// Left alone:
/// - A click on the picture-in-picture window. It makes the window key before
///   the app activates, so its playback keys keep working.
/// - A switch to the desktop by the user (Control-arrow, a swipe, Mission
///   Control). macOS then activates the owner of that desktop's frontmost
///   window, the floating picture-in-picture window, and moving away would
///   undo the user's switch.
/// - A picture-in-picture window AppKit restores on a desktop that also has a
///   browser window: it was the last key window there.
@MainActor
final class PictureInPictureActivationHandOff {
    static let shared = PictureInPictureActivationHandOff()

    /// How soon after a desktop switch made while Phi was inactive an
    /// activation counts as caused by that switch. macOS activates the owner
    /// of the arrival desktop's frontmost window 2-3 ms after
    /// `activeSpaceDidChangeNotification`; a Cmd-Tab or Dock click comes at
    /// the user's own pace.
    static let desktopSwitchActivationInterval: TimeInterval = 0.5

    private var observers: [NSObjectProtocol] = []
    /// Whether a window was already key when the app began activating: a
    /// click on one of its windows, which AppKit keys before activating.
    private var activationFoundKeyWindow = false
    /// `systemUptime` of the last desktop switch made while Phi was inactive.
    private var lastInactiveDesktopSwitch: TimeInterval?

    private init() {}

    func install() {
        guard observers.isEmpty else { return }
        // No queue: each runs synchronously where AppKit posts it, on the
        // main thread, so the desktop switch is seen before the activation it
        // causes.
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.willBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activationFoundKeyWindow = NSApp.keyWindow != nil }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !NSApp.isActive else { return }
                self?.lastInactiveDesktopSwitch = ProcessInfo.processInfo.systemUptime
            }
        })
    }

    private func applicationDidBecomeActive() {
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.shouldHandOff(
            activationFoundKeyWindow: activationFoundKeyWindow,
            secondsSinceInactiveDesktopSwitch: lastInactiveDesktopSwitch.map { now - $0 },
            pictureInPictureAloneOnDesktop: pictureInPictureAloneOnDesktop)
        else { return }
        handOffKey(after: "activation")
    }

    /// The Dock click's reopen event, which the user only sends to switch to
    /// Phi. Returns true when it handed key to a browser window, which is then
    /// all the reopen has to do.
    func applicationShouldHandleReopen() -> Bool {
        guard pictureInPictureAloneOnDesktop else { return false }
        return handOffKey(after: "reopen")
    }

    private var isPictureInPicture: (NSWindow) -> Bool? {
        { ChromiumLauncher.sharedInstance().bridge?.isPictureInPictureWindow?($0) }
    }

    /// The switch only decides fullscreen desktops; on any other desktop the
    /// picture-in-picture window takes key either way.
    private var pictureInPictureAloneOnDesktop: Bool {
        PictureInPictureOnlyDesktop.isActive(
            switchOn: true, keyWindow: NSApp.keyWindow, windows: NSApp.windows,
            isPictureInPicture: isPictureInPicture)
    }

    @discardableResult
    private func handOffKey(after event: String) -> Bool {
        guard let target = SpaceSessionControllersManager.shared.activeWindowController?.window,
              target.isVisible || target.isMiniaturized, target.canBecomeKey,
              isPictureInPicture(PictureInPictureOnlyDesktop.attachedTo(target)) != true else {
            AppLogInfo("[PiPActivation] picture-in-picture took key on \(event); no browser window to hand it to")
            return false
        }
        AppLogInfo("[PiPActivation] picture-in-picture took key on \(event); handing it to "
            + "window \(target.windowNumber)\(target.isMiniaturized ? " (deminiaturizing)" : "")")
        if target.isMiniaturized {
            target.deminiaturize(nil)
        }
        target.makeKeyAndOrderFront(nil)
        return true
    }

    /// The rule behind the hand-off. `secondsSinceInactiveDesktopSwitch` is
    /// nil when no desktop switch happened while Phi was inactive.
    static func shouldHandOff(
        activationFoundKeyWindow: Bool,
        secondsSinceInactiveDesktopSwitch: TimeInterval?,
        pictureInPictureAloneOnDesktop: Bool
    ) -> Bool {
        guard !activationFoundKeyWindow, pictureInPictureAloneOnDesktop else { return false }
        if let seconds = secondsSinceInactiveDesktopSwitch,
           seconds < desktopSwitchActivationInterval {
            return false
        }
        return true
    }
}
