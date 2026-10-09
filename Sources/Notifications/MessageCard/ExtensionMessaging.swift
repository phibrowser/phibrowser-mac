// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

protocol ExtensionMessagingProtocol {
    /// Send a response to an extension's pending request
    /// - Parameters:
    ///   - response: The response JSON string
    ///   - requestId: The request ID from the original extension message
    func sendResponse(_ response: String, requestId: String)
    
    /// Send an error to an extension's pending request (extension can catch with try/catch)
    /// - Parameters:
    ///   - error: The error message
    ///   - requestId: The request ID from the original extension message
    func sendError(_ error: String, requestId: String)
    
    /// Broadcast a message to all extensions
    /// - Parameters:
    ///   - type: The message type
    ///   - payload: The JSON payload string
    func broadcast(type: String, payload: String)

    /// Send an event only to the authenticated external-agent session.
    func broadcastToAgent(type: String, payload: String, principalId: String)
}

final class ExtensionMessaging: @MainActor ExtensionMessagingProtocol {
    static let shared = ExtensionMessaging()
    @MainActor
    func sendResponse(_ response: String, requestId: String) {
        DispatchQueue.main.async {
            // A direct /phi-agent request never left the app: reply on its own
            // socket instead of routing back through Chromium.
            if AgentDirectChannelRegistry.shared.deliverResponse(
                requestId: requestId, response: response) {
                return
            }
            ChromiumLauncher.sharedInstance().bridge?
                .sendResponse(forExtensionRequest: requestId, response: response)
        }
    }

    @MainActor
    func sendError(_ error: String, requestId: String) {
        DispatchQueue.main.async {
            if AgentDirectChannelRegistry.shared.deliverError(
                requestId: requestId, error: error) {
                return
            }
            ChromiumLauncher.sharedInstance().bridge?
                .sendError(forExtensionRequest: requestId, error: error)
        }
    }

    @MainActor
    func broadcast(type: String, payload: String) {
        DispatchQueue.main.async {
            // Fan out to app-served direct channels as well as extensions
            // (which receive it via Chromium's PhiAgentSpace.appMessage).
            AgentDirectChannelRegistry.shared.broadcast(type: type, payloadJson: payload)
            _ = ChromiumLauncher.sharedInstance().bridge?
                .broadcastMessageToExtensions(withType: type, payload: payload)
        }
    }

    /// Agent card decisions never cross the extension broadcast channel.
    @MainActor
    func broadcastToAgent(type: String, payload: String, principalId: String) {
        DispatchQueue.main.async {
            AgentDirectChannelRegistry.shared.broadcast(
                type: type, payloadJson: payload, principalId: principalId)
        }
    }

    /// Delivers a task event only to that task's driver. External CDP tasks
    /// stay inside their app-issued principal; in-app phi-agent tasks continue
    /// through the Chromium extension bridge. This prevents user messages and
    /// ownership changes from leaking across approved direct connections.
    @MainActor
    func broadcastToTaskDriver(type: String, payload: String,
                               origin: AgentTaskOrigin,
                               driverPrincipalId: String?) {
        DispatchQueue.main.async {
            switch origin {
            case .cdp:
                guard let driverPrincipalId, !driverPrincipalId.isEmpty else { return }
                AgentDirectChannelRegistry.shared.broadcast(
                    type: type, payloadJson: payload, principalId: driverPrincipalId)
            case .phiAgent:
                _ = ChromiumLauncher.sharedInstance().bridge?
                    .broadcastMessageToExtensions(withType: type, payload: payload)
            }
        }
    }
}
