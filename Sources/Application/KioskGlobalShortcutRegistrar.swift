// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Carbon.HIToolbox

/// Mirrors the effective New Kiosk Window shortcut into Carbon's system-wide
/// hot-key service while the user-facing preference is enabled.
final class KioskGlobalShortcutRegistrar {
    enum Status: Equatable {
        case disabled, unassigned, unsupported, registered
        case failed(OSStatus)
    }

    static let statusDidChangeNotification = Notification.Name("KioskGlobalShortcut.statusDidChange")
    static let inputSourceDidChangeNotification = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    struct Configuration: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// A snapshot of the current OS layout. Translation is injected in unit
    /// tests; production retains the system's Unicode layout data for the
    /// duration of resolution, including an IME's underlying keyboard layout.
    struct KeyboardLayout {
        let inputSourceIdentifier: String?
        let characters: (UInt16, NSEvent.ModifierFlags) -> String?

        static func current() -> KeyboardLayout? {
            guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  let fallback = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
            return load(source, fallback: fallback)
        }

        static func load(_ source: TISInputSource, fallback: TISInputSource? = nil) -> KeyboardLayout? {
            let identifier = TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map {
                Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
            }
            guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
                ?? fallback.flatMap({ TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }) else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            let keyboardType = UInt32(LMGetKbdType())
            return KeyboardLayout(inputSourceIdentifier: identifier) { keyCode, flags in
                guard let bytes = CFDataGetBytePtr(data) else { return nil }
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let result = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown),
                    carbonModifiers(flags) >> 8, keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState, characters.count, &length, &characters)
                guard result == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }

    /// Carbon owns the handles; this adapter keeps registration failures and
    /// cleanup testable without installing global shortcuts in unit tests.
    struct HotKeyAPI {
        var installHandler: (UnsafeMutableRawPointer) -> (OSStatus, EventHandlerRef?)
        var register: (Configuration, EventHotKeyID) -> (OSStatus, EventHotKeyRef?)
        var unregister: (EventHotKeyRef) -> OSStatus
        var removeHandler: (EventHandlerRef) -> OSStatus

