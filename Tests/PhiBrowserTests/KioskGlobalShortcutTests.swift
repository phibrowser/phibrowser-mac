// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Phi

@MainActor
final class KioskGlobalShortcutTests: XCTestCase {
    typealias Registrar = KioskGlobalShortcutRegistrar

    func testGermanAndUSSemanticZResolveToTheirActualPhysicalKeys() throws {
        let key = ShortcutsKey(characters: "z", modifiers: [.command, .option])
        XCTAssertEqual(configuration(for: key, isEnabled: true, layout: try layout("German")),
                       .init(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(cmdKey | optionKey)))
        XCTAssertEqual(configuration(for: key, isEnabled: true, layout: try layout("US")),
                       .init(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | optionKey)))
    }

    func testCommandQWERTYUsesPhysicalIdentityForNonCommandBindings() throws {
        let layout = try layout("DVORAK-QWERTYCMD")
        for (flags, carbon) in [(NSEvent.ModifierFlags.control, UInt32(controlKey)),
                               (.option, UInt32(optionKey)),
                               ([.control, .option], UInt32(controlKey | optionKey)),
                               (.command, UInt32(cmdKey))] {
            XCTAssertEqual(configuration(for: .init(characters: "z", modifiers: flags), isEnabled: true, layout: layout),
                           .init(keyCode: UInt32(kVK_ANSI_Z), modifiers: carbon))
        }
    }

    func testOrdinaryDvorakKeepsItsSemanticCharacter() throws {
        XCTAssertEqual(configuration(for: .init(characters: ";", modifiers: .control),
                                               isEnabled: true, layout: try layout("Dvorak")),
                       .init(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey)))
    }

    func testCzechCommandNumberRowAndControlPlusFollowNativeMatching() throws {
        let layout = try layout("Czech")
        XCTAssertEqual(configuration(for: .init(characters: "1", modifiers: .command), isEnabled: true, layout: layout),
                       .init(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey)))
        XCTAssertEqual(configuration(for: .init(characters: "+", modifiers: .control), isEnabled: true, layout: layout),
                       .init(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(controlKey)))
    }

    func testLegacyPlusAndUppercaseBindingsInferThePhysicalShiftKey() throws {
        let layout = try layout("US")
        var previousAliases: Set<Registrar.Configuration>?
        for key in [ShortcutsKey(characters: "+", modifiers: .command),
                    .init(characters: "+", modifiers: [.command, .shift])] {
            XCTAssertEqual(configuration(for: key, isEnabled: true, layout: layout),
                           .init(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(cmdKey | shiftKey)))
            let aliases = Set(Registrar.configurations(for: key, isEnabled: true, layout: layout))
            XCTAssertTrue(aliases.contains(.init(keyCode: UInt32(kVK_ANSI_KeypadPlus), modifiers: UInt32(cmdKey))))
            if let previousAliases { XCTAssertEqual(aliases, previousAliases) }
            previousAliases = aliases
        }
        XCTAssertEqual(configuration(for: .init(characters: "C", modifiers: .command), isEnabled: true, layout: layout),
                       .init(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey)))
    }

    func testShiftedKeypadRegistersOnlyShiftedPhysicalKeys() throws {
        let layout = try layout("US")
        for (code, character) in [(kVK_ANSI_Keypad1, "1"), (kVK_ANSI_KeypadPlus, "+")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.control, .shift, .numericPad], timestamp: 0, windowNumber: 0,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: UInt16(code)))
            let key = try XCTUnwrap(ShortcutsKey.recordingKey(for: event, inputSourceIdentifier: "com.apple.keylayout.US"))
            XCTAssertEqual(Registrar.configurations(for: key, isEnabled: true, layout: layout),
                           [.init(keyCode: UInt32(code), modifiers: UInt32(controlKey | shiftKey))])
            let unshifted = ShortcutsKey(characters: character, modifiers: .control)
            let aliases = Registrar.configurations(for: unshifted, isEnabled: true, layout: layout)
            XCTAssertTrue(aliases.contains(.init(keyCode: UInt32(code), modifiers: UInt32(controlKey))))
            XCTAssertFalse(aliases.contains(.init(keyCode: UInt32(code), modifiers: UInt32(controlKey | shiftKey))))
        }
    }

    func testUnavailableLayoutDoesNotInventAnANSIPrintableBinding() {
        XCTAssertNil(configuration(for: .init(characters: "z", modifiers: .control), isEnabled: true, layout: nil))
        XCTAssertEqual(configuration(for: .init(characters: "\u{F72D}", modifiers: .control), isEnabled: true, layout: nil),
                       .init(keyCode: UInt32(kVK_PageDown), modifiers: UInt32(controlKey)))
        XCTAssertEqual(configuration(for: .init(characters: "\u{1B}", modifiers: .control), isEnabled: true, layout: nil),
                       .init(keyCode: UInt32(kVK_Escape), modifiers: UInt32(controlKey)))
    }

    func testDisabledMissingAndUnsupportedBindingsAreNotRegistered() throws {
        let layout = try layout("US")
        let valid = ShortcutsKey(characters: "n", modifiers: [.command, .option])
        XCTAssertNil(configuration(for: valid, isEnabled: false, layout: layout))
        XCTAssertNil(configuration(for: nil, isEnabled: true, layout: layout))
        for key in [ShortcutsKey(characters: "n", modifiers: []),
                    .init(characters: "n", modifiers: .shift),
                    .init(characters: "n", modifiers: [.command, .function]),
                    .init(characters: "n", modifiers: [.command, .capsLock]),
                    .init(characters: "🧭", modifiers: .command),
                    .init(characters: "\u{F71C}", modifiers: .control)] {
            XCTAssertNil(configuration(for: key, isEnabled: true, layout: layout), "Unexpected registration for \(key)")
        }
    }

    func testCanonicalPhysicalIdentityWinsOverLegacySemanticCandidate() {
        let layout = Registrar.KeyboardLayout(inputSourceIdentifier: "com.apple.keylayout.DVORAK-QWERTYCMD") { code, _ in
            switch Int(code) {
            case kVK_ANSI_A: return "z"
            case kVK_ANSI_Z: return ";"
            default: return nil
            }
        }
        XCTAssertEqual(configuration(for: .init(characters: "z", modifiers: .control), isEnabled: true, layout: layout),
                       .init(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey)))
    }

    func testSuccessfulRegistrationIsIdempotentAndCleansEveryAlias() throws {
        let api = FakeHotKeys()
        let center = NotificationCenter()
        let sources = NotificationCenter()
        let layout = try layout("US")
        let key = ShortcutsKey(characters: "+", modifiers: .command)
        let registrar = Registrar(action: {}, hotKeyAPI: api.api, shortcut: { key }, keyboardLayout: { layout },
                                  notificationCenter: center, inputSourceNotificationCenter: sources)
        defer { registrar.invalidate() }
        registrar.start(enabled: true)
        XCTAssertEqual(registrar.status, .registered)
        XCTAssertTrue(api.active.values.contains { $0.configuration == .init(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(cmdKey | shiftKey)) })
        XCTAssertTrue(api.active.values.contains { $0.configuration == .init(keyCode: UInt32(kVK_ANSI_KeypadPlus), modifiers: UInt32(cmdKey)) })
        let count = api.registerCalls.count
        registrar.start(enabled: true)
        center.post(name: .shortcutsDidChange, object: nil)
        sources.post(name: Registrar.inputSourceDidChangeNotification, object: nil)
        XCTAssertEqual(api.registerCalls.count, count)
        XCTAssertEqual(api.installCount, 1)
        registrar.invalidate()
        XCTAssertEqual(registrar.status, .disabled)
        XCTAssertTrue(api.active.isEmpty)
        XCTAssertEqual(api.unregisterCount, count)
        XCTAssertEqual(api.removeCount, 1)
        center.post(name: .shortcutsDidChange, object: nil)
        sources.post(name: Registrar.inputSourceDidChangeNotification, object: nil)
        XCTAssertEqual(api.registerCalls.count, count)
    }

    func testAliasRegistrationFailureRollsBackAndCanRecover() throws {
        let api = FakeHotKeys()
        api.failRegistrationAt = 2
        let layout = try layout("US")
        let registrar = Registrar(action: {}, hotKeyAPI: api.api,
            shortcut: { .init(characters: "+", modifiers: .command) }, keyboardLayout: { layout })
        defer { registrar.invalidate() }
        registrar.setEnabled(true)
        XCTAssertEqual(registrar.status, .failed(FakeHotKeys.failure))
        XCTAssertEqual(api.registerCalls.count, 2)
        XCTAssertEqual(api.unregisterCount, 1)
        XCTAssertTrue(api.active.isEmpty, "A failed alias must not leave a partially working global shortcut")
        api.failRegistrationAt = nil
        registrar.setEnabled(true)
        XCTAssertEqual(registrar.status, .registered)
        XCTAssertGreaterThan(api.active.count, 1)
        XCTAssertEqual(api.installCount, 1)
    }

    func testHandlerFailureAndMissingHandleAreReportedAndRetried() throws {
        let api = FakeHotKeys()
        api.installResult = FakeHotKeys.failure
        let layout = try layout("US")
        let registrar = Registrar(action: {}, hotKeyAPI: api.api,
            shortcut: { .init(characters: "z", modifiers: .control) }, keyboardLayout: { layout })
        defer { registrar.invalidate() }
        registrar.setEnabled(true)
        XCTAssertEqual(registrar.status, .failed(FakeHotKeys.failure))
        XCTAssertTrue(api.registerCalls.isEmpty)
        api.installResult = noErr
        api.omitHandler = true
        registrar.setEnabled(true)
        XCTAssertEqual(registrar.status, .failed(OSStatus(paramErr)))
        XCTAssertTrue(api.registerCalls.isEmpty)
        api.omitHandler = false
        registrar.setEnabled(true)
        XCTAssertEqual(registrar.status, .registered)
        XCTAssertEqual(api.installCount, 3)
    }

    func testStatusDistinguishesDisabledUnassignedUnsupportedAndRegistered() throws {
        let api = FakeHotKeys()
        let center = NotificationCenter()
        let sourceCenter = NotificationCenter()
        let layout = try layout("US")
        var key: ShortcutsKey?
        let registrar = Registrar(action: {}, hotKeyAPI: api.api, shortcut: { key }, keyboardLayout: { layout },
                                  notificationCenter: center, inputSourceNotificationCenter: sourceCenter)
        var statuses: [Registrar.Status] = []
        let observer = center.addObserver(forName: Registrar.statusDidChangeNotification, object: nil, queue: .main) {
            if let source = $0.object as? Registrar { statuses.append(source.status) }
        }
        defer { center.removeObserver(observer); registrar.invalidate() }
        registrar.start(enabled: false)
        XCTAssertEqual(registrar.status, .disabled)
        XCTAssertEqual(api.installCount, 0)
        registrar.setEnabled(true)
        XCTAssertEqual(registrar.status, .unassigned)
        key = .init(characters: "z", modifiers: .control)
        center.post(name: .shortcutsDidChange, object: nil)
        XCTAssertEqual(registrar.status, .registered)
        key = .init(characters: "z", modifiers: [.control, .function])
        center.post(name: .shortcutsDidChange, object: nil)
        XCTAssertEqual(registrar.status, .unsupported)
        XCTAssertTrue(api.active.isEmpty)
        registrar.setEnabled(false)
        XCTAssertEqual(statuses, [.unassigned, .registered, .unsupported, .disabled])
    }

    func testInputSourceChangeReplacesUSZWithGermanZAndInvalidationStopsObservation() throws {
        let api = FakeHotKeys()
        let center = NotificationCenter()
        let sources = NotificationCenter()
        var currentLayout = try layout("US")
        let registrar = Registrar(action: {}, hotKeyAPI: api.api,
            shortcut: { .init(characters: "z", modifiers: [.command, .option]) }, keyboardLayout: { currentLayout },
            notificationCenter: center, inputSourceNotificationCenter: sources)
        defer { registrar.invalidate() }
        registrar.start(enabled: true)
        XCTAssertEqual(api.active.values.map(\.configuration.keyCode), [UInt32(kVK_ANSI_Z)])
        currentLayout = try layout("German")
        sources.post(name: Registrar.inputSourceDidChangeNotification, object: nil)
        XCTAssertEqual(registrar.status, .registered)
        XCTAssertEqual(api.active.values.map(\.configuration.keyCode), [UInt32(kVK_ANSI_Y)])
        XCTAssertEqual(api.unregisterCount, 1)
        registrar.invalidate()
        let count = api.registerCalls.count
        sources.post(name: Registrar.inputSourceDidChangeNotification, object: nil)
        center.post(name: .shortcutsDidChange, object: nil)
        XCTAssertEqual(api.registerCalls.count, count)
        XCTAssertTrue(api.active.isEmpty)
    }

    func testRebindingRejectsOldHotKeyEventsAndDisablingRejectsCurrentEvents() throws {
        let api = FakeHotKeys()
        let center = NotificationCenter()
        let layout = try layout("US")
        var key = ShortcutsKey(characters: "z", modifiers: .control)
        var actions = 0
        let registrar = Registrar(action: { actions += 1 }, hotKeyAPI: api.api, shortcut: { key }, keyboardLayout: { layout },
                                  notificationCenter: center,
                                  inputSourceNotificationCenter: NotificationCenter())
        defer { registrar.invalidate() }
        registrar.start(enabled: true)
        let oldID = try XCTUnwrap(api.active.values.first?.identifier)
        XCTAssertEqual(try deliver(oldID, to: registrar), noErr)
        key = .init(characters: "n", modifiers: .control)
        center.post(name: .shortcutsDidChange, object: nil)
        let newID = try XCTUnwrap(api.active.values.first?.identifier)
        XCTAssertNotEqual(oldID.id, newID.id)
        XCTAssertEqual(try deliver(oldID, to: registrar), OSStatus(eventNotHandledErr))
        XCTAssertEqual(try deliver(.init(signature: 0, id: newID.id), to: registrar), OSStatus(eventNotHandledErr))
        XCTAssertEqual(try deliver(newID, to: registrar), noErr)
        registrar.setEnabled(false)
        XCTAssertEqual(try deliver(newID, to: registrar), OSStatus(eventNotHandledErr))
        XCTAssertEqual(actions, 2)
    }

    /// The New Kiosk omnibox asks in a non-activating panel, so a press
    /// must act right away: waiting for an activation macOS may decline
    /// would swallow this press and every later one.
    func testPressActsImmediatelyEvenWhileAnotherAppIsActive() throws {
        let api = FakeHotKeys()
        let layout = try layout("US")
        var actions = 0
        let registrar = Registrar(action: { actions += 1 }, hotKeyAPI: api.api,
            shortcut: { .init(characters: "z", modifiers: .control) }, keyboardLayout: { layout },
            notificationCenter: NotificationCenter(), inputSourceNotificationCenter: NotificationCenter())
        defer { registrar.invalidate() }
        registrar.start(enabled: true)
        let identifier = try XCTUnwrap(api.active.values.first?.identifier)

        XCTAssertEqual(try deliver(identifier, to: registrar), noErr)
        XCTAssertEqual(try deliver(identifier, to: registrar), noErr)
        XCTAssertEqual(actions, 2, "Every press acts; none waits on the one before")

        registrar.setEnabled(false)
        XCTAssertEqual(try deliver(identifier, to: registrar), OSStatus(eventNotHandledErr))
        XCTAssertEqual(actions, 2)
    }

    func testUnregisterFailurePreventsReplacementAndActionUntilRecovery() throws {
        let api = FakeHotKeys()
        let center = NotificationCenter()
        let layout = try layout("US")
        var key = ShortcutsKey(characters: "z", modifiers: .control)
        var actions = 0
        let registrar = Registrar(action: { actions += 1 }, hotKeyAPI: api.api, shortcut: { key }, keyboardLayout: { layout },
            notificationCenter: center, inputSourceNotificationCenter: NotificationCenter())
        defer { registrar.invalidate() }
        registrar.start(enabled: true)
        let oldID = try XCTUnwrap(api.active.values.first?.identifier)
        key = .init(characters: "n", modifiers: .control)
        api.unregisterResult = FakeHotKeys.failure
        center.post(name: .shortcutsDidChange, object: nil)
        XCTAssertEqual(registrar.status, .failed(FakeHotKeys.failure))
        XCTAssertEqual(api.registerCalls.count, 1)
        XCTAssertEqual(try deliver(oldID, to: registrar), OSStatus(eventNotHandledErr))
        XCTAssertEqual(actions, 0)
        api.unregisterResult = noErr
        registrar.setEnabled(true)
        XCTAssertEqual(registrar.status, .registered)
        XCTAssertEqual(api.active.values.map(\.configuration.keyCode), [UInt32(kVK_ANSI_N)])
    }

    func testRecordingReleasesAllAliasesAndRestoresTheLatestBindingOnce() throws {
        let api = FakeHotKeys()
        let center = NotificationCenter()
        let sources = NotificationCenter()
        let layout = try layout("US")
        var key = ShortcutsKey(characters: "+", modifiers: .command)
        var actions = 0
        let registrar = Registrar(action: { actions += 1 }, hotKeyAPI: api.api,
            shortcut: { key }, keyboardLayout: { layout }, 
            notificationCenter: center, inputSourceNotificationCenter: sources)
        defer { registrar.invalidate() }
        registrar.start(enabled: true)
        let identifiers = api.active.values.map(\.identifier)
        XCTAssertGreaterThan(identifiers.count, 1)

        let resumeFirst = registrar.suspendForShortcutRecording()
        let resumeSecond = registrar.suspendForShortcutRecording()
        XCTAssertTrue(api.active.isEmpty)
        for identifier in identifiers {
            XCTAssertEqual(try deliver(identifier, to: registrar), OSStatus(eventNotHandledErr))
        }
        key = .init(characters: "n", modifiers: .control)
        center.post(name: .shortcutsDidChange, object: nil)
        sources.post(name: Registrar.inputSourceDidChangeNotification, object: nil)
        XCTAssertTrue(api.active.isEmpty, "Saving or changing input sources must not resume capture early")
        resumeFirst()
        resumeFirst()
        XCTAssertTrue(api.active.isEmpty, "An old recorder cannot release the active recorder's suspension")
        resumeSecond()
        let count = api.registerCalls.count
        resumeSecond()
        XCTAssertEqual(api.registerCalls.count, count)
        XCTAssertEqual(registrar.status, .registered)
        XCTAssertEqual(api.active.values.map(\.configuration.keyCode), [UInt32(kVK_ANSI_N)])
        XCTAssertEqual(try deliver(try XCTUnwrap(api.active.values.first?.identifier), to: registrar), noErr)
        XCTAssertEqual(actions, 1)
    }

    func testRecordingRejectsPressesAndRespectsDisablement() throws {
        let api = FakeHotKeys()
        let layout = try layout("US")
        var actions = 0
        let registrar = Registrar(action: { actions += 1 }, hotKeyAPI: api.api,
            shortcut: { .init(characters: "n", modifiers: .control) }, keyboardLayout: { layout },
            notificationCenter: NotificationCenter(), inputSourceNotificationCenter: NotificationCenter())
        defer { registrar.invalidate() }
        registrar.start(enabled: true)
        let identifier = try XCTUnwrap(api.active.values.first?.identifier)
        let resume = registrar.suspendForShortcutRecording()
        XCTAssertEqual(try deliver(identifier, to: registrar), OSStatus(eventNotHandledErr))
        XCTAssertEqual(actions, 0)
        registrar.setEnabled(false)
        resume()
        XCTAssertTrue(api.active.isEmpty)
        XCTAssertEqual(registrar.status, .disabled)
    }

    func testRecordingUnregisterFailureBlocksActionsAndCanRecoverOnRelease() throws {
        let api = FakeHotKeys()
        let layout = try layout("US")
        let registrar = Registrar(action: { XCTFail("A recording must not open Kiosk") }, hotKeyAPI: api.api,
            shortcut: { .init(characters: "n", modifiers: .control) }, keyboardLayout: { layout },
            notificationCenter: NotificationCenter(),
            inputSourceNotificationCenter: NotificationCenter())
        defer { registrar.invalidate() }
        registrar.start(enabled: true)
        let oldID = try XCTUnwrap(api.active.values.first?.identifier)
        api.unregisterResult = FakeHotKeys.failure
        let resume = registrar.suspendForShortcutRecording()
        XCTAssertEqual(registrar.status, .failed(FakeHotKeys.failure))
        XCTAssertEqual(try deliver(oldID, to: registrar), OSStatus(eventNotHandledErr))
        api.unregisterResult = noErr
        resume()
        XCTAssertEqual(registrar.status, .registered)
        XCTAssertNotEqual(api.active.values.first?.identifier.id, oldID.id)
    }

    func testSettingsReportsEveryEnabledStateWithoutClaimingSuccessFromPreferenceAlone() {
        XCTAssertNil(NavigationsSettingsView.globalShortcutStatusDescription(.disabled))
        let descriptions = [Registrar.Status.registered, .unassigned, .unsupported, .failed(FakeHotKeys.failure)]
            .compactMap(NavigationsSettingsView.globalShortcutStatusDescription)
        XCTAssertEqual(descriptions.count, 4)
        XCTAssertEqual(Set(descriptions).count, 4)
        XCTAssertTrue(descriptions.allSatisfy { !$0.isEmpty })
    }

    func testSystemRegistrationReportsConflictRecoversAndReleasesOwnership() throws {
        // Reserve a test-only chord without changing user preferences or
        // synthesizing keyboard input. Exercise the real Carbon service.
        let code = UInt32(kVK_F19)
        let modifiers = UInt32(controlKey | optionKey | shiftKey)
        let identifier = EventHotKeyID(signature: 0x50485453, id: 1) // PHTS
        var blocker: EventHotKeyRef?
        let result = RegisterEventHotKey(code, modifiers, identifier,
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &blocker)
        XCTAssertEqual(result, noErr)
        let blockerRef = try XCTUnwrap(blocker)
        defer { if let blocker { XCTAssertEqual(UnregisterEventHotKey(blocker), noErr) } }

        let registrar = Registrar(action: { XCTFail("No keyboard input is sent by this test") },
            shortcut: { .init(characters: "\u{F716}", modifiers: [.control, .option, .shift]) },
            keyboardLayout: { nil }, notificationCenter: NotificationCenter(),
            inputSourceNotificationCenter: NotificationCenter())
        defer { registrar.invalidate() }
        registrar.start(enabled: true)
        guard case .failed(let failure) = registrar.status else {
            return XCTFail("A duplicate system hotkey must report failure: \(registrar.status)")
        }
        XCTAssertNotEqual(failure, noErr)
        XCTAssertEqual(UnregisterEventHotKey(blockerRef), noErr)
        blocker = nil
        registrar.setEnabled(true)
        XCTAssertEqual(registrar.status, .registered)
        registrar.invalidate()
        XCTAssertEqual(registrar.status, .disabled)

        // Acquiring it again proves the registrar released the actual OS
        // reservation, rather than only updating its status property.
        XCTAssertEqual(RegisterEventHotKey(code, modifiers, identifier,
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &blocker), noErr)
        XCTAssertNotNil(blocker)
    }

    private func deliver(_ identifier: EventHotKeyID, to registrar: Registrar) throws -> OSStatus {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                                  EventAttributes(kEventAttributeUserEvent), &event), noErr)
        let actualEvent = try XCTUnwrap(event)
        defer { ReleaseEvent(actualEvent) }
        var identifier = identifier
        XCTAssertEqual(SetEventParameter(actualEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
        return registrar.handle(actualEvent)
    }

    private final class FakeHotKeys {
        static let failure: OSStatus = -9876
        struct Entry {
            let configuration: Registrar.Configuration
            let identifier: EventHotKeyID
        }
        var installResult: OSStatus = noErr
        var unregisterResult: OSStatus = noErr
        var omitHandler = false
        var failRegistrationAt: Int?
        var installCount = 0
        var removeCount = 0
        var unregisterCount = 0
        var registerCalls: [Entry] = []
        var active: [EventHotKeyRef: Entry] = [:]

        var api: Registrar.HotKeyAPI {
            .init(installHandler: { [unowned self] _ in
                installCount += 1
                return (installResult, installResult == noErr && !omitHandler ? unsafeBitCast(UInt(1), to: EventHandlerRef.self) : nil)
            }, register: { [unowned self] configuration, identifier in
                let entry = Entry(configuration: configuration, identifier: identifier)
                registerCalls.append(entry)
                if failRegistrationAt == registerCalls.count { return (Self.failure, nil) }
                let handle = unsafeBitCast(UInt(registerCalls.count + 100), to: EventHotKeyRef.self)
                active[handle] = entry
                return (noErr, handle)
            }, unregister: { [unowned self] handle in
                unregisterCount += 1
                if unregisterResult == noErr { XCTAssertNotNil(active.removeValue(forKey: handle)) }
                return unregisterResult
            }, removeHandler: { [unowned self] _ in
                removeCount += 1
                return noErr
            })
        }
    }

    private func configuration(for key: ShortcutsKey?, isEnabled: Bool,
                               layout: Registrar.KeyboardLayout?) -> Registrar.Configuration? {
        Registrar.configurations(for: key, isEnabled: isEnabled, layout: layout).first
    }

    private func layout(_ name: String) throws -> Registrar.KeyboardLayout {
        let identifier = "com.apple.keylayout." + name
        let sources = TISCreateInputSourceList([kTISPropertyInputSourceID as String: identifier] as CFDictionary, true)
            .takeRetainedValue() as! [TISInputSource]
        return try XCTUnwrap(Registrar.KeyboardLayout.load(try XCTUnwrap(sources.first)), identifier)
    }
}
