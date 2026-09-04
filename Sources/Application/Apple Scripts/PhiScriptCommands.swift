// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import PostHog

struct PhiScriptingClientContext: Decodable, Equatable {
    private static let maxPayloadBytes = 1_024
    private static let knownCommands: Set<String> = [
        "new-incognito-space",
        "new-incognito-window",
        "new-kiosk-window",
        "new-tab",
        "new-window",
        "phi-actions",
        "search-current-space-tabs",
        "search-spaces",
        "search-tabs",
    ]
    private static let knownActions: Set<String> = [
        "activate-space",
        "activate-tab",
        "add-split-view",
        "close-tab",
        "force-refresh-page",
        "manage-extensions",
        "open-bookmark",
        "open-pinned-tab",
        "refresh-page",
        "reload-tab",
    ]

    let schemaVersion: Int
    let clientId: String
    let clientCommand: String
    let clientAction: String?
    let invocationId: String

    static func parse(_ rawValue: String?) -> PhiScriptingClientContext? {
        guard
            let rawValue,
            rawValue.utf8.count <= maxPayloadBytes,
            let data = rawValue.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Self.self, from: data),
            decoded.schemaVersion == 1,
            decoded.clientId == "raycast",
            UUID(uuidString: decoded.invocationId) != nil
        else {
            return nil
        }

        return Self(
            schemaVersion: decoded.schemaVersion,
            clientId: decoded.clientId,
            clientCommand: knownCommands.contains(decoded.clientCommand) ? decoded.clientCommand : "unknown",
            clientAction: decoded.clientAction.map { knownActions.contains($0) ? $0 : "unknown" },
            invocationId: decoded.invocationId.lowercased()
        )
    }
}

enum PhiScriptingAnalytics {
    static func shouldCapture(scriptingCommand: String) -> Bool {
        // Version checks are compatibility plumbing, not user operations.
        scriptingCommand != "get_version"
    }

    static func properties(
        clientContext: String?,
        scriptingCommand: String,
        succeeded: Bool,
        operationOutcome: PhiScriptingOperationResult
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "operation_outcome": operationOutcome.rawValue,
            "scripting_command": scriptingCommand,
            "source_client": "other",
            "succeeded": succeeded,
        ]

        guard let context = PhiScriptingClientContext.parse(clientContext) else {
            return properties
        }

        properties["source_client"] = context.clientId
        properties["client_command"] = context.clientCommand
        
        if let clientAction = context.clientAction {
            properties["client_action"] = clientAction
        }
        return properties
    }

    @MainActor
    static func capture(
        clientContext: String?,
        scriptingCommand: String,
        succeeded: Bool,
        operationOutcome: PhiScriptingOperationResult
    ) {
        guard shouldCapture(scriptingCommand: scriptingCommand) else {
            return
        }

        PostHogSDK.shared.capture(
            "scripting_command_invoked",
            properties: properties(
                clientContext: clientContext,
                scriptingCommand: scriptingCommand,
                succeeded: succeeded,
                operationOutcome: operationOutcome
            )
        )
    }
}

enum PhiScriptCommandExecution {
    static func run(
        scriptingCommand: String,
        clientContext: String?,
        operation: @escaping @MainActor () -> [String: Any]
    ) -> String {
        let execute: @MainActor () -> [String: Any] = {
            let response = operation()
            let succeeded = response["ok"] as? Bool == true
            let operationOutcome = (response["outcome"] as? String)
                .flatMap(PhiScriptingOperationResult.init(rawValue:))
                ?? (succeeded ? .completed : .failed)
            PhiScriptingAnalytics.capture(
                clientContext: clientContext,
                scriptingCommand: scriptingCommand,
                succeeded: succeeded,
                operationOutcome: operationOutcome
            )
            return response
        }

        let response: [String: Any]
        if Thread.isMainThread {
            response = MainActor.assumeIsolated(execute)
        } else {
            response = DispatchQueue.main.sync {
                MainActor.assumeIsolated(execute)
            }
        }
        return PhiScriptingJSON.string(from: response)
    }
}

private extension NSScriptCommand {
    func stringArgument(_ key: String) -> String? {
        evaluatedArguments?[key] as? String
    }

    func runPhiCommand(
        _ scriptingCommand: String,
        operation: @escaping @MainActor () -> [String: Any]
    ) -> String {
        PhiScriptCommandExecution.run(
            scriptingCommand: scriptingCommand,
            clientContext: stringArgument("clientContext"),
            operation: operation
        )
    }
}

@objc(PhiListSpacesScriptCommand)
final class PhiListSpacesScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand("list_spaces") {
            PhiScriptingService.shared.listSpaces()
        }
    }
}

