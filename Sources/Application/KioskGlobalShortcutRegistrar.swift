// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Carbon.HIToolbox

/// Mirrors the effective New Kiosk Window shortcut into Carbon's system-wide
/// hot-key service while the user-facing preference is enabled.
final class KioskGlobalShortcutRegistrar {
    struct Configuration: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private static let hotKeySignature: OSType = 0x5048494B // PHIK
    private static let hotKeyID: UInt32 = 1

    private let action: () -> Void
    private let isApplicationActive: () -> Bool
    private let activateApplication: () -> Void
    private let notificationCenter: NotificationCenter
    private let activationNotificationObject: Any?
    private let scheduleAfterActivation: (@escaping () -> Void) -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var shortcutsObserver: NSObjectProtocol?
    private var applicationActivationObserver: NSObjectProtocol?
    private var eventHandlerStatus: OSStatus = noErr
    private var isEnabled = false

    init(
        action: @escaping () -> Void,
        isApplicationActive: @escaping () -> Bool = { NSApp.isActive },
        activateApplication: @escaping () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        },
        notificationCenter: NotificationCenter = .default,
        activationNotificationObject: Any? = NSApp,
        scheduleAfterActivation: @escaping (@escaping () -> Void) -> Void = {
            DispatchQueue.main.async(execute: $0)
        }
    ) {
        self.action = action
        self.isApplicationActive = isApplicationActive
        self.activateApplication = activateApplication
        self.notificationCenter = notificationCenter
        self.activationNotificationObject = activationNotificationObject
        self.scheduleAfterActivation = scheduleAfterActivation
    }

    func start() {
        assert(Thread.isMainThread)
        guard shortcutsObserver == nil else {
            refresh()
            return
        }

        isEnabled = PhiPreferences.GeneralSettings
            .openKioskWithGlobalShortcut.loadValue()
        installEventHandler()
        shortcutsObserver = notificationCenter.addObserver(
            forName: .shortcutsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        isEnabled = enabled
        refresh()
    }

    func invalidate() {
        assert(Thread.isMainThread)
        if let shortcutsObserver {
            notificationCenter.removeObserver(shortcutsObserver)
            self.shortcutsObserver = nil
        }
        removeApplicationActivationObserver()
        unregisterCurrentShortcut()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    static func configuration(
        for shortcut: ShortcutsKey?,
        isEnabled: Bool
    ) -> Configuration? {
        guard isEnabled,
              let shortcut,
              let keyCode = shortcut.carbonVirtualKeyCode else {
            return nil
        }

        var modifiers: UInt32 = 0
        let shortcutModifiers = shortcut.modifiers
            .intersection(ShortcutsKey.supportedModifierFlags)
        if shortcutModifiers.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if shortcutModifiers.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if shortcutModifiers.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if shortcutModifiers.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        guard modifiers != 0 else { return nil }

        return Configuration(keyCode: keyCode, modifiers: modifiers)
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        eventHandlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let registrar = Unmanaged<KioskGlobalShortcutRegistrar>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                return registrar.handle(event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if eventHandlerStatus != noErr {
            AppLogError(
                "[KioskGlobalShortcut] Failed to install event handler "
                    + "(OSStatus \(eventHandlerStatus))"
            )
        }
    }

    private func refresh() {
        unregisterCurrentShortcut()
        guard eventHandlerStatus == noErr else { return }

        let shortcut = Shortcuts.key(for: .PHI_NEW_KIOSK_WINDOW)
        guard let configuration = Self.configuration(
            for: shortcut,
            isEnabled: isEnabled
        ) else {
            if isEnabled, let shortcut {
                AppLogWarn(
                    "[KioskGlobalShortcut] Unsupported shortcut "
                        + shortcut.displayString
                )
            }
            return
        }

        var newHotKey: EventHotKeyRef?
        let identifier = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: Self.hotKeyID
        )
        let status = RegisterEventHotKey(
            configuration.keyCode,
            configuration.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &newHotKey
        )
        guard status == noErr else {
            AppLogError(
                "[KioskGlobalShortcut] Failed to register "
                    + "\(shortcut?.displayString ?? "disabled") "
                    + "(OSStatus \(status))"
            )
            return
        }
        hotKey = newHotKey
    }

    private func unregisterCurrentShortcut() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        assert(Thread.isMainThread)
        var identifier = EventHotKeyID(signature: 0, id: 0)
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr,
              identifier.signature == Self.hotKeySignature,
              identifier.id == Self.hotKeyID else {
            return OSStatus(eventNotHandledErr)
        }

        performActionAfterApplicationActivation()
        return noErr
    }

    /// When Phi is in the background, AppKit can restore an existing main
    /// window at the end of activation. Wait for that lifecycle to settle
    /// before creating Kiosk so the new window wins the final ordering pass.
    func performActionAfterApplicationActivation() {
        assert(Thread.isMainThread)
        guard !isApplicationActive() else {
            action()
            return
        }
        guard applicationActivationObserver == nil else { return }

        applicationActivationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: activationNotificationObject,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.removeApplicationActivationObserver()
            self.scheduleAfterActivation { [weak self] in
                self?.action()
            }
        }
        activateApplication()
    }

    private func removeApplicationActivationObserver() {
        if let applicationActivationObserver {
            notificationCenter.removeObserver(applicationActivationObserver)
            self.applicationActivationObserver = nil
        }
    }
}