        static let live = HotKeyAPI(
            installHandler: { userData in
                var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                var handler: EventHandlerRef?
                let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                    return Unmanaged<KioskGlobalShortcutRegistrar>.fromOpaque(userData).takeUnretainedValue().handle(event)
                }, 1, &eventType, userData, &handler)
                return (result, handler)
            },
            register: { configuration, identifier in
                var hotKey: EventHotKeyRef?
                // A non-exclusive registration can succeed while another
                // app's exclusive hotkey suppresses every notification.
                // Request ownership so conflicts produce a visible failure.
                let result = RegisterEventHotKey(configuration.keyCode, configuration.modifiers, identifier,
                    GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
                return (result, hotKey)
            },
            unregister: { UnregisterEventHotKey($0) },
            removeHandler: { RemoveEventHandler($0) }
        )
    }

    private static let hotKeySignature: OSType = 0x5048494B // PHIK

    private let action: () -> Void
    private let hotKeyAPI: HotKeyAPI
    private let shortcut: () -> ShortcutsKey?
    private let keyboardLayout: () -> KeyboardLayout?
    private let notificationCenter: NotificationCenter
    private let inputSourceNotificationCenter: NotificationCenter
    private var eventHandler: EventHandlerRef?
    private struct Registration {
        let configuration: Configuration
        let identifier: EventHotKeyID
        let hotKey: EventHotKeyRef
    }
    private var registrations: [Registration] = []
    private var shortcutsObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var nextHotKeyID: UInt32 = 0
    private var isEnabled = false
    private var recordingSessions: Set<UUID> = []
    private(set) var status: Status = .disabled {
        didSet {
            if oldValue != status { notificationCenter.post(name: Self.statusDidChangeNotification, object: self) }
        }
    }

    init(
        action: @escaping () -> Void,
        hotKeyAPI: HotKeyAPI = .live,
        shortcut: @escaping () -> ShortcutsKey? = { Shortcuts.key(for: .PHI_NEW_KIOSK_WINDOW) },
        keyboardLayout: @escaping () -> KeyboardLayout? = KeyboardLayout.current,
        notificationCenter: NotificationCenter = .default,
        inputSourceNotificationCenter: NotificationCenter = DistributedNotificationCenter.default()
    ) {
        self.action = action
        self.hotKeyAPI = hotKeyAPI
        self.shortcut = shortcut
        self.keyboardLayout = keyboardLayout
        self.notificationCenter = notificationCenter
        self.inputSourceNotificationCenter = inputSourceNotificationCenter
    }

    func start(enabled: Bool = PhiPreferences.GeneralSettings.openKioskWithGlobalShortcut.loadValue()) {
        assert(Thread.isMainThread)
        isEnabled = enabled
        guard shortcutsObserver == nil else {
            refresh()
            return
        }

        shortcutsObserver = notificationCenter.addObserver(
            forName: .shortcutsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        inputSourceObserver = inputSourceNotificationCenter.addObserver(
            forName: Self.inputSourceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        isEnabled = enabled
        refresh()
    }

    /// Release Carbon ownership so the recorder receives the actual key event.
    /// Each recorder releases only its own suspension, including during replacement.
    func suspendForShortcutRecording() -> () -> Void {
        assert(Thread.isMainThread)
        let session = UUID()
        recordingSessions.insert(session)
        refresh()
        return { [weak self] in
            assert(Thread.isMainThread)
            guard let self, self.recordingSessions.remove(session) != nil else { return }
            self.refresh()
        }
    }

    func invalidate() {
        assert(Thread.isMainThread)
        if let shortcutsObserver {
            notificationCenter.removeObserver(shortcutsObserver)
            self.shortcutsObserver = nil
        }
        if let inputSourceObserver {
            inputSourceNotificationCenter.removeObserver(inputSourceObserver)
            self.inputSourceObserver = nil
        }
        isEnabled = false
        recordingSessions.removeAll()
        if unregisterCurrentShortcut() { status = .disabled }
        if let eventHandler {
            let result = hotKeyAPI.removeHandler(eventHandler)
            if result == noErr { self.eventHandler = nil }
            else { status = .failed(result) }
        }
    }

    static func configurations(
        for shortcut: ShortcutsKey?,
        isEnabled: Bool,
        layout: KeyboardLayout? = KeyboardLayout.current()
    ) -> [Configuration] {
        guard isEnabled,
              let shortcut,
              !shortcut.modifiers.contains(.function),
              shortcut.modifiers.subtracting(ShortcutsKey.supportedModifierFlags).isEmpty,
              !shortcut.modifiers.isEmpty,
              !(shortcut.modifiers == .shift && shortcut.isPrintableMenuCharacter) else {
            return []
        }

        if let keyCode = shortcut.carbonSpecialKeyCode {
            return [Configuration(keyCode: keyCode, modifiers: carbonModifiers(shortcut.modifiers))]
        }
        guard shortcut.isPrintableMenuCharacter, let layout else { return [] }

        // Shift is encoded in printable menu identities, including legacy '+'
        // bindings without an explicit Shift bit. Resolve both physical forms
        // through the same canonical/legacy matcher used by native dispatch.
        let unshifted = shortcut.modifiers.subtracting(.shift)
        let candidates = [unshifted, unshifted.union(.shift)]
        var matches: [Configuration: Int] = [:]
        for keyCode in UInt16(0)...UInt16(127) {
            for flags in candidates {
                let eventFlags = ShortcutsKey.isPrintableKeypadKeyCode(keyCode)
                    ? flags.union(.numericPad) : flags
                guard let semantic = layout.characters(keyCode, flags.intersection(.shift)),
                      let characters = layout.characters(keyCode, flags),
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: eventFlags,
                          timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                          charactersIgnoringModifiers: semantic, isARepeat: false, keyCode: keyCode),
                      let rank = ShortcutsKey.eventKeys(for: event, inputSourceIdentifier: layout.inputSourceIdentifier)?
                        .matchingRank(for: shortcut) else { continue }
                let configuration = Configuration(keyCode: UInt32(keyCode), modifiers: carbonModifiers(flags))
                guard configuration.modifiers != 0 else { continue }
                matches[configuration] = min(matches[configuration] ?? rank, rank)
            }
        }
        // Preserve every physical alias of the canonical semantic identity.
        // Only use legacy layout candidates when no canonical candidate exists.
        guard let identityRank = matches.values.map({ $0 / 2 }).min() else { return [] }
        return matches.filter { $0.value / 2 == identityRank }.map(\.key).sorted {
            $0.keyCode == $1.keyCode ? $0.modifiers < $1.modifiers : $0.keyCode < $1.keyCode
        }
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        return modifiers
    }

    private func installEventHandler() -> Bool {
        guard eventHandler == nil else { return true }
        let (result, handler) = hotKeyAPI.installHandler(Unmanaged.passUnretained(self).toOpaque())
        guard result == noErr, let handler else {
            let failure = result == noErr ? OSStatus(paramErr) : result
            AppLogError("[KioskGlobalShortcut] Failed to install event handler (OSStatus \(failure))")
            status = .failed(failure)
            return false
        }
        eventHandler = handler
        return true
    }

    private func refresh() {
        assert(Thread.isMainThread)
        guard recordingSessions.isEmpty else {
            if unregisterCurrentShortcut() { status = .disabled }
            return
        }
        let shortcut = shortcut()
        let configurations = Self.configurations(for: shortcut, isEnabled: isEnabled,
                                                layout: isEnabled ? keyboardLayout() : nil)
        if !configurations.isEmpty, status == .registered,
           configurations == registrations.map(\.configuration), eventHandler != nil {
            return
        }
        guard unregisterCurrentShortcut() else { return }
        guard !configurations.isEmpty else {
            status = !isEnabled ? .disabled : (shortcut == nil ? .unassigned : .unsupported)
            return
        }
        guard installEventHandler() else { return }
        for configuration in configurations {
            nextHotKeyID &+= 1
            if nextHotKeyID == 0 { nextHotKeyID = 1 }
            let identifier = EventHotKeyID(signature: Self.hotKeySignature, id: nextHotKeyID)
            let (result, newHotKey) = hotKeyAPI.register(configuration, identifier)
            guard result == noErr, let newHotKey else {
                let failure = result == noErr ? OSStatus(paramErr) : result
                AppLogError("[KioskGlobalShortcut] Failed to register \(shortcut?.displayString ?? "disabled") (OSStatus \(failure))")
                if unregisterCurrentShortcut() { status = .failed(failure) }
                return
            }
            registrations.append(Registration(configuration: configuration, identifier: identifier, hotKey: newHotKey))
        }
        status = .registered
    }

    private func unregisterCurrentShortcut() -> Bool {
        var remaining: [Registration] = []
        for registration in registrations {
            let result = hotKeyAPI.unregister(registration.hotKey)
            if result != noErr {
                AppLogError("[KioskGlobalShortcut] Failed to unregister (OSStatus \(result))")
                status = .failed(result)
                remaining.append(registration)
            }
        }
        registrations = remaining
        return remaining.isEmpty
    }

    func handle(_ event: EventRef) -> OSStatus {
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
        guard status == noErr, isEnabled, recordingSessions.isEmpty, self.status == .registered,
              identifier.signature == Self.hotKeySignature,
              registrations.contains(where: { $0.identifier.id == identifier.id }) else {
            return OSStatus(eventNotHandledErr)
        }

        // Immediately, even while another app is active: the action asks
        // in a non-activating panel and activates Phi only once it opens
        // something (`KioskLaunchActivation`). Waiting for activation here
        // would stall every later press when macOS declines to activate.
        action()
        return noErr
    }
}