@objc(PhiListTabsScriptCommand)
final class PhiListTabsScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let scopeValue = stringArgument("scope")
        let spaceId = stringArgument("spaceId")
        return runPhiCommand("list_tabs") {
            do {
                let scope = try PhiScriptingTabScope(scope: scopeValue, spaceId: spaceId)
                return PhiScriptingService.shared.listTabs(scope: scope)
            } catch {
                return [
                    "schemaVersion": PhiScriptingService.schemaVersion,
                    "ok": false,
                    "error": [
                        "code": PhiScriptingError.invalidArgument.code,
                        "message": PhiScriptingError.invalidArgument.message,
                    ],
                ]
            }
        }
    }
}

@objc(PhiGetActiveSpaceScriptCommand)
final class PhiGetActiveSpaceScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand("get_active_space") {
            PhiScriptingService.shared.getActiveSpace()
        }
    }
}

@objc(PhiActivateSpaceScriptCommand)
final class PhiActivateSpaceScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let spaceId = stringArgument("spaceId")
        return runPhiCommand("activate_space") {
            PhiScriptingService.shared.activateSpace(spaceId: spaceId)
        }
    }
}

@objc(PhiActivateTabScriptCommand)
final class PhiActivateTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let windowId = stringArgument("windowId")
        let tabId = stringArgument("tabId")
        return runPhiCommand("activate_tab") {
            PhiScriptingService.shared.activateTab(windowId: windowId, tabId: tabId)
        }
    }
}

@objc(PhiCloseTabScriptCommand)
final class PhiCloseTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let windowId = stringArgument("windowId")
        let tabId = stringArgument("tabId")
        return runPhiCommand("close_tab") {
            PhiScriptingService.shared.closeTab(windowId: windowId, tabId: tabId)
        }
    }
}

@objc(PhiReloadTabScriptCommand)
final class PhiReloadTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let windowId = stringArgument("windowId")
        let tabId = stringArgument("tabId")
        return runPhiCommand("reload_tab") {
            PhiScriptingService.shared.reloadTab(windowId: windowId, tabId: tabId)
        }
    }
}

@objc(PhiForceReloadTabScriptCommand)
final class PhiForceReloadTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let windowId = stringArgument("windowId")
        let tabId = stringArgument("tabId")
        return runPhiCommand("force_reload_tab") {
            PhiScriptingService.shared.forceReloadTab(windowId: windowId, tabId: tabId)
        }
    }
}

@objc(PhiAddSplitViewScriptCommand)
final class PhiAddSplitViewScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let windowId = stringArgument("windowId")
        let tabId = stringArgument("tabId")
        return runPhiCommand("add_split_view") {
            PhiScriptingService.shared.addSplitView(windowId: windowId, tabId: tabId)
        }
    }
}

@objc(PhiOpenPinnedTabScriptCommand)
final class PhiOpenPinnedTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let spaceId = stringArgument("spaceId")
        let pinnedTabId = stringArgument("pinnedTabId")
        return runPhiCommand("open_pinned_tab") {
            PhiScriptingService.shared.openPinnedTab(
                spaceId: spaceId,
                pinnedTabId: pinnedTabId
            )
        }
    }
}

@objc(PhiOpenBookmarkScriptCommand)
final class PhiOpenBookmarkScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let spaceId = stringArgument("spaceId")
        let bookmarkId = stringArgument("bookmarkId")
        return runPhiCommand("open_bookmark") {
            PhiScriptingService.shared.openBookmark(
                spaceId: spaceId,
                bookmarkId: bookmarkId
            )
        }
    }
}

@objc(PhiOpenTabScriptCommand)
final class PhiOpenTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let address = stringArgument("address")
        let spaceId = stringArgument("spaceId")
        return runPhiCommand("open_tab") {
            PhiScriptingService.shared.openTab(address: address, spaceId: spaceId)
        }
    }
}

@objc(PhiNewWindowScriptCommand)
final class PhiNewWindowScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand("create_window") {
            PhiScriptingService.shared.newWindow()
        }
    }
}

@objc(PhiNewIncognitoWindowScriptCommand)
final class PhiNewIncognitoWindowScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand("create_incognito_window") {
            PhiScriptingService.shared.newIncognitoWindow()
        }
    }
}

@objc(PhiNewKioskWindowScriptCommand)
final class PhiNewKioskWindowScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let url = stringArgument("url")
        return runPhiCommand("create_kiosk_window") {
            PhiScriptingService.shared.newKioskWindow(url: url)
        }
    }
}

@objc(PhiNewIncognitoSpaceScriptCommand)
final class PhiNewIncognitoSpaceScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand("create_incognito_space") {
            PhiScriptingService.shared.newIncognitoSpace()
        }
    }
}

@objc(PhiGetVersionScriptCommand)
final class PhiGetVersionScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand("get_version") {
            PhiScriptingService.shared.getVersion()
        }
    }
}

@objc(PhiGetChromiumDataDirectoryScriptCommand)
final class PhiGetChromiumDataDirectoryScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand("get_chromium_data_directory") {
            PhiScriptingService.shared.getChromiumDataDirectory()
        }
    }
}
