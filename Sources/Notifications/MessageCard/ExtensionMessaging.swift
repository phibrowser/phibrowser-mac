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
}

final class ExtensionMessaging: @MainActor ExtensionMessagingProtocol {
    static let shared = ExtensionMessaging()
    @MainActor
    func sendResponse(_ response: String, requestId: String) {
        DispatchQueue.main.async {
            ChromiumLauncher.sharedInstance().bridge?
                .sendResponse(forExtensionRequest: requestId, response: response)
        }
    }
    
    @MainActor
    func sendError(_ error: String, requestId: String) {
        DispatchQueue.main.async {
            ChromiumLauncher.sharedInstance().bridge?
                .sendError(forExtensionRequest: requestId, error: error)
        }
    }
    
    @MainActor
    func broadcast(type: String, payload: String) {
        DispatchQueue.main.async {
            _ = ChromiumLauncher.sharedInstance().bridge?
                .broadcastMessageToExtensions(withType: type, payload: payload)
        }
    }
}
